import 'dart:io';

import 'generic_http.dart';
import '../../net/host_policy.dart';

/// Step 0 of the generic-extractor detection order
/// (`docs/plan-generic-extractor.md`): decide whether the input URL is
/// itself a media file, either by its file extension (no network) or, if
/// that is inconclusive, by the Content-Type the server reports.
class MediaUrlProbe {
  final HttpClient Function() _httpClientFactory;

  /// Test-only escape hatch for [HostPolicy]'s SSRF guard so tests can
  /// point this probe straight at a local fixture `HttpServer` (a single
  /// hop, no redirect involved). Any redirect hop is still always
  /// checked regardless of this flag (see `HostPolicy.guardedRequest`).
  /// Production code must never set this to true.
  final bool allowPrivateHosts;

  MediaUrlProbe({
    HttpClient Function()? httpClientFactory,
    this.allowPrivateHosts = false,
  }) : _httpClientFactory = httpClientFactory ?? HttpClient.new;

  /// Every extension the generic extractor recognizes as "this URL is
  /// media", per the plan's step-0 list. Also used by the HTML sniffer to
  /// gate which URLs found in a page it accepts as candidates (the same
  /// allowlist keeps a tracker/analytics URL out of the results).
  static const Set<String> extensionContainers = {
    'mp4',
    'webm',
    'mkv',
    'mov',
    'm4v',
    'm3u8',
    'mpd',
    'mp3',
    'm4a',
  };

  static const Map<String, String> _contentTypeContainers = {
    'video/mp4': 'mp4',
    'video/webm': 'webm',
    'video/x-matroska': 'mkv',
    'video/quicktime': 'mov',
    'application/vnd.apple.mpegurl': 'm3u8',
    'application/x-mpegurl': 'm3u8',
    'application/dash+xml': 'mpd',
    'audio/mpeg': 'mp3',
    'audio/mp4': 'm4a',
  };

  /// The container implied by [url]'s path extension, or null if the
  /// extension is missing/unrecognized (query string is ignored).
  static String? containerFromExtension(Uri url) {
    final path = url.path.toLowerCase();
    final dot = path.lastIndexOf('.');
    if (dot == -1 || dot == path.length - 1) return null;
    final ext = path.substring(dot + 1);
    return extensionContainers.contains(ext) ? ext : null;
  }

  /// HEAD (falling back to GET when the server rejects HEAD with a 4xx/5xx)
  /// and maps the response Content-Type to a container. Returns null when
  /// the Content-Type is missing or not a recognized media type.
  Future<String?> containerFromContentType(Uri url) async {
    final client = _httpClientFactory();
    try {
      var response = await _send(client, url, useHead: true);
      if (response.statusCode >= 400) {
        await response.drain<void>();
        response = await _send(client, url, useHead: false);
      }
      final contentType = response.headers.contentType?.mimeType.toLowerCase();
      await response.drain<void>();
      if (contentType == null) return null;
      final known = _contentTypeContainers[contentType];
      if (known != null) return known;
      final isMedia = contentType.startsWith('video/') || contentType.startsWith('audio/');
      return isMedia ? contentType.split('/').last : null;
    } finally {
      client.close(force: true);
    }
  }

  Future<HttpClientResponse> _send(HttpClient client, Uri url, {required bool useHead}) {
    return HostPolicy.guardedRequest(
      client,
      url,
      useHead: useHead,
      allowPrivateHosts: allowPrivateHosts,
      configureRequest: (request) {
        request.headers.set('User-Agent', genericDesktopUserAgent);
        request.headers.set('Accept-Language', genericAcceptLanguage);
      },
    );
  }
}
