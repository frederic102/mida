import 'html_media_sniffer.dart';
import 'iframe_follower.dart';
import 'network_budget.dart';
import 'oembed_scanner.dart';

/// Result of a successful [EmbedMediaResolver.followEmbeds] pass: the
/// merged media found across every embed page that yielded any, plus the
/// embed URL to use as the `Referer` for subsequent format/playlist
/// requests.
class EmbedFollowResult {
  final HtmlSniffResult sniffed;
  final Uri embedUrl;

  const EmbedFollowResult({required this.sniffed, required this.embedUrl});
}

/// The generic extractor's "1.5" step, split out of `GenericExtractor` to
/// keep that file under the project's 400-line cap: follows up to
/// [IframeFollower.maxCandidates] `<iframe>`/`<embed>`/`og:video:url` embed
/// pages found in a page's HTML (one level deep only - an embed page is
/// never itself scanned for further iframes to follow), and, only if none
/// of those yield anything, falls back to oEmbed discovery.
///
/// Network-budget follow-up (security): every fetch this step makes - each
/// embed-candidate GET, the oEmbed JSON GET, and the GET for the iframe an
/// oEmbed response points at - draws from one shared [NetworkBudget], so a
/// page cannot turn this step into an unbounded number of outbound
/// requests. The actual fetch is injected via [fetchText] rather than
/// owned here, so this class stays free of `HostPolicy`/`HttpClient`
/// wiring - that stays in `GenericExtractor`, the single place SSRF/DNS
/// guarding is owned.
class EmbedMediaResolver {
  final Future<String> Function(Uri url, {Map<String, String>? extraHeaders}) fetchText;

  const EmbedMediaResolver({required this.fetchText});

  Future<EmbedFollowResult?> followEmbeds(Uri pageUrl, String pageHtml) async {
    final budget = NetworkBudget();
    final iframeCandidates = IframeFollower.findEmbedCandidates(pageHtml, pageUrl);

    final direct = await _tryEmbedCandidates(pageUrl, iframeCandidates, budget);
    if (direct != null) return direct;

    final oembedCandidate = await _resolveOembedIframe(pageUrl, pageHtml, budget);
    if (oembedCandidate == null) return null;
    return _tryEmbedCandidates(pageUrl, [oembedCandidate], budget);
  }

  /// Fetches each of [candidates] with `Referer: <pageUrl>` (skipping any
  /// once [budget] is exhausted) and sniffs it independently. Candidates
  /// that fail to fetch, or sniff to nothing, are skipped rather than
  /// aborting the whole pass; every embed that does yield media is merged.
  Future<EmbedFollowResult?> _tryEmbedCandidates(Uri pageUrl, List<Uri> candidates, NetworkBudget budget) async {
    final mergedMedia = <SniffedMedia>[];
    final seenUrls = <String>{};
    String? title;
    String? thumbnailUrl;
    Uri? sourceEmbedUrl;
    var anyDrmDropped = false;

    for (final embedUrl in candidates) {
      if (!budget.tryConsume()) break;
      String embedHtml;
      try {
        embedHtml = await fetchText(embedUrl, extraHeaders: {'Referer': pageUrl.toString()});
      } catch (_) {
        continue;
      }

      final embedSniff = HtmlMediaSniffer.sniff(embedHtml, embedUrl);
      anyDrmDropped = anyDrmDropped || embedSniff.anyDrmCandidatesDropped;
      if (embedSniff.isEmpty) continue;

      // Headers are per-MediaInfo, not per-format (see MediaInfo doc), so
      // when multiple embeds contribute we can only carry one Referer:
      // the first embed that actually produced media wins.
      sourceEmbedUrl ??= embedUrl;
      title ??= embedSniff.title;
      thumbnailUrl ??= embedSniff.thumbnailUrl;
      for (final media in embedSniff.mediaUrls) {
        if (seenUrls.add(media.url)) mergedMedia.add(media);
      }
    }

    if (mergedMedia.isEmpty || sourceEmbedUrl == null) {
      // Still surface "found DRM only" even when nothing else contributed,
      // so `GenericExtractor.extract` can prefer DRM_PROTECTED over
      // NO_MEDIA_FOUND.
      if (anyDrmDropped) {
        return EmbedFollowResult(
          sniffed: const HtmlSniffResult(anyDrmCandidatesDropped: true),
          embedUrl: sourceEmbedUrl ?? pageUrl,
        );
      }
      return null;
    }
    return EmbedFollowResult(
      sniffed: HtmlSniffResult(
        mediaUrls: mergedMedia,
        title: title,
        thumbnailUrl: thumbnailUrl,
        anyDrmCandidatesDropped: anyDrmDropped,
      ),
      embedUrl: sourceEmbedUrl,
    );
  }

  /// oEmbed fallback: if [pageHtml] advertises an oEmbed discovery link
  /// (`<link type="application/json+oembed" href="...">`), fetches that
  /// JSON (consuming one unit of [budget]) and pulls the iframe `src` out
  /// of its `html` field, so [followEmbeds] can fetch and sniff it exactly
  /// like any other discovered embed candidate: same guard (via
  /// [fetchText]), same `Referer`, same one-level-deep limit, same shared
  /// budget. Returns null on any failure (no link, no budget left, fetch
  /// error, malformed JSON, no iframe in `html`) - this is a bonus
  /// discovery path, never fatal to the rest of extraction.
  Future<Uri?> _resolveOembedIframe(Uri pageUrl, String pageHtml, NetworkBudget budget) async {
    final oembedUrl = OembedScanner.findOembedUrl(pageHtml, pageUrl);
    if (oembedUrl == null) return null;
    if (!budget.tryConsume()) return null;
    String body;
    try {
      body = await fetchText(oembedUrl);
    } catch (_) {
      return null;
    }
    return OembedScanner.findIframeSrcInOembedJson(body, oembedUrl);
  }
}
