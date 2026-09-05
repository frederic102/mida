import 'dart:convert';

import '../media_models.dart';

/// Pure parsing of the DOM `BrowserPageFetcher` dumps for an Instagram
/// post/reel URL (`docs/plan-phase2-extractors.md` Instagram section). No
/// network, no browser invocation, so it is fully exercised against
/// `test/fixtures/instagram_dom_excerpt.html`.
///
/// Implementation note (deviation from the plan's literal description): the
/// plan describes finding the post's media JSON ("the `xig_polaris_media`
/// blob") with a raw-text regex scan plus manual `\/`/`\uXXXX` unescaping.
/// A live capture against the reel this plan cites
/// (`https://www.instagram.com/reel/Chunk8-jurw/`) showed that data sits in
/// one well-formed `<script type="application/json" data-sjs>` tag whose
/// content is valid JSON end to end (the `\/` and `\uXXXX` sequences the
/// plan flags are legal JSON string escapes, not something layered on top).
/// `jsonDecode` handles those natively, so this parser decodes that script
/// tag directly and walks the resulting tree, rather than duplicating a
/// hand-rolled unescaper for characters the standard library already
/// decodes correctly. This also sidesteps a real ambiguity a raw-text scan
/// would hit: the same page embeds several *other* posts' JSON (Instagram's
/// "recommended" rail) that also contain their own `video_versions`/
/// `caption` keys, so a plain "first video_versions in the document" scan
/// picks up the wrong post; matching on `code` (the shortcode from the
/// post's own URL) is what disambiguates them.
class InstagramDomParser {
  const InstagramDomParser();

  static final RegExp _jsonScriptPattern = RegExp(
    r'<script\b[^>]*\btype="application/json"[^>]*>(.*?)</script>',
    dotAll: true,
  );

  static final RegExp _dashDurationPattern = RegExp(
    r'mediaPresentationDuration="PT(?:(\d+)H)?(?:(\d+)M)?([\d.]+)S"',
  );

  static final RegExp _adaptationSetPattern = RegExp(
    r'<AdaptationSet\b([^>]*)>(.*?)</AdaptationSet>',
    dotAll: true,
  );

  static final RegExp _representationPattern = RegExp(
    r'<Representation\b([^>]*)>(.*?)</Representation>',
    dotAll: true,
  );

  static final RegExp _baseUrlPattern = RegExp(r'<BaseURL>(.*?)</BaseURL>', dotAll: true);

  /// Throws [MediaExtractionException]: `PARSE_ERROR` when no embedded JSON
  /// script tag matches this post's shortcode at all (blocked page, login
  /// wall, layout change), `UNSUPPORTED_MEDIA` when the post is found but
  /// has no video anywhere in it (image-only post, or an image-only
  /// carousel; only the first video of a carousel is ever considered, per
  /// the plan's scope).
  MediaInfo parse(String html, {required Uri sourceUrl}) {
    final shortcode = _shortcodeFromUrl(sourceUrl);
    final media = _findMediaScript(html, shortcode);
    if (media == null) {
      throw const MediaExtractionException(
        'PARSE_ERROR',
        'Instagram returned a page MiDa could not read the video data from.',
      );
    }

    final formats = _extractFormats(media);
    if (formats.isEmpty) {
      throw const MediaExtractionException(
        'UNSUPPORTED_MEDIA',
        'This Instagram post has no video (image-only post or carousel), '
            'which MiDa does not support yet.',
      );
    }

    final caption = _asMap(media['caption'])?['text'] as String?;
    final owner = _asMap(media['user'])?['username'] as String?;
    final postId = shortcode ?? (media['pk'] as String?) ?? '';

    return MediaInfo(
      id: postId,
      title: buildSocialTitle(author: owner, caption: caption, postId: postId),
      author: owner,
      thumbnailUrl: _thumbnailOf(media),
      duration: _durationOf(media),
      formats: formats,
      sourceUrl: sourceUrl,
    );
  }

  /// Builds the display title: `@<author> - <first 60 chars of the
  /// caption, URLs and line breaks stripped>`, or `@<author> - <post id>`
  /// when nothing usable is left after that cleanup. A raw Instagram
  /// caption can run to 150+ chars of emoji-laden text and embedded links -
  /// unsuitable as a filename verbatim - so this is deliberately never
  /// "just use the caption". Shared verbatim (small enough that a
  /// cross-platform import would be more awkward than the duplication)
  /// with `TikTokPageParser.buildSocialTitle`.
  static String buildSocialTitle({
    required String? author,
    required String? caption,
    required String postId,
  }) {
    final authorPart = '@${(author != null && author.isNotEmpty) ? author : 'unknown'}';
    final cleaned = _cleanCaptionForTitle(caption);
    return '$authorPart - ${cleaned.isNotEmpty ? cleaned : postId}';
  }

  static String _cleanCaptionForTitle(String? caption) {
    if (caption == null) return '';
    final noUrls = caption.replaceAll(RegExp(r'https?://\S+'), '');
    final noLineBreaks = noUrls.replaceAll(RegExp(r'[\r\n]+'), ' ');
    final collapsed = noLineBreaks.replaceAll(RegExp(r'\s+'), ' ').trim();
    return _truncateSafely(collapsed, 60);
  }

  /// Truncates to [maxLen] UTF-16 code units without splitting a surrogate
  /// pair (astral-plane emoji are two code units; a naive `substring` can
  /// cut one in half and leave an unpaired surrogate in the result).
  static String _truncateSafely(String value, int maxLen) {
    if (value.length <= maxLen) return value;
    var end = maxLen;
    if (end > 0 && value.codeUnitAt(end - 1) >= 0xD800 && value.codeUnitAt(end - 1) <= 0xDBFF) {
      end -= 1;
    }
    return value.substring(0, end).trim();
  }

  /// Scans every `<script type="application/json">` tag in [html], decodes
  /// each independently (a decode failure just means "not this tag, keep
  /// looking") and returns the first JSON object whose `code` equals
  /// [shortcode] and which carries this post's own media fields directly
  /// (`video_versions`, `image_versions2` or `carousel_media`) rather than
  /// just linking to it.
  Map<String, dynamic>? _findMediaScript(String html, String? shortcode) {
    if (shortcode == null) return null;
    for (final match in _jsonScriptPattern.allMatches(html)) {
      dynamic decoded;
      try {
        decoded = jsonDecode(match.group(1)!);
      } catch (_) {
        continue;
      }
      final found = _findMediaNode(decoded, shortcode);
      if (found != null) return found;
    }
    return null;
  }

  Map<String, dynamic>? _findMediaNode(dynamic node, String shortcode) {
    if (node is Map) {
      // Instagram's page state nests the same `code` twice: an outer
      // wrapper that only links to the media, and (deeper, inside
      // `if_not_gated_logged_out`) the object that actually carries
      // `video_dash_manifest`/`video_versions`/`image_versions2`/
      // `carousel_media`. Requiring one of those four here is what makes
      // this pick the inner object instead of returning the wrapper (which
      // would look like "no media" and misreport a real video post as
      // UNSUPPORTED_MEDIA).
      if (node['code'] == shortcode &&
          (node.containsKey('video_dash_manifest') ||
              node.containsKey('video_versions') ||
              node.containsKey('image_versions2') ||
              node.containsKey('carousel_media'))) {
        return node.cast<String, dynamic>();
      }
      for (final value in node.values) {
        final found = _findMediaNode(value, shortcode);
        if (found != null) return found;
      }
      return null;
    }
    if (node is List) {
      for (final item in node) {
        final found = _findMediaNode(item, shortcode);
        if (found != null) return found;
      }
    }
    return null;
  }

  /// All playable renditions for the top-level post, falling back to the
  /// first carousel slide that has any (per the plan's "first video only"
  /// carousel scope).
  List<MediaFormat> _extractFormats(Map<String, dynamic> media) {
    final direct = _formatsForMediaItem(media);
    if (direct.isNotEmpty) return direct;

    final carousel = media['carousel_media'];
    if (carousel is List) {
      for (final item in carousel) {
        if (item is Map) {
          final itemFormats = _formatsForMediaItem(item.cast<String, dynamic>());
          if (itemFormats.isNotEmpty) return itemFormats;
        }
      }
    }
    return const [];
  }

  /// Every format one media item (the post itself, or one carousel slide)
  /// offers: the DASH manifest's Representations first (the actually
  /// adaptive, highest-quality source), then `video_versions` as extra
  /// video-only candidates.
  List<MediaFormat> _formatsForMediaItem(Map<String, dynamic> item) {
    final result = <MediaFormat>[];
    final manifest = item['video_dash_manifest'];
    if (manifest is String && manifest.isNotEmpty) {
      result.addAll(_parseDashManifest(manifest));
    }
    final versions = item['video_versions'];
    if (versions is List && versions.isNotEmpty) {
      result.addAll(_formatsFromVersions(versions));
    }
    return result;
  }

  /// Parses the inline MPD XML Instagram embeds as `video_dash_manifest`
  /// into one [MediaFormat] per `Representation`.
  ///
  /// Verified live against a real manifest (`test/fixtures/
  /// instagram_dom_excerpt.html`) and against a byte-level `ffprobe` of the
  /// downloaded rendition: despite the container mimeType always reading
  /// `video/mp4`, `Representation`s under an `AdaptationSet mimeType=
  /// "audio/mp4"` (DASH allows the mimeType on either element) are
  /// genuinely audio-only, and every video `Representation` genuinely has
  /// no audio track of its own - so this always splits strictly into
  /// video-only (`hasAudio: false`) or audio-only (`hasVideo: false`)
  /// formats, never a muxed guess.
  List<MediaFormat> _parseDashManifest(String manifest) {
    final result = <MediaFormat>[];
    var index = 0;
    for (final adaptationSetMatch in _adaptationSetPattern.allMatches(manifest)) {
      final setAttrs = adaptationSetMatch.group(1) ?? '';
      final setContent = adaptationSetMatch.group(2) ?? '';
      final setMimeType = _xmlAttr(setAttrs, 'mimeType');

      for (final repMatch in _representationPattern.allMatches(setContent)) {
        final repAttrs = repMatch.group(1) ?? '';
        final repContent = repMatch.group(2) ?? '';
        final baseUrlMatch = _baseUrlPattern.firstMatch(repContent);
        final url = baseUrlMatch == null ? null : _decodeXmlEntities(baseUrlMatch.group(1)!.trim());
        if (url == null || url.isEmpty) continue;

        final mimeType = _xmlAttr(repAttrs, 'mimeType') ?? setMimeType;
        final codecs = _xmlAttr(repAttrs, 'codecs');
        final bandwidth = _asInt(_xmlAttr(repAttrs, 'bandwidth')) ?? 0;
        final id = _xmlAttr(repAttrs, 'id') ?? 'dash-${index++}';

        if (mimeType == 'audio/mp4') {
          result.add(MediaFormat(
            id: id,
            url: url,
            container: 'mp4',
            audioCodec: codecs,
            bitrate: bandwidth,
            hasVideo: false,
            hasAudio: true,
          ));
        } else {
          result.add(MediaFormat(
            id: id,
            url: url,
            container: 'mp4',
            videoCodec: codecs,
            width: _asInt(_xmlAttr(repAttrs, 'width')),
            height: _asInt(_xmlAttr(repAttrs, 'height')),
            bitrate: bandwidth,
            hasVideo: true,
            hasAudio: false,
          ));
        }
      }
    }
    return result;
  }

  String? _xmlAttr(String attrs, String name) => RegExp('\\b$name="([^"]*)"').firstMatch(attrs)?.group(1);

  /// Decodes the XML entities the manifest string itself uses around `&`
  /// in signed query params (a second, XML-level escaping layer on top of
  /// - and untouched by - the JSON string decoding that already happened
  /// when this manifest string was read out of the surrounding JSON).
  String _decodeXmlEntities(String value) => value
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'");

  /// `video_versions` entries have historically been assumed muxed, but a
  /// live byte-level `ffprobe` of one (URL `efg` tag `dash_baseline_2_v1`)
  /// came back video-only h264 - the same as the DASH manifest's own
  /// Representations for the same post. Without a reliable per-entry way
  /// to prove one actually carries audio, these are always treated as
  /// additional video-only candidates, never assumed muxed.
  List<MediaFormat> _formatsFromVersions(List versions) {
    final result = <MediaFormat>[];
    for (final entry in versions) {
      if (entry is! Map) continue;
      final url = entry['url'] as String?;
      if (url == null || url.isEmpty) continue;
      result.add(MediaFormat(
        id: '${entry['type'] ?? result.length}',
        url: url,
        container: 'mp4',
        width: _asInt(entry['width']),
        height: _asInt(entry['height']),
        hasVideo: true,
        hasAudio: false,
      ));
    }
    return result;
  }

  /// Instagram's inline post JSON does not always carry a plain
  /// `video_duration` seconds field (the plan expected one, but the reel it
  /// verified against has none); when absent, this falls back to parsing
  /// the `mediaPresentationDuration` attribute out of the DASH manifest
  /// (`video_dash_manifest`), which is present instead.
  Duration? _durationOf(Map<String, dynamic> media) {
    final seconds = media['video_duration'];
    if (seconds is num) return Duration(milliseconds: (seconds * 1000).round());

    final manifest = media['video_dash_manifest'];
    if (manifest is String) {
      final match = _dashDurationPattern.firstMatch(manifest);
      if (match != null) {
        final hours = int.tryParse(match.group(1) ?? '0') ?? 0;
        final minutes = int.tryParse(match.group(2) ?? '0') ?? 0;
        final wholeAndFractionalSeconds = double.tryParse(match.group(3) ?? '0') ?? 0;
        return Duration(
          hours: hours,
          minutes: minutes,
          milliseconds: (wholeAndFractionalSeconds * 1000).round(),
        );
      }
    }
    return null;
  }

  String? _thumbnailOf(Map<String, dynamic> media) {
    final direct = _firstCandidateUrl(_asMap(media['image_versions2']));
    if (direct != null) return direct;

    final carousel = media['carousel_media'];
    if (carousel is List) {
      for (final item in carousel) {
        if (item is Map) {
          final url = _firstCandidateUrl(_asMap(item['image_versions2']));
          if (url != null) return url;
        }
      }
    }
    return null;
  }

  String? _firstCandidateUrl(Map<String, dynamic>? imageVersions2) {
    final candidates = imageVersions2?['candidates'];
    if (candidates is List && candidates.isNotEmpty && candidates.first is Map) {
      return (candidates.first as Map)['url'] as String?;
    }
    return null;
  }

  Map<String, dynamic>? _asMap(dynamic value) => value is Map ? value.cast<String, dynamic>() : null;

  int? _asInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  /// Instagram post/reel URLs are always `/<type>/<shortcode>/...` (`type`
  /// is `p`, `reel`, `reels` or `tv`; enforced by
  /// `InstagramExtractor.canHandle`), so the shortcode is always the second
  /// non-empty path segment.
  String? _shortcodeFromUrl(Uri url) {
    final segments = url.pathSegments.where((s) => s.isNotEmpty).toList();
    return segments.length >= 2 ? segments[1] : null;
  }
}
