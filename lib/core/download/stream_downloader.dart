import 'dart:io';
import 'dart:typed_data';

import '../net/host_policy.dart';
import '../utils/url_parser.dart';

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
/// half-written one behind.
class StreamDownloader {
  final HttpClient _httpClient;
  final int chunkSize;
  final int maxRetries;
  final Duration Function(int attempt) backoff;

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
  })  : _httpClient = httpClient ?? HttpClient(),
        backoff = backoff ?? _defaultBackoff;

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
  }) async {
    final partPath = '$outputPath.part';
    final sink = File(partPath).openWrite();
    var received = 0;
    var succeeded = false;

    try {
      if (contentLength == null || contentLength <= 0) {
        // Source did not report a size (or reported zero): fetch in one
        // shot, we cannot chunk what we don't know the extent of.
        received = await _fetchOnce(url, headers, sink, onProgress, null);
      } else {
        var offset = 0;
        while (offset < contentLength) {
          if (cancelToken?.isCancelled ?? false) {
            throw const StreamDownloadException('Download cancelled');
          }
          final end = (offset + chunkSize - 1).clamp(0, contentLength - 1);
          received += await _fetchChunkWithRetry(
            url,
            headers,
            offset,
            end,
            sink,
            onProgress,
            contentLength,
            received,
          );
          offset = end + 1;
        }
      }
      succeeded = true;
    } finally {
      await sink.close();
      if (!succeeded) {
        await _tryDeleteFile(partPath);
      }
    }

    await File(partPath).rename(outputPath);
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

  /// Single (non-ranged) fetch, used only when the source did not report a
  /// content length. Retried the same way as a chunk: the whole response is
  /// buffered in memory before a single write to [sink], so a retry after a
  /// mid-stream failure cannot duplicate or corrupt already-written bytes.
  Future<int> _fetchOnce(
    String url,
    Map<String, String> headers,
    IOSink sink,
    void Function(int received, int? total)? onProgress,
    int? total,
  ) async {
    Object? lastError;
    for (var attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        final response = await _get(url, headers, null, null);
        if (response.statusCode >= 400) {
          throw StreamDownloadException(
            'HTTP ${response.statusCode} fetching ${_redact(url)}',
          );
        }
        final bytes = await _readAll(response);
        sink.add(bytes);
        onProgress?.call(bytes.length, total);
        return bytes.length;
      } catch (e) {
        lastError = e;
        if (attempt == maxRetries) break;
        await Future.delayed(backoff(attempt));
      }
    }
    throw StreamDownloadException(
      'Failed to fetch ${_redact(url)} after $maxRetries attempts: $lastError',
    );
  }

  Future<int> _fetchChunkWithRetry(
    String url,
    Map<String, String> headers,
    int start,
    int end,
    IOSink sink,
    void Function(int received, int? total)? onProgress,
    int total,
    int receivedBeforeChunk,
  ) async {
    Object? lastError;
    for (var attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        final response = await _get(url, headers, start, end);
        if (response.statusCode != 206 && response.statusCode != 200) {
          throw StreamDownloadException(
            'HTTP ${response.statusCode} fetching bytes $start-$end of ${_redact(url)}',
          );
        }
        final bytes = await _readAll(response);
        sink.add(bytes);
        onProgress?.call(receivedBeforeChunk + bytes.length, total);
        return bytes.length;
      } catch (e) {
        lastError = e;
        if (attempt == maxRetries) break;
        await Future.delayed(backoff(attempt));
      }
    }
    throw StreamDownloadException(
      'Failed to fetch bytes $start-$end after $maxRetries attempts: $lastError',
    );
  }

  Future<List<int>> _readAll(HttpClientResponse response) async {
    final builder = BytesBuilder(copy: false);
    await for (final bytes in response) {
      builder.add(bytes);
    }
    return builder.takeBytes();
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
