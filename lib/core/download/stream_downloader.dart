import 'dart:io';

import '../extractors/media_models.dart';
import '../net/cookie_scope.dart';
import '../net/host_policy.dart';
import '../utils/file_mover.dart';
import '../utils/url_parser.dart';
import 'stream_body_writer.dart';

/// Lets a caller abort an in-progress [StreamDownloader.download] between
/// chunks. Cooperative: checked once per chunk, not mid-chunk.
class CancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

class StreamDownloadException implements Exception {
  final String message;
  const StreamDownloadException(this.message);

  @override
  String toString() => 'StreamDownloadException: $message';
}

/// Downloads one format URL to disk. YouTube (and most CDNs fronting it)
/// serve large files fine via chunked `Range` GETs but flake on very long
/// single connections, so this fetches in fixed-size chunks with retry.
///
/// Writes to `<outputPath>.part` and renames on completion so a crash
/// mid-download never leaves a file that looks finished; a failed or
/// cancelled download deletes the `.part` file rather than leaving a
/// half-written one behind. The actual byte-level fetch/write work (and
/// what a 200-instead-of-206 or a mismatched `Content-Range` mean) lives
/// in [StreamBodyWriter] - this class owns the URL/redirect/host-check/TLS
/// side instead, to stay under this project's 400-line file cap.
class StreamDownloader {
  final HttpClient _httpClient;
  final int chunkSize;
  final int maxRetries;
  final Duration Function(int attempt) backoff;
  final FileMover _fileMover;
  late final StreamBodyWriter _body;

  /// Exempts only redirect hop 0 (the URL the caller explicitly asked for)
  /// from the https-only and private-host checks - lets tests point this
  /// at a local `http://127.0.0.1` fixture server. Every hop reached via a
  /// redirect is always checked regardless, so a public URL that redirects
  /// to a private/loopback address is still refused even in a test that
  /// sets this. Production code must never set this to true.
  final bool allowPrivateHosts;

  static const int _maxRedirectHops = 5;

  StreamDownloader({
    HttpClient? httpClient,
    this.chunkSize = 10 * 1024 * 1024,
    this.maxRetries = 3,
    Duration Function(int attempt)? backoff,
    this.allowPrivateHosts = false,
    FileMover? fileMover,
  })  : _httpClient = httpClient ?? HttpClient(),
        backoff = backoff ?? _defaultBackoff,
        _fileMover = fileMover ?? FileMover() {
    _body = StreamBodyWriter(
      get: _get,
      maxRetries: maxRetries,
      backoff: this.backoff,
      redact: _redact,
      certificateTrustException: _certificateTrustException,
    );
  }

  static Duration _defaultBackoff(int attempt) => Duration(seconds: 1 << (attempt - 1));

  /// Closes the underlying `HttpClient`. Callers that create a
  /// [StreamDownloader] per download (`MediaDownloadPipeline` does, via its
  /// `downloaderFactory`) must call this once done with it - an unclosed
  /// `HttpClient` keeps its connection pool (and the process) alive.
  void close() => _httpClient.close(force: true);

  Future<void> download({
    required String url,
    required String outputPath,
    Map<String, String> headers = const {},
    int? contentLength,
    void Function(int received, int? total)? onProgress,
    CancelToken? cancelToken,
    Map<String, List<CookieEntry>>? cookiesByDomain,
  }) async {
    final partPath = '$outputPath.part';
    final part = PartFile(partPath);
    var succeeded = false;
    var written = 0;

    try {
      if (contentLength == null || contentLength <= 0) {
        // Source did not report a size (or reported zero): fetch in one
        // shot, we cannot chunk what we don't know the extent of.
        written = await _body.fetchOnce(url, headers, cookiesByDomain, part, onProgress);
      } else {
        written = await _body.downloadChunked(
          url,
          headers,
          cookiesByDomain,
          part,
          contentLength,
          chunkSize,
          onProgress,
          () => cancelToken?.isCancelled ?? false,
        );
      }
      _body.verifyCompleteLength(written, contentLength, url);
      succeeded = true;
    } finally {
      await part.close();
      if (!succeeded) {
        await _tryDeleteFile(partPath);
      }
    }

    // Goes through FileMover (not a bare File.rename) so a transient
    // Windows AV/indexer lock on the file that just finished writing -
    // live-caught: `PathAccessException` right after a large download -
    // gets retried instead of crashing the whole download.
    await _fileMover.move(partPath, outputPath);
  }

  Future<void> _tryDeleteFile(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Best effort cleanup only; a leaked .part is a cosmetic issue, not
      // worth masking the real failure that got us here.
    }
  }

  /// A TLS handshake failure (an untrusted/expired/mismatched certificate
  /// on the CDN's own end - observed live: vk.com's video CDN, okcdn.ru)
  /// is not transient like a dropped connection or a 5xx; the same
  /// handshake will fail identically on every retry, so this is thrown
  /// immediately instead of exhausting [maxRetries] and backoff delays for
  /// no reason. What/why/next, never a raw `HandshakeException` dump: this
  /// app never disables certificate verification to work around one - see
  /// docs/plan-phase5-coverage.md Lane A follow-up.
  StreamDownloadException _certificateTrustException(String url, HandshakeException cause) {
    return StreamDownloadException(
      "This site's video server uses a certificate your system does not trust "
      '(TLS handshake failed for ${_redact(url)}). This is a problem with that '
      'server\'s certificate, not with this app, and this app will not bypass '
      'certificate checks to work around it - retrying will not help either. '
      'If you believe this site is legitimate, check your system clock and root '
      'certificate store, or try again later.',
    );
  }

  /// Fetches [url], following redirects manually (rather than trusting
  /// `HttpClientRequest.followRedirects`) so every hop - not just the
  /// first URL - is re-checked against the https-only and private-host
  /// policy before being fetched. Stream URLs carry signed tokens; sending
  /// them over plain http would leak them to anyone on the network path,
  /// and a redirect to a private/loopback address would let a compromised
  /// or malicious CDN turn this app into an SSRF proxy against its own
  /// host/LAN.
  Future<HttpClientResponse> _get(
    String url,
    Map<String, String> headers,
    Map<String, List<CookieEntry>>? cookiesByDomain,
    int? start,
    int? end,
  ) async {
    var uri = Uri.parse(url);
    HttpClientResponse? response;

    for (var hop = 0; hop <= _maxRedirectHops; hop++) {
      _requireAllowedUrl(uri, exempt: allowPrivateHosts && hop == 0);

      final request = await _httpClient.getUrl(uri);
      request.followRedirects = false;
      headers.forEach(request.headers.set);
      // Recomputed per hop (not once up front): a redirect can land on a
      // different host than [url] itself, and [headers]'s own `Cookie` (if
      // any - `MediaInfo.requestHeaders`'s fallback for every extractor
      // that has not adopted [cookiesByDomain] yet) must not simply ride
      // along onto that new host unexamined.
      if (cookiesByDomain != null) {
        final scoped = CookieScope.headerFor(uri, cookiesByDomain);
        if (scoped.isNotEmpty) request.headers.set('Cookie', scoped);
      }
      if (start != null && end != null) {
        request.headers.set('Range', 'bytes=$start-$end');
      }
      response = await request.close();

      final location = response.headers.value('location');
      final isRedirect = response.statusCode >= 300 && response.statusCode < 400 && location != null;
      if (!isRedirect || hop == _maxRedirectHops) return response;

      await response.drain<void>();
      uri = uri.resolve(location);
    }
    return response!;
  }

  /// [exempt] (only ever true for redirect hop 0, and only when
  /// [allowPrivateHosts] is set) skips both checks entirely - the escape
  /// hatch tests use to point at a local `http://127.0.0.1` fixture
  /// server. Every other hop is always checked, `allowPrivateHosts` or not.
  void _requireAllowedUrl(Uri uri, {required bool exempt}) {
    if (exempt) return;
    if (uri.scheme != 'https') {
      throw StreamDownloadException('Refusing a non-https URL: ${_redact(uri.toString())}');
    }
    if (HostPolicy.isDisallowedHost(uri)) {
      throw StreamDownloadException(
        'Refusing a private/loopback/link-local host: ${_redact(uri.toString())}',
      );
    }
  }

  String _redact(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    return UrlParser.stripQuery(uri).toString();
  }
}
