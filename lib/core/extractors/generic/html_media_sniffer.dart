import 'dart:convert';

import 'inline_json_scanner.dart';
import 'media_url_probe.dart';
import 'meta_tag_scanner.dart';
import 'sniffed_media.dart';

export 'sniffed_media.dart';

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

  /// `data-video-src`/`data-src`/`data-mp4`/`data-hls`: lazy-load
  /// attributes some sites put the real media URL in instead of `src`
  /// (the browser's own JS swaps it in on play/scroll). `data-src` in
  /// particular is also extremely common on plain `<img data-src="...">`
  /// lazy-loaded thumbnails; that is not a false-positive risk here
  /// because every match still has to pass the same extension-allowlist
  /// gate as everything else (`_classify` -> [MediaUrlProbe.containerFromExtension]),
  /// so a `.jpg`/`.png` value is dropped just like it would be from any
  /// other source. `data-setup` (Video.js JSON) is deliberately not
  /// matched here: it is JSON, not a bare URL, and is handled by
  /// [InlineJsonScanner] instead.
  static final RegExp _dataAttrSrcPattern = RegExp(
    '\\bdata-(?:video-src|src|mp4|hls)\\s*=\\s*(?:"([^"]+)"|' r"'([^']+)')",
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

  /// Hard cap on distinct candidate URLs a single sniff pass will collect
  /// (resource-exhaustion guard): bounds the number of downstream
  /// format-expansion/reachability-probe calls one page can trigger,
  /// regardless of how many matches its raw text/JSON actually contains.
  static const int _maxCandidates = 200;

  static HtmlSniffResult sniff(String html, Uri baseUrl) {
    // Keyed (not a plain List) so a URL seen again from a later source can
    // be looked up and upgraded in place rather than appended as a
    // duplicate. A plain Dart `Map` preserves insertion order, which is
    // what keeps discovery order stable for `orderFormats` downstream.
    final candidatesByUrl = <String, SniffedMedia>{};

    // [width]/[height]/[bitrate] are only ever supplied by an
    // inline-JSON-derived candidate. A URL already seen from an earlier,
    // metadata-less source (e.g. a plain <video src>) is not replaced -
    // its url/container stay put - but is *upgraded in place* to fill in
    // whichever of these three fields it was still missing, since the two
    // sources agreeing on the same URL is exactly the case that lets a
    // JSON blob's resolution data attach to a format the page also
    // exposes plainly (this is the mechanism that turns previously-empty
    // `heights=[]` results into real values; see the extractor test's
    // guard-can-fail case for what regresses without it). `contextBacked`
    // only ever goes false -> true on an upgrade, never true -> false: once
    // any source vouches for a URL, a later metadata-less mention of the
    // same URL must not un-vouch for it.
    void addCandidate(String? rawUrl, {int? width, int? height, int? bitrate, bool contextBacked = false}) {
      if (rawUrl == null || rawUrl.isEmpty) return;
      final classified = _classify(rawUrl, baseUrl);
      if (classified == null) return;
      final existing = candidatesByUrl[classified.url];
      if (existing != null) {
        candidatesByUrl[classified.url] = SniffedMedia(
          url: existing.url,
          container: existing.container,
          width: existing.width ?? width,
          height: existing.height ?? height,
          bitrate: existing.bitrate ?? bitrate,
          contextBacked: existing.contextBacked || contextBacked,
        );
        return;
      }
      if (candidatesByUrl.length >= _maxCandidates) return;
      candidatesByUrl[classified.url] = SniffedMedia(
        url: classified.url,
        container: classified.container,
        width: width,
        height: height,
        bitrate: bitrate,
        contextBacked: contextBacked,
      );
    }

    // Explicit player elements/attributes: a `<video>`/`<source>` tag or a
    // `data-video-src`/`data-hls`/`data-mp4` attribute is itself the
    // strongest possible signal that this URL is a real playable file, not
    // an incidental mention - context-backed unconditionally.
    for (final match in _videoSrcPattern.allMatches(html)) {
      addCandidate(match.group(1) ?? match.group(2), contextBacked: true);
    }
    for (final match in _sourceSrcPattern.allMatches(html)) {
      addCandidate(match.group(1) ?? match.group(2), contextBacked: true);
    }
    for (final match in _dataAttrSrcPattern.allMatches(html)) {
      addCandidate(match.group(1) ?? match.group(2), contextBacked: true);
    }

    // og:video:width/height (and the Twitter Player Card equivalents) are a
    // second inline-metadata resolution source, alongside inline-JSON blobs:
    // sites that expose no __NEXT_DATA__/__INITIAL_STATE__ at all (a plain
    // server-rendered page) still often carry these two tags right next to
    // og:video/og:video:secure_url (a live fetch against streamable.com and
    // archive.org confirmed this - both previously came back `heights=[]`).
    // Read in a first pass so the value is already known by the time the
    // og:video candidate itself is added below, regardless of which order
    // the tags happen to appear on the page in.
    int? ogVideoWidth;
    int? ogVideoHeight;
    for (final entry in MetaTagScanner.scan(html)) {
      if (entry.key == 'og:video:width' || entry.key == 'twitter:player:width') {
        ogVideoWidth ??= int.tryParse(entry.value);
      } else if (entry.key == 'og:video:height' || entry.key == 'twitter:player:height') {
        ogVideoHeight ??= int.tryParse(entry.value);
      }
    }

    String? ogTitle;
    String? ogImage;
    for (final entry in MetaTagScanner.scan(html)) {
      // og:video/twitter:player:stream are the site's own declared player
      // metadata protocol - context-backed unconditionally, same as a
      // <video> tag.
      if (_ogVideoProperties.contains(entry.key)) {
        addCandidate(entry.value, width: ogVideoWidth, height: ogVideoHeight, contextBacked: true);
      } else if (entry.key == 'og:title') {
        ogTitle ??= entry.value;
      } else if (entry.key == 'og:image') {
        ogImage ??= entry.value;
      }
    }

    // JSON-LD explicitly typed `VideoObject.contentUrl` - structured data
    // the page asserts is a video, context-backed.
    for (final match in _jsonLdPattern.allMatches(html)) {
      _harvestJsonLd(match.group(1) ?? '', (url) => addCandidate(url, contextBacked: true));
    }

    // Inline-JSON blobs (__NEXT_DATA__, window.__INITIAL_STATE__/__NUXT__/
    // __APOLLO_STATE__, <script type="application/json">, Video.js
    // data-setup): far more reliable than the raw-text regex catch-all
    // below, and the only source that carries width/height/bitrate.
    // `contextBacked` here is whatever `JsonMediaWalker` itself judged (see
    // its own false-positive guard doc): a URL sitting next to player-shaped
    // metadata or inside a recognized player-config container is
    // context-backed, a bare URL-shaped JSON string with neither is not.
    for (final candidate in InlineJsonScanner.scanAll(html)) {
      addCandidate(
        candidate.url,
        width: candidate.width,
        height: candidate.height,
        bitrate: candidate.bitrate,
        contextBacked: candidate.contextBacked,
      );
    }

    // Raw-text catch-all: a bare URL-shaped string found anywhere in the
    // page/script text with no surrounding context at all - the exact
    // shape an ad creative, tracker beacon, or unrelated preview clip's URL
    // has too. Never context-backed; `GenericExtractor` must verify it via
    // a reachability probe before trusting it as a format (security
    // follow-up: this used to be trusted outright).
    final unescaped = _decodeEscapes(html);
    for (final match in _mediaUrlPattern.allMatches(unescaped)) {
      addCandidate(match.group(0));
    }

    final title = _decodeEntities(ogTitle) ?? _extractTitleTag(html) ?? _lastPathSegment(baseUrl);

    final clearCandidates = <SniffedMedia>[];
    var anyDroppedForDrm = false;
    for (final candidate in candidatesByUrl.values) {
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
