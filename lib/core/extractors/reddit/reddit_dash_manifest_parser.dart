import '../media_models.dart';

/// Pure text -> [MediaFormat] mapping for a `v.redd.it` DASH manifest
/// (`.../DASHPlaylist.mpd`, the URL Reddit's `dash_url` field points at).
/// Kept free of any I/O so it can be exercised entirely against
/// `test/fixtures/reddit_dash_playlist.mpd`.
///
/// Deliberately a small hand-rolled regex reader, not a general XML
/// parser (no `xml` package dependency, and `v.redd.it`'s manifest shape
/// has been a flat, non-nested `Period > AdaptationSet > Representation`
/// for years - one video `AdaptationSet` with several
/// height/bitrate `Representation`s, one audio `AdaptationSet` with
/// (usually) one `Representation`, no nested `SegmentTemplate`
/// indirection this reader would need to follow): each
/// `<Representation ...><BaseURL>NAME</BaseURL>...` is one downloadable
/// segment file relative to the manifest's own directory, which
/// `v.redd.it` always serves at `.../<post-id>/DASHPlaylist.mpd` -
/// [baseUrl] is expected to already be that directory (with a trailing
/// slash), computed by the caller from `dash_url`.
class RedditDashManifestParser {
  const RedditDashManifestParser();

  static final _adaptationSetPattern = RegExp(
    r'<AdaptationSet\b([^>]*)>(.*?)</AdaptationSet>',
    dotAll: true,
  );
  static final _representationPattern = RegExp(
    r'<Representation\b([^>]*?)(?:/>|>(.*?)</Representation>)',
    dotAll: true,
  );
  static final _baseUrlPattern = RegExp(r'<BaseURL>([^<]*)</BaseURL>');

  /// Throws [MediaExtractionException] (`UNSUPPORTED_MEDIA`) when no
  /// `<Representation>` with a `<BaseURL>` was found at all - a manifest
  /// this reader cannot make sense of (Reddit changed shape, or DRM
  /// wrapped `<ContentProtection>` with every representation encrypted
  /// and unusable without a license, checked separately by the caller
  /// before this parser is ever reached).
  List<MediaFormat> parse(String manifestXml, {required String baseUrl}) {
    final formats = <MediaFormat>[];

    for (final setMatch in _adaptationSetPattern.allMatches(manifestXml)) {
      final setAttrs = setMatch.group(1) ?? '';
      final setBody = setMatch.group(2) ?? '';
      final mimeType = _attr(setAttrs, 'mimeType') ?? '';
      final isAudio = mimeType.startsWith('audio/') || setAttrs.contains('contentType="audio"');
      final isVideo = mimeType.startsWith('video/') || setAttrs.contains('contentType="video"');

      for (final repMatch in _representationPattern.allMatches(setBody)) {
        final repAttrs = repMatch.group(1) ?? '';
        final repBody = repMatch.group(2) ?? '';
        final baseUrlMatch = _baseUrlPattern.firstMatch(repBody);
        final fileName = baseUrlMatch?.group(1);
        if (fileName == null || fileName.isEmpty) continue;

        final width = int.tryParse(_attr(repAttrs, 'width') ?? '');
        final height = int.tryParse(_attr(repAttrs, 'height') ?? '');
        final bandwidth = int.tryParse(_attr(repAttrs, 'bandwidth') ?? '') ?? 0;
        final codecs = _attr(repAttrs, 'codecs');
        final repMimeType = _attr(repAttrs, 'mimeType') ?? mimeType;
        final effectiveIsAudio = isAudio || repMimeType.startsWith('audio/');
        final effectiveIsVideo = isVideo || repMimeType.startsWith('video/');

        formats.add(MediaFormat(
          id: _attr(repAttrs, 'id') ?? fileName,
          url: '$baseUrl$fileName',
          container: 'mp4',
          videoCodec: effectiveIsVideo ? codecs : null,
          audioCodec: effectiveIsAudio ? codecs : null,
          width: effectiveIsVideo ? width : null,
          height: effectiveIsVideo ? height : null,
          bitrate: bandwidth,
          hasVideo: effectiveIsVideo,
          hasAudio: effectiveIsAudio,
        ));
      }
    }

    if (formats.isEmpty) {
      throw const MediaExtractionException(
        'UNSUPPORTED_MEDIA',
        'Reddit\'s DASH manifest for this video had no readable renditions.',
      );
    }
    return formats;
  }

  String? _attr(String attrsText, String name) {
    final match = RegExp('$name="([^"]*)"').firstMatch(attrsText);
    return match?.group(1);
  }
}
