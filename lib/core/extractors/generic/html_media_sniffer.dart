import 'dart:convert';

import 'media_url_probe.dart';
import 'meta_tag_scanner.dart';

/// A media URL found while sniffing a page: already resolved to an
/// absolute URL and classified to a recognized container by file
/// extension (see [MediaUrlProbe.extensionContainers]). Anything that
/// does not end in a recognized extension (tracker pixels, ad-click
/// links, embed player pages, etc) never becomes a [SniffedMedia].
class SniffedMedia {
  final String url;
  final String container;

  const SniffedMedia({required this.url, required this.container});

  @override
  String toString() => 'SniffedMedia($container, $url)';
}

/// Result of one sniff pass over a page's HTML.
///
/// Duration is intentionally not modeled here: none of the sources in
/// scope for step 1 of the plan (video/source tags, og/twitter meta,
/// JSON-LD `contentUrl`, inline-script URL scan) reliably carry a
/// duration, so callers always treat it as unknown for this path.
class HtmlSniffResult {
  final List<SniffedMedia> mediaUrls;
  final String? title;
  final String? thumbnailUrl;

  /// True when at least one candidate URL was found on this page but
  /// dropped because it signaled DRM (`/drm/`, `cbcs`, `cenc`, etc; see
  /// [HtmlMediaSniffer._drmUrlMarkers]). Lets the caller distinguish "this
  /// page genuinely has no video" from "this page's video is DRM'd", even
  /// when [mediaUrls] ends up empty for both.
  final bool anyDrmCandidatesDropped;

  const HtmlSniffResult({
    this.mediaUrls = const [],
    this.title,
    this.thumbnailUrl,
    this.anyDrmCandidatesDropped = false,
  });

  bool get isEmpty => mediaUrls.isEmpty;
}

/// Pure HTML sniffer (no network, no side effects): finds candidate media
/// URLs in [html] using the detection order from
/// `docs/plan-generic-extractor.md` ("탐지 순서" step 1). No HTML parsing
/// package is added for this (project convention: no new pub deps); tags
/// are found with small, order-independent attribute regexes instead of a
/// full DOM parse.
class HtmlMediaSniffer {
  const HtmlMediaSniffer._();

  static final RegExp _videoSrcPattern = RegExp(
    '<video\\b[^>]*\\bsrc\\s*=\\s*(?:"([^"]+)"|' r"'([^']+)')",
    caseSensitive: false,
  );

  static final RegExp _sourceSrcPattern = RegExp(
    '<source\\b[^>]*\\bsrc\\s*=\\s*(?:"([^"]+)"|' r"'([^']+)')",
    caseSensitive: false,
  );

  static final RegExp _jsonLdPattern = RegExp(
    '<script\\b[^>]*\\btype\\s*=\\s*(?:"application/ld\\+json"|' r"'application/ld\+json')" '[^>]*>(.*?)</script>',
    caseSensitive: false,
    dotAll: true,
  );

  /// Direct media URLs written into HTML/inline `<script>` text. Only
  /// recognized extensions are matched at all (this, not a denylist, is
  /// what keeps analytics/tracking URLs out; see the sniffer test's guard
  /// case for a fixture that proves it).
  static final RegExp _mediaUrlPattern = RegExp(
    r'''https?://[^\s"'<>\\]+\.(m3u8|mpd|mp4|webm)(\?[^\s"'<>\\]*)?''',
    caseSensitive: false,
  );

  static final RegExp _titleTagPattern = RegExp(r'<title[^>]*>(.*?)</title>', caseSensitive: false, dotAll: true);

  /// JSON string escapes that show up inside inline `<script>` blobs a
  /// page's own JS reads (e.g. Instagram's `video_versions`): `\uXXXX`
  /// (Instagram escapes the `&` between signed query params this way, not
  /// as `\/`), `\/`, `\"`, `\\`. A single-pass regex avoids re-processing
  /// characters a first escape produced, which sequential `replaceAll`
  /// calls could do by accident.
  static final RegExp _escapePattern = RegExp(r'\\u([0-9a-fA-F]{4})|\\/|\\"|\\\\');

  static const Set<String> _ogVideoProperties = {
    'og:video',
    'og:video:url',
    'og:video:secure_url',
    'twitter:player:stream',
  };

  /// Substrings that mark a media URL as DRM-wrapped (Vimeo's
  /// `/playlist/drm/cbcs,...` master is the case a live probe hit: ffmpeg
  /// cannot demux it, "Invalid data found when processing input"). Checked
  /// against the whole URL (path + query), case-insensitively.
  static const List<String> _drmUrlMarkers = [
    '/drm/',
    'cbcs',
    'cenc',
    'widevine',
    'playready',
    'fairplay',
    'license',
  ];

  static bool _looksLikeDrmUrl(String url) {
    final lower = url.toLowerCase();
    return _drmUrlMarkers.any(lower.contains);
  }

  static HtmlSniffResult sniff(String html, Uri baseUrl) {
    final seenUrls = <String>{};
    final rawCandidates = <SniffedMedia>[];

    void addCandidate(String? rawUrl) {
      if (rawUrl == null || rawUrl.isEmpty) return;
      final classified = _classify(rawUrl, baseUrl);
      if (classified == null) return;
      if (!seenUrls.add(classified.url)) return;
      rawCandidates.add(classified);
    }

    for (final match in _videoSrcPattern.allMatches(html)) {
      addCandidate(match.group(1) ?? match.group(2));
    }
    for (final match in _sourceSrcPattern.allMatches(html)) {
      addCandidate(match.group(1) ?? match.group(2));
    }

    String? ogTitle;
    String? ogImage;
    for (final entry in MetaTagScanner.scan(html)) {
      if (_ogVideoProperties.contains(entry.key)) {
        addCandidate(entry.value);
      } else if (entry.key == 'og:title') {
        ogTitle ??= entry.value;
      } else if (entry.key == 'og:image') {
        ogImage ??= entry.value;
      }
    }

    for (final match in _jsonLdPattern.allMatches(html)) {
      _harvestJsonLd(match.group(1) ?? '', addCandidate);
    }

    final unescaped = _decodeEscapes(html);
    for (final match in _mediaUrlPattern.allMatches(unescaped)) {
      addCandidate(match.group(0));
    }

    final title = _decodeEntities(ogTitle) ?? _extractTitleTag(html) ?? _lastPathSegment(baseUrl);

    final clearCandidates = <SniffedMedia>[];
    var anyDroppedForDrm = false;
    for (final candidate in rawCandidates) {
      if (_looksLikeDrmUrl(candidate.url)) {
        anyDroppedForDrm = true;
        continue;
      }
      clearCandidates.add(candidate);
    }

    return HtmlSniffResult(
      mediaUrls: clearCandidates,
      title: title,
      thumbnailUrl: ogImage,
      anyDrmCandidatesDropped: anyDroppedForDrm,
    );
  }

  static void _harvestJsonLd(String rawJson, void Function(String?) addCandidate) {
    dynamic decoded;
    try {
      decoded = jsonDecode(rawJson.trim());
    } catch (_) {
      return;
    }
    _walkJsonLd(decoded, addCandidate);
  }

  /// Walks JSON-LD looking for `VideoObject.contentUrl`, including nodes
  /// nested in a top-level array or under `@graph` (per the plan).
  /// `embedUrl` is deliberately ignored: it points at a player page, not a
  /// playable file.
  static void _walkJsonLd(dynamic node, void Function(String?) addCandidate) {
    if (node is List) {
      for (final item in node) {
        _walkJsonLd(item, addCandidate);
      }
      return;
    }
    if (node is! Map) return;

    final graph = node['@graph'];
    if (graph != null) _walkJsonLd(graph, addCandidate);

    final type = node['@type'];
    final isVideoObject = type == 'VideoObject' || (type is List && type.contains('VideoObject'));
    if (!isVideoObject) return;

    final contentUrl = node['contentUrl'];
    if (contentUrl is String) {
      addCandidate(contentUrl);
    } else if (contentUrl is List) {
      for (final entry in contentUrl) {
        if (entry is String) addCandidate(entry);
      }
    }
  }

  static SniffedMedia? _classify(String rawUrl, Uri baseUrl) {
    final decoded = _decodeEscapes(rawUrl);
    Uri resolved;
    try {
      resolved = baseUrl.resolve(decoded);
    } catch (_) {
      return null;
    }
    final container = MediaUrlProbe.containerFromExtension(resolved);
    if (container == null) return null;
    return SniffedMedia(url: resolved.toString(), container: container);
  }

  static String? _extractTitleTag(String html) {
    final match = _titleTagPattern.firstMatch(html);
    final raw = match?.group(1)?.trim();
    return (raw == null || raw.isEmpty) ? null : _decodeEntities(raw);
  }

  /// Decodes JSON-style backslash escapes (`\uXXXX`, `\/`, `\"`, `\\`)
  /// plus the HTML entity `&amp;`, in one pass over [text].
  ///
  /// Why this matters: the URL regex's char class excludes a literal
  /// backslash, so any un-decoded escape inside a candidate URL (most
  /// often Instagram's `\uXXXX` escape for `&` in its `video_versions`
  /// JSON) truncates the match right there, cutting off the rest of the
  /// signed query string. That corrupted, truncated URL still looks like
  /// a URL, so it still gets returned as a "format", but a Range GET
  /// against it 403s instead of 206ing (found via a live probe against a
  /// real Instagram reel, not a hypothetical).
  static String _decodeEscapes(String text) {
    final unescaped = text.replaceAllMapped(_escapePattern, (match) {
      final unicodeHex = match.group(1);
      if (unicodeHex != null) {
        return String.fromCharCode(int.parse(unicodeHex, radix: 16));
      }
      switch (match.group(0)) {
        case r'\/':
          return '/';
        case r'\"':
          return '"';
        case r'\\':
          return r'\';
      }
      return match.group(0)!;
    });
    return unescaped.replaceAll('&amp;', '&');
  }

  static String? _decodeEntities(String? text) {
    if (text == null) return null;
    return text
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>');
  }

  static String? _lastPathSegment(Uri url) {
    final segments = url.pathSegments.where((s) => s.isNotEmpty).toList();
    return segments.isEmpty ? null : segments.last;
  }
}
