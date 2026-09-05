import 'media_url_probe.dart';

/// A media URL found while sniffing a page: already resolved to an
/// absolute URL and classified to a recognized container by file
/// extension (see [MediaUrlProbe.extensionContainers]). Anything that
/// does not end in a recognized extension (tracker pixels, ad-click
/// links, embed player pages, etc) never becomes a [SniffedMedia].
///
/// [width]/[height]/[bitrate] are only ever populated from a source that
/// actually carries that metadata alongside the URL: an inline-JSON
/// blob's source object (see `InlineJsonScanner`/`JsonMediaWalker`), or
/// the page's own `og:video:width`/`og:video:height` (or Twitter Player
/// Card `twitter:player:width`/`height`) meta tags attached to an
/// `og:video`-family candidate. A plain `<video src>` match with no such
/// sibling metadata leaves them null. When the same
/// URL is found by more than one source, whichever source found it first
/// wins the [url]/[container] and later sources may only fill in
/// still-null metadata fields (see `HtmlMediaSniffer.sniff`'s
/// `addCandidate`), never overwrite a value that is already set.
///
/// [contextBacked] is the false-positive guard (security follow-up): true
/// when this URL came from a source that is itself evidence of a real
/// player (a `<video>`/`<source>` tag, an `og:video`/`twitter:player:stream`
/// meta tag, a JSON-LD `VideoObject`, an explicit `data-video-src`/
/// `data-hls` attribute, or a `JsonMediaCandidate` the walker itself judged
/// context-backed). False for the one source with zero context at all: a
/// bare URL-shaped string found by scanning raw page/script text for
/// anything ending in a recognized extension - exactly the shape an ad
/// creative, tracker beacon, or unrelated preview clip's URL has too.
/// `GenericExtractor` must treat a non-context-backed candidate as
/// unproven until a cheap reachability probe confirms it, and must rank
/// context-backed candidates ahead of merely-probed ones.
class SniffedMedia {
  final String url;
  final String container;
  final int? width;
  final int? height;
  final int? bitrate;
  final bool contextBacked;

  const SniffedMedia({
    required this.url,
    required this.container,
    this.width,
    this.height,
    this.bitrate,
    this.contextBacked = false,
  });

  @override
  String toString() =>
      'SniffedMedia($container, $url, ${width}x$height, bitrate: $bitrate, contextBacked: $contextBacked)';
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
  /// `HtmlMediaSniffer._drmUrlMarkers`). Lets the caller distinguish "this
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
