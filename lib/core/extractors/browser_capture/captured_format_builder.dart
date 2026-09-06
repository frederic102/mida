import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../net/host_policy.dart';
import '../generic/hls_master_format_mapper.dart';
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

  /// Turns one candidate into one or more [MediaFormat]s. An `m3u8` URL is
  /// fetched (with the same headers the page's requests carried) and, if
  /// it is a master playlist, expanded via [HlsMasterFormatMapper] - one
  /// format per `#EXT-X-STREAM-INF` variant (video-only + a paired
  /// audio-only format when the master splits audio into its own
  /// `#EXT-X-MEDIA` rendition group, muxed otherwise), matching the generic
  /// extractor's format model; everything else (media-playlist `m3u8`,
  /// `mpd`, `mp4`, `webm`) is exposed as a single format.
  Future<List<MediaFormat>> expandFormats(CapturedMediaCandidate candidate, Map<String, String> headers) async {
    final directCaps = FormatCapabilities.fromMimeType(candidate.mimeType);
    if (candidate.container != 'm3u8') {
      // `capabilitiesUnknown` only when [directCaps] is itself an
      // unconfirmed guess (the container's own mimeType said nothing
      // decisive) - phase 6 P3: this is the selector
      // `FormatCapabilityResolver` uses to decide which mp4/m4a candidates
      // are worth an ffprobe-by-bytes sniff. Round 2 P-R7 (Vigil#2): `m4a`
      // belongs in this list too - a direct `.m4a` candidate with no
      // decisive mimeType is exactly as unconfirmed as an `.mp4`/`.webm`
      // one (its `FormatCapabilities.fromMimeType` default is still the
      // safe muxed guess, which is wrong for almost every real m4a).
      final capsUnknown = (candidate.container == 'mp4' || candidate.container == 'webm' || candidate.container == 'm4a') &&
          !(candidate.mimeType?.toLowerCase().startsWith('audio/') ?? false);
      return [
        _formatFor(
          id: candidate.url,
          url: candidate.url,
          container: candidate.container,
          caps: directCaps,
          capabilitiesUnknown: capsUnknown,
        ),
      ];
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

    final mapped = HlsMasterFormatMapper.formatsFor(candidate.url, playlistText, defaultCaps: directCaps);
    if (mapped.isEmpty) {
      return [_formatFor(id: candidate.url, url: candidate.url, container: 'm3u8', caps: directCaps)];
    }
    return mapped;
  }

  /// Round 2 P-R6 (Codex#18): caps how much of a manifest response this
  /// fetch ever holds in memory. A real HLS master/media playlist is plain
  /// text and always well under this; the cap exists for whatever a
  /// misbehaving/attacker-controlled endpoint decides to send in its place
  /// (unbounded body would otherwise buffer entirely before this method
  /// ever got a chance to look at it).
  static const int _maxManifestBytes = 1024 * 1024;

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
      final bytes = await _readBounded(client, response);
      try {
        return utf8.decode(bytes);
      } on FormatException {
        return latin1.decode(bytes);
      }
    } finally {
      client.close(force: true);
    }
  }

  /// Streams [response] into memory up to [_maxManifestBytes]. The moment
  /// that cap would be crossed, the subscription is cancelled and [client]
  /// is force-closed right there - not after draining the rest of the body
  /// first - so an oversized response stops costing bytes/sockets the
  /// instant it is detected, rather than being read to completion and
  /// merely truncated afterward.
  Future<List<int>> _readBounded(HttpClient client, HttpClientResponse response) async {
    final bytes = <int>[];
    final completer = Completer<void>();
    late final StreamSubscription<List<int>> subscription;
    subscription = response.listen(
      (chunk) {
        final remaining = _maxManifestBytes - bytes.length;
        if (remaining <= 0) return; // already at cap; any further chunk is dropped
        bytes.addAll(remaining >= chunk.length ? chunk : chunk.sublist(0, remaining));
        if (bytes.length >= _maxManifestBytes) {
          subscription.cancel();
          client.close(force: true);
          if (!completer.isCompleted) completer.complete();
        }
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete();
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!completer.isCompleted) completer.completeError(error, stackTrace);
      },
      cancelOnError: true,
    );
    await completer.future;
    return bytes;
  }

  MediaFormat _formatFor({
    required String id,
    required String url,
    required String container,
    int? width,
    int? height,
    int? bitrate,
    FormatCapabilities caps = FormatCapabilities.muxed,
    bool capabilitiesUnknown = false,
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
      capabilitiesUnknown: capabilitiesUnknown,
    );
  }
}
