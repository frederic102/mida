import 'dart:io';
import 'dart:typed_data';

import '../extractors/media_models.dart';
import 'stream_downloader.dart';

/// The `.part` file a single [StreamDownloader.download] call writes to,
/// wrapped so its underlying [IOSink] can be reopened (truncating back to
/// zero bytes) between retry attempts of a fetch that streams directly to
/// disk - see [StreamBodyWriter._streamCapped]'s doc for why that matters.
class PartFile {
  final String path;
  IOSink sink;

  PartFile(this.path) : sink = File(path).openWrite();

  /// Closes the current handle and reopens fresh at [path] - `openWrite`'s
  /// default mode truncates, so this undoes whatever a failed attempt
  /// already streamed in before the next retry starts writing.
  Future<void> reset() async {
    await sink.close();
    sink = File(path).openWrite();
  }

  Future<void> close() => sink.close();
}

class FetchOutcome {
  final int bytesWritten;
  /// True when the server answered with the *entire* file (a 200 where a
  /// ranged 206 was expected, or the only response the unranged path ever
  /// makes) rather than just one chunk.
  final bool isFullBody;
  const FetchOutcome({required this.bytesWritten, required this.isFullBody});
}

/// The byte-level half of [StreamDownloader]: fetching one response
/// (unranged, or one ranged chunk) and getting its body onto disk safely -
/// bounded, streamed rather than fully buffered where the size is
/// unknown, and retried with the `.part` file truncated back to empty
/// first when a partial write could have happened. Split out of
/// `stream_downloader.dart` (which owns the redirect/host-check/TLS
/// concerns instead) to stay under this project's 400-line file cap.
///
/// [get] is `StreamDownloader._get` - the redirect-following, host-checked
/// fetch; this class never talks to `HttpClient` directly.
/// [certificateTrustException] converts a raw [HandshakeException] into
/// the app's own what/why/next [StreamDownloadException] (see
/// `StreamDownloader._certificateTrustException`'s doc for why that
/// conversion happens immediately rather than being retried).
class StreamBodyWriter {
  final Future<HttpClientResponse> Function(
    String url,
    Map<String, String> headers,
    Map<String, List<CookieEntry>>? cookiesByDomain,
    int? start,
    int? end,
  ) get;
  final int maxRetries;
  final Duration Function(int attempt) backoff;
  final String Function(String url) redact;
  final StreamDownloadException Function(String url, HandshakeException cause) certificateTrustException;

  /// Hard ceiling on how many bytes a single response body is ever allowed
  /// to write to disk when the server did not declare a usable size for
  /// it (no `Content-Length`, or a ranged request answered 200 instead of
  /// 206). Not a realistic file size for anything this app downloads -
  /// purely a backstop against a compromised/misbehaving server streaming
  /// an unbounded body and filling the disk.
  static const int hardCapBytes = 8 * 1024 * 1024 * 1024; // 8 GB

  /// `Content-Type`s that mean "this is an error page or an API response",
  /// never actual media - live-caught (coordinator repro, coverage probe):
  /// one candidate's `https` format URL resolved to an HTML/JSON error body
  /// instead of the video, and nothing rejected it, so it was written to
  /// disk and handed off as a "successful" 1.7MB file with zero real
  /// streams. Checked only on the first (or only) response for a
  /// candidate - a legitimate CDN does not switch from real media to an
  /// error page mid-download without also changing its HTTP status, which
  /// the existing 200-on-a-later-chunk check already refuses.
  ///
  /// Deliberately narrow (just these two, not `text/plain`/`text/xml`/...):
  /// `dart:io`'s own `HttpResponse` defaults to `Content-Type: text/plain`
  /// for *any* response that never sets one explicitly - true of plenty of
  /// legitimate raw-byte CDNs (and every hermetic test fixture server in
  /// this codebase that never bothers setting a media type either), so
  /// blocklisting that too would reject real, working downloads far more
  /// often than it would ever catch a genuine error page. `text/html` and
  /// `application/json` are never a real server's default and essentially
  /// never legitimately mean "this is the media file".
  static const _nonMediaContentTypes = {'text/html', 'application/json'};

  static const _whitespaceBytes = {0x20, 0x0A, 0x0D, 0x09}; // space, \n, \r, \t

  StreamBodyWriter({
    required this.get,
    required this.maxRetries,
    required this.backoff,
    required this.redact,
    required this.certificateTrustException,
  });

  void verifyCompleteLength(int written, int? contentLength, String url) {
    if (contentLength != null && contentLength > 0 && written != contentLength) {
      throw StreamDownloadException(
        'Downloaded $written bytes but ${redact(url)} declared Content-Length $contentLength; refusing an '
        'incomplete or oversized file rather than handing it off as if it finished cleanly.',
      );
    }
  }

  /// Single (non-ranged) fetch, used only when the source did not report a
  /// content length. Streams the response body directly to [part]'s `.part`
  /// file (never buffers it fully in memory - the whole point of this
  /// path is that we do not know how big it is), bounded by [hardCapBytes]
  /// or the response's own `Content-Length` when it provides one. A retry
  /// reopens (truncates) [part] first so a partial write from a failed
  /// attempt never leaks into the next one.
  Future<int> fetchOnce(
    String url,
    Map<String, String> headers,
    Map<String, List<CookieEntry>>? cookiesByDomain,
    PartFile part,
    void Function(int received, int? total)? onProgress,
  ) async {
    Object? lastError;
    for (var attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        final response = await get(url, headers, cookiesByDomain, null, null);
        if (response.statusCode >= 400) {
          await response.drain<void>();
          throw StreamDownloadException('HTTP ${response.statusCode} fetching ${redact(url)}');
        }
        _rejectNonMediaContentType(response, url);
        final declaredLength = response.contentLength;
        final total = declaredLength > 0 ? declaredLength : null;
        final cap = total ?? hardCapBytes;
        final bytesWritten = await _streamCapped(response, part.sink, cap, url);
        onProgress?.call(bytesWritten, total);
        return bytesWritten;
      } catch (e) {
        if (e is HandshakeException) throw certificateTrustException(url, e);
        lastError = e;
        if (attempt == maxRetries) break;
        await part.reset();
        await Future.delayed(backoff(attempt));
      }
    }
    throw StreamDownloadException('Failed to fetch ${redact(url)} after $maxRetries attempts: $lastError');
  }

  Future<int> downloadChunked(
    String url,
    Map<String, String> headers,
    Map<String, List<CookieEntry>>? cookiesByDomain,
    PartFile part,
    int contentLength,
    int chunkSize,
    void Function(int received, int? total)? onProgress,
    bool Function() isCancelled,
  ) async {
    var offset = 0;
    var received = 0;
    var chunkIndex = 0;

    while (offset < contentLength) {
      if (isCancelled()) {
        throw const StreamDownloadException('Download cancelled');
      }
      final end = (offset + chunkSize - 1).clamp(0, contentLength - 1);
      final outcome = await _fetchChunkWithRetry(
        url, headers, cookiesByDomain, part, offset, end, onProgress, contentLength, received,
        isFirstChunk: chunkIndex == 0,
      );
      received += outcome.bytesWritten;
      if (outcome.isFullBody) {
        // The server ignored `Range` on the very first request and served
        // the whole file regardless of what we asked for - nothing left
        // to fetch.
        break;
      }
      offset = end + 1;
      chunkIndex++;
    }
    return received;
  }

  Future<FetchOutcome> _fetchChunkWithRetry(
    String url,
    Map<String, String> headers,
    Map<String, List<CookieEntry>>? cookiesByDomain,
    PartFile part,
    int start,
    int end,
    void Function(int received, int? total)? onProgress,
    int total,
    int receivedBeforeChunk, {
    required bool isFirstChunk,
  }) async {
    Object? lastError;
    for (var attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        final response = await get(url, headers, cookiesByDomain, start, end);

        if (response.statusCode == 200) {
          if (!isFirstChunk) {
            // A server that already honored `Range` for earlier chunks and
            // then stops mid-download would otherwise get its full body
            // appended on top of what was already written - duplicating
            // every byte after this point. Refuse instead: this candidate
            // is broken, let the pipeline try another one.
            await response.drain<void>();
            throw StreamDownloadException(
              'HTTP 200 fetching bytes $start-$end of ${redact(url)}: the server stopped honoring Range '
              'mid-download after earlier chunks succeeded.',
            );
          }
          // The server ignored `Range` entirely on the very first request
          // and is serving the whole file regardless of what was asked for
          // - stream it as the complete file (capped at the known total)
          // rather than treating it as merely one chunk.
          _rejectNonMediaContentType(response, url);
          final bytesWritten = await _streamCapped(response, part.sink, total, url);
          onProgress?.call(bytesWritten, total);
          return FetchOutcome(bytesWritten: bytesWritten, isFullBody: true);
        }

        if (response.statusCode != 206) {
          await response.drain<void>();
          throw StreamDownloadException('HTTP ${response.statusCode} fetching bytes $start-$end of ${redact(url)}');
        }

        _requireMatchingContentRangeStart(response, start, url);
        if (isFirstChunk) _rejectNonMediaContentType(response, url);
        final bytes = await _readAll(response);
        if (isFirstChunk) _rejectNonMediaBodyPrefix(bytes, url);
        part.sink.add(bytes);
        onProgress?.call(receivedBeforeChunk + bytes.length, total);
        return FetchOutcome(bytesWritten: bytes.length, isFullBody: false);
      } catch (e) {
        if (e is HandshakeException) throw certificateTrustException(url, e);
        lastError = e;
        if (attempt == maxRetries) break;
        if (isFirstChunk) {
          // Only the first chunk can ever have written partial bytes
          // directly to `part.sink` before failing (the full-body 200
          // branch above streams incrementally); every later chunk fully
          // buffers via `_readAll` before a single `.add()` call, so
          // nothing partial ever reaches disk for it. Resetting here when
          // nothing was actually written is a harmless no-op.
          await part.reset();
        }
        await Future.delayed(backoff(attempt));
      }
    }
    throw StreamDownloadException('Failed to fetch bytes $start-$end after $maxRetries attempts: $lastError');
  }

  /// Requires a 206 response's own `Content-Range` header to confirm it
  /// actually starts at [start] - the byte offset this app itself
  /// requested. A broken/malicious server could otherwise answer 206 (so
  /// the naive "status looks fine" check passes) while actually returning
  /// some other slice of the file entirely, silently writing the wrong
  /// bytes at this position.
  void _requireMatchingContentRangeStart(HttpClientResponse response, int start, String url) {
    final contentRange = response.headers.value('content-range');
    final match = contentRange == null ? null : RegExp(r'^bytes (\d+)-').firstMatch(contentRange);
    if (match == null || int.parse(match.group(1)!) != start) {
      throw StreamDownloadException(
        'HTTP 206 fetching bytes starting at $start of ${redact(url)} came back with an unexpected or '
        'missing Content-Range ("${contentRange ?? '(none)'}"); refusing rather than risk writing the '
        'wrong bytes at this position.',
      );
    }
  }

  /// Refuses [response] outright (before any of its body is read) when its
  /// `Content-Type` is one of [_nonMediaContentTypes] - an error page or
  /// API response saved with a `.mp4`/whatever extension is worse than no
  /// file at all, since it looks "downloaded successfully" until something
  /// tries to actually play it. A missing `Content-Type` is not itself
  /// suspicious (plenty of CDNs omit it for a plain range response) and is
  /// waved through; only an *explicit*, exactly-matching non-media type is
  /// rejected, since real video/audio Content-Types are too varied
  /// (`video/mp4`, `application/octet-stream`, vendor-specific strings, ...)
  /// to usefully allowlist instead.
  void _rejectNonMediaContentType(HttpClientResponse response, String url) {
    final raw = response.headers.value('content-type');
    if (raw == null) return;
    final contentType = raw.toLowerCase().split(';').first.trim();
    if (_nonMediaContentTypes.contains(contentType)) {
      throw StreamDownloadException(
        'Refusing to download ${redact(url)}: the server responded with Content-Type "$contentType" '
        '(looks like an error page or API response, not video/audio data).',
      );
    }
  }

  /// Streams [response]'s body into [sink] incrementally (never buffers
  /// the whole thing in memory first), refusing once more than [cap]
  /// bytes have arrived - a compromised/misbehaving server could otherwise
  /// exhaust memory (buffering) or disk (unbounded write) by simply never
  /// ending the response body. The very first chunk is also checked
  /// against [_rejectNonMediaBodyPrefix] before it is written, on top of
  /// [_rejectNonMediaContentType]'s header-only check - a mislabeled or
  /// absent Content-Type does not stop the body itself from being an
  /// obvious HTML/JSON/HLS-playlist text body.
  Future<int> _streamCapped(HttpClientResponse response, IOSink sink, int cap, String url) async {
    var written = 0;
    var checkedPrefix = false;
    await for (final bytes in response) {
      if (!checkedPrefix) {
        checkedPrefix = true;
        _rejectNonMediaBodyPrefix(bytes, url);
      }
      written += bytes.length;
      if (written > cap) {
        throw StreamDownloadException(
          'Refusing to write more than $cap bytes fetching ${redact(url)}: the response body exceeded its '
          'declared/allowed size.',
        );
      }
      sink.add(bytes);
    }
    return written;
  }

  Future<List<int>> _readAll(HttpClientResponse response) async {
    final builder = BytesBuilder(copy: false);
    await for (final bytes in response) {
      builder.add(bytes);
    }
    return builder.takeBytes();
  }

  /// Refuses a response body whose very first bytes look like text meant
  /// to be read, not media meant to be played: a raw `<` (HTML/XML), `{`
  /// (a JSON error body), or a literal `#EXTM3U` (an HLS playlist fetched
  /// as if it were a plain file) - checked on the leading bytes only (a
  /// real video/audio file never starts with any of these), so this never
  /// touches the bulk of a legitimate download.
  void _rejectNonMediaBodyPrefix(List<int> firstBytes, String url) {
    var start = 0;
    while (start < firstBytes.length && _whitespaceBytes.contains(firstBytes[start])) {
      start++;
    }
    if (start >= firstBytes.length) return;
    final first = firstBytes[start];
    final looksLikeMarkup = first == 0x3C; // '<'
    final looksLikeJson = first == 0x7B; // '{'
    final looksLikePlaylist = String.fromCharCodes(firstBytes.skip(start).take(7)) == '#EXTM3U';
    if (looksLikeMarkup || looksLikeJson || looksLikePlaylist) {
      throw StreamDownloadException(
        'Refusing to download ${redact(url)}: its body starts with '
        '"${String.fromCharCodes(firstBytes.skip(start).take(16))}" (looks like HTML/JSON/an HLS playlist, '
        'not video/audio data).',
      );
    }
  }
}
