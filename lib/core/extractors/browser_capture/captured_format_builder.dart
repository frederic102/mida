import 'dart:convert';
import 'dart:io';

import '../../net/host_policy.dart';
import '../generic/hls_playlist_parser.dart';
import '../media_models.dart';
import 'captured_media_classifier.dart';
import 'format_capabilities.dart';

/// Turns [CapturedMediaCandidate]s into playable [MediaFormat]s. Split out
/// of `BrowserCaptureExtractor` (which owns capture/ranking) to keep both
/// files under this project's 400-line cap; this half owns the one piece
/// of the pipeline that makes its own HTTP requests (fetching an `m3u8`
/// candidate to check whether it is a master playlist).
///
/// `BrowserCaptureExtractor` already calls `HostPolicy.assertAllowedHost`
/// on every candidate before handing it here, but this class routes its
/// own fetch through `HostPolicy.guardedRequest` too (council follow-up):
/// it must be safe to use on its own, not only behind that pre-check, and
/// a redirect the pre-check never sees still needs a per-hop re-check.
class CapturedFormatBuilder {
  final HttpClient Function() _httpClientFactory;

  /// Test-only escape hatch for the SSRF guard in [_fetchText], so a test
  /// can point a master-playlist fetch at a local fixture server (see
  /// `HostPolicy.guardedRequest`: exempts only hop 0). Production code
  /// must never set this to true.
  final bool allowPrivateHosts;

  CapturedFormatBuilder({
    HttpClient Function()? httpClientFactory,
    this.allowPrivateHosts = false,
  }) : _httpClientFactory = httpClientFactory ?? HttpClient.new;

  static final RegExp _streamInfPattern = RegExp(r'^#EXT-X-STREAM-INF:(.*)$', caseSensitive: false);
  static final RegExp _codecsAttrPattern = RegExp(r'''CODECS="([^"]*)"''', caseSensitive: false);

  /// Turns one candidate into one or more [MediaFormat]s. An `m3u8` URL is
  /// fetched (with the same headers the page's requests carried) and, if
  /// it is a master playlist, expanded into one format per
  /// `#EXT-X-STREAM-INF` variant, matching the generic extractor's format
  /// model; everything else (media-playlist `m3u8`, `mpd`, `mp4`, `webm`)
  /// is exposed as a single format.
  Future<List<MediaFormat>> expandFormats(CapturedMediaCandidate candidate, Map<String, String> headers) async {
    final directCaps = FormatCapabilities.fromMimeType(candidate.mimeType);
    if (candidate.container != 'm3u8') {
      return [_formatFor(id: candidate.url, url: candidate.url, container: candidate.container, caps: directCaps)];
    }

    String playlistText;
    try {
      playlistText = await _fetchText(Uri.parse(candidate.url), headers);
    } on MediaExtractionException {
      // An SSRF-blocked host must surface as a real failure, not get
      // silently swapped for a placeholder format that still points at
      // the same blocked URL (which some later caller could then fetch
      // unguarded).
      rethrow;
    } catch (_) {
      return [_formatFor(id: candidate.url, url: candidate.url, container: 'm3u8', caps: directCaps)];
    }

    final variants = HlsPlaylistParser.parseMasterVariants(playlistText, Uri.parse(candidate.url));
    if (variants.isEmpty) {
      return [_formatFor(id: candidate.url, url: candidate.url, container: 'm3u8', caps: directCaps)];
    }

    final codecsByVariant = _variantCodecsInOrder(playlistText);
    return [
      for (var i = 0; i < variants.length; i++)
        _formatFor(
          id: '${candidate.url}#$i',
          url: variants[i].url,
          container: 'm3u8',
          width: variants[i].width,
          height: variants[i].height,
          bitrate: variants[i].bandwidth,
          caps: FormatCapabilities.fromHlsCodecs(i < codecsByVariant.length ? codecsByVariant[i] : null),
        ),
    ];
  }

  /// Extracts each `#EXT-X-STREAM-INF` line's `CODECS="..."` attribute, in
  /// the same top-to-bottom order `HlsPlaylistParser.parseMasterVariants`
  /// produces its variant list, so index i here lines up with variant i
  /// there. `HlsPlaylistParser` does not expose this attribute itself
  /// (left unedited per this phase's file-ownership rule); this is a
  /// narrow, independent second pass over the same text for the one field
  /// it lacks; both walks agree on what counts as a variant line.
  List<String?> _variantCodecsInOrder(String playlistText) {
    final codecsByVariant = <String?>[];
    for (final line in playlistText.split(RegExp(r'\r?\n'))) {
      final match = _streamInfPattern.firstMatch(line.trim());
      if (match == null) continue;
      codecsByVariant.add(_codecsAttrPattern.firstMatch(match.group(1)!)?.group(1));
    }
    return codecsByVariant;
  }

  Future<String> _fetchText(Uri url, Map<String, String> headers) async {
    final client = _httpClientFactory();
    try {
      final response = await HostPolicy.guardedRequest(
        client,
        url,
        useHead: false,
        allowPrivateHosts: allowPrivateHosts,
        configureRequest: (request) => headers.forEach(request.headers.set),
      );
      final bytes = await response.fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk));
      try {
        return utf8.decode(bytes);
      } on FormatException {
        return latin1.decode(bytes);
      }
    } finally {
      client.close(force: true);
    }
  }

  MediaFormat _formatFor({
    required String id,
    required String url,
    required String container,
    int? width,
    int? height,
    int? bitrate,
    FormatCapabilities caps = FormatCapabilities.muxed,
  }) {
    return MediaFormat(
      id: id,
      url: url,
      container: container,
      width: width,
      height: height,
      bitrate: bitrate ?? 0,
      hasVideo: caps.hasVideo,
      hasAudio: caps.hasAudio,
    );
  }
}
