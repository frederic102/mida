import '../generic/drm_playlist_scanner.dart';
import '../generic/facebook_efg_decoder.dart';
import '../generic/format_expander.dart';
import '../media_models.dart';
import '../reddit/reddit_dash_manifest_parser.dart';
import 'facebook_video_json_parser.dart';

/// [FacebookFormatBuilder.build]'s result: the formats, plus whether a
/// DASH manifest was dropped for carrying DRM signals (so the extractor
/// can say `DRM_PROTECTED` instead of a generic failure when nothing else
/// was left).
class FacebookFormats {
  final List<MediaFormat> formats;
  final bool drmDetected;

  const FacebookFormats({required this.formats, required this.drmDetected});
}

/// Turns one [FacebookVideoNode] into [MediaFormat]s with honest
/// capabilities, reusing the project's existing DASH/DRM helpers rather
/// than a Facebook copy of them:
///
/// - Progressive (`browser_native_hd_url`/`sd_url`, `playable_url*`,
///   `progressive_urls[]`): the web player plays these as a single file,
///   so they are offered as muxed mp4 but flagged
///   [MediaFormat.capabilitiesUnknown] - nothing in the page positively
///   states the file has sound, and `FormatCapabilityResolver` sniffs the
///   real tracks (and fills in the height) before selection. The `efg`
///   decoder is deliberately not applied here: a progressive file's
///   `vencode_tag` can carry `gen2_720p`-style tokens that decoder reads
///   as video-only.
/// - Inline DASH (`dash_manifest`): DRM-scanned with
///   `DrmPlaylistScanner.isMpdDrmProtected`, then read by
///   `RedditDashManifestParser` (the same flat `AdaptationSet >
///   Representation > BaseURL` shape; Facebook's `BaseURL`s are absolute,
///   so the base is empty). Each representation is a whole mp4 file, the
///   video-only or audio-only half of a pair (phase 6): capabilities come
///   from the manifest's own `mimeType`, else the `efg` tag, else the
///   muxed guess flagged unknown.
/// - `dash_manifest_url` (only when no inline manifest produced formats):
///   handed to `FormatExpander.expandFormats(..., 'mpd')`, which DRM-scans
///   the manifest and exposes it as one ffmpeg-read `mpd` format.
class FacebookFormatBuilder {
  final FormatExpander _expander;
  final RedditDashManifestParser _dashParser;

  FacebookFormatBuilder({required FormatExpander expander, RedditDashManifestParser? dashParser})
      : _expander = expander,
        _dashParser = dashParser ?? const RedditDashManifestParser();

  Future<FacebookFormats> build(FacebookVideoNode node, {Map<String, String>? requestHeaders}) async {
    final formats = <MediaFormat>[];
    var drmDetected = false;

    final hd = node.hdUrl;
    final sd = node.sdUrl;
    if (hd != null) formats.add(_progressive('progressive-hd', hd));
    if (sd != null && sd != hd) formats.add(_progressive('progressive-sd', sd));

    final dashFormats = <MediaFormat>[];
    final xml = node.dashXml;
    if (xml != null) {
      if (DrmPlaylistScanner.isMpdDrmProtected(xml)) {
        drmDetected = true;
      } else {
        dashFormats.addAll(dashRepresentations(xml));
      }
    }
    final dashUrl = node.dashUrl;
    if (dashFormats.isEmpty && dashUrl != null) {
      final expanded = await _expander.expandFormats(dashUrl, 'mpd', extraHeaders: requestHeaders);
      drmDetected = drmDetected || expanded.drmDetected;
      dashFormats.addAll(expanded.formats);
    }

    formats.addAll(dashFormats);
    return FacebookFormats(formats: _dedupe(formats), drmDetected: drmDetected);
  }

  /// Inline MPD -> one format per representation with an absolute `https`
  /// `BaseURL`. Empty when the manifest has none this reader understands.
  List<MediaFormat> dashRepresentations(String xml) {
    final List<MediaFormat> parsed;
    try {
      parsed = _dashParser.parse(xml, baseUrl: '');
    } on MediaExtractionException {
      return const [];
    }
    final result = <MediaFormat>[];
    for (final format in parsed) {
      final url = FacebookVideoJsonParser.httpsUrl(FacebookVideoJsonParser.unescapeHtml(format.url));
      if (url == null) continue;
      final known = format.hasVideo || format.hasAudio;
      final efg = known ? null : FacebookEfgDecoder.capabilitiesFromUrl(url);
      final hasVideo = known ? format.hasVideo : (efg?.hasVideo ?? true);
      final hasAudio = known ? format.hasAudio : (efg?.hasAudio ?? true);
      result.add(MediaFormat(
        id: 'dash-${format.id}',
        url: url,
        container: format.container,
        videoCodec: format.videoCodec,
        audioCodec: format.audioCodec,
        width: hasVideo ? format.width : null,
        height: hasVideo ? format.height : null,
        bitrate: format.bitrate,
        hasVideo: hasVideo,
        hasAudio: hasAudio,
        capabilitiesUnknown: !known && efg == null,
      ));
    }
    return result;
  }

  static MediaFormat _progressive(String id, String url) => MediaFormat(
        id: id,
        url: url,
        container: 'mp4',
        hasVideo: true,
        hasAudio: true,
        capabilitiesUnknown: true,
      );

  static List<MediaFormat> _dedupe(List<MediaFormat> formats) {
    final seen = <String>{};
    return [
      for (final format in formats)
        if (seen.add(format.url)) format,
    ];
  }
}
