import '../media_models.dart';
import 'format_expander.dart';
import 'html_media_sniffer.dart';
import 'media_url_probe.dart';
import 'stage_deadline.dart';

/// Candidate handling for one `GenericExtractor.extract()` call, split out
/// of `generic_extractor.dart` to keep it under the 400-line cap: filters
/// sniffed candidates (false-positive guard), expands them into formats,
/// and decides between `DRM_PROTECTED` and `NO_MEDIA_FOUND` once every
/// discovery step has come up empty.
///
/// A candidate set that ends with zero usable formats is "nothing found
/// yet", never a result: [buildIfUsable] returns null so the caller keeps
/// looking (platform chain, iframe follow). DRM evidence seen on the way
/// (a manifest body carrying key material) is remembered in
/// [manifestDrmSeen] and only decides the final status in
/// [noMediaOrDrm], so a DRM-wrapped decoy cannot shadow a working embed.
class GenericCandidateBuilder {
  final MediaUrlProbe probe;
  final FormatExpander expander;
  final StageDeadline deadline;

  /// True once any expanded candidate reported DRM key material.
  bool manifestDrmSeen = false;

  GenericCandidateBuilder({required this.probe, required this.expander, required this.deadline});

  /// Reachability-probe guard: caps how many non-context-backed candidates
  /// (see `SniffedMedia.contextBacked`) get an actual HEAD/Range network
  /// probe per `extract()` call, on top of the sniffer's own 200-candidate
  /// cap: a page with dozens of bare URL-shaped matches must not turn into
  /// dozens of extra HTTP round-trips.
  static const int maxReachabilityProbes = 10;

  static final RegExp _emePattern = RegExp(r'\bEME\b', caseSensitive: false);
  static const List<String> _drmMarkers = [
    'widevine',
    'playready',
    'fairplay',
    'encrypted-media',
    'license_url',
  ];

  static const MediaExtractionException drmProtected = MediaExtractionException(
    'DRM_PROTECTED',
    'This video is protected by DRM (Widevine, PlayReady, or FairPlay) and cannot be downloaded.',
  );

  /// A [MediaInfo] built from the candidates of [sniffed], or null when
  /// none yields at least one format. Candidates the sniffer itself vouches
  /// for (`contextBacked`) are expanded FIRST. Bare candidates (found only
  /// by the raw-text catch-all, or a bare URL-shaped JSON string with no
  /// player-ish metadata around it) must pass a reachability probe before
  /// they are expanded. When the vouched-for ones already yielded formats,
  /// the bare ones are optional extras (an HLS ladder next to a plain
  /// `<video src>`, say) and get at most half of the remaining stage time:
  /// a slow or stalling probe can never starve a working result.
  Future<MediaInfo?> buildIfUsable(
    Uri sourceUrl,
    HtmlSniffResult sniffed, {
    required Map<String, String> requestHeaders,
    Map<String, String>? playlistFetchHeaders,
  }) async {
    if (sniffed.isEmpty) return null;
    final contextBacked = sniffed.mediaUrls.where((c) => c.contextBacked).toList();
    final bare = sniffed.mediaUrls.where((c) => !c.contextBacked).toList();
    final formats = await _expandAll(contextBacked, playlistFetchHeaders);
    if (formats.isEmpty) {
      formats.addAll(await _expandAll(await _probeBare(bare), playlistFetchHeaders));
    } else if (bare.isNotEmpty) {
      final extras = <MediaFormat>[];
      var open = true;
      Future<void> collect() async {
        for (final candidate in await _probeBare(bare, stillWanted: () => open)) {
          if (!open) return;
          extras.addAll(await _expandAll([candidate], playlistFetchHeaders));
        }
      }

      await collect().timeout(deadline.remaining ~/ 2, onTimeout: () => open = false);
      open = false;
      formats.addAll(List.of(extras));
    }
    if (formats.isEmpty) return null;
    return MediaInfo(
      id: idFromUrl(sourceUrl),
      title: sniffed.title ?? lastSegmentOrUrl(sourceUrl),
      thumbnailUrl: sniffed.thumbnailUrl,
      sourceUrl: sourceUrl,
      formats: expander.orderFormats(formats),
      requestHeaders: requestHeaders,
    );
  }

  Future<List<MediaFormat>> _expandAll(List<SniffedMedia> candidates, Map<String, String>? headers) async {
    final formats = <MediaFormat>[];
    for (final media in candidates) {
      final expanded = await expander.expandFormats(
        media.url,
        media.container,
        extraHeaders: headers,
        width: media.width,
        height: media.height,
        bitrate: media.bitrate,
        capabilities: media.capabilities,
      );
      manifestDrmSeen = manifestDrmSeen || expanded.drmDetected;
      formats.addAll(expanded.formats);
    }
    return formats;
  }

  Future<List<SniffedMedia>> _probeBare(List<SniffedMedia> bare, {bool Function()? stillWanted}) async {
    final probed = <SniffedMedia>[];
    for (final candidate in bare.take(maxReachabilityProbes)) {
      if (stillWanted != null && !stillWanted()) break;
      final parsed = Uri.tryParse(candidate.url);
      if (parsed == null) continue;
      if (await probe.isPlausibleMediaCandidate(parsed, deadline: deadline)) probed.add(candidate);
    }
    return probed;
  }

  /// The terminal outcome once every discovery step found nothing usable:
  /// `DRM_PROTECTED` when DRM markers are in [corpus], any candidate was
  /// dropped as DRM-wrapped, or a manifest body carried key material;
  /// else `NO_MEDIA_FOUND`.
  MediaExtractionException noMediaOrDrm(String corpus, {bool anyDrmCandidatesDropped = false}) {
    final lower = corpus.toLowerCase();
    final hasDrmMarker = anyDrmCandidatesDropped ||
        manifestDrmSeen ||
        _drmMarkers.any(lower.contains) ||
        _emePattern.hasMatch(corpus);
    if (hasDrmMarker) return drmProtected;
    return const MediaExtractionException(
      'NO_MEDIA_FOUND',
      'No video found on this page. The site may load video only after '
          'sign-in or interaction. Try the direct video URL if you have it.',
    );
  }

  static String idFromUrl(Uri url) => 'generic-${url.toString().hashCode.toUnsigned(31)}';

  static String lastSegmentOrUrl(Uri url) {
    final segments = url.pathSegments.where((s) => s.isNotEmpty).toList();
    return segments.isEmpty ? url.toString() : segments.last;
  }
}
