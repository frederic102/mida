import 'meta_tag_scanner.dart';

/// Pure (no network) candidate-URL finder for the "follow embedded
/// players" step of `GenericExtractor` (per the live Vimeo measurement:
/// the outer page is a 155KB shell with an `<iframe src="https://player.
/// vimeo.com/video/...">`; the media is only found by fetching that
/// embed page separately).
///
/// Deliberately one level deep: this only extracts candidates from the
/// outer page. `GenericExtractor` must not call this again on an embed
/// page it already followed (that would let a chain of embeds recurse
/// unboundedly).
class IframeFollower {
  const IframeFollower._();

  /// Per-page cap so a pathological page (dozens of ad iframes) can't
  /// turn one `extract()` call into dozens of extra HTTP round-trips.
  static const int maxCandidates = 5;

  static final RegExp _iframeSrcPattern = RegExp(
    '<iframe\\b[^>]*\\bsrc\\s*=\\s*(?:"([^"]+)"|' r"'([^']+)')",
    caseSensitive: false,
  );

  static final RegExp _embedSrcPattern = RegExp(
    '<embed\\b[^>]*\\bsrc\\s*=\\s*(?:"([^"]+)"|' r"'([^']+)')",
    caseSensitive: false,
  );

  /// Finds up to [maxCandidates] absolute http(s) embed-page URLs
  /// referenced by `<iframe src>`, `<embed src>`, or an `og:video:url`
  /// meta tag in [html] (resolved against [pageUrl]). Skips anything that
  /// is not http(s) after resolution, and anything that resolves back to
  /// [pageUrl] itself (would otherwise "follow" the page into itself).
  /// Detection order: iframe, then embed, then og:video:url; duplicates
  /// across sources are collapsed to their first occurrence.
  static List<Uri> findEmbedCandidates(String html, Uri pageUrl) {
    final candidates = <Uri>[];
    final seen = <String>{};
    final pageUrlString = pageUrl.toString();

    void addRaw(String? rawUrl) {
      if (candidates.length >= maxCandidates) return;
      if (rawUrl == null || rawUrl.isEmpty) return;
      Uri resolved;
      try {
        resolved = pageUrl.resolve(rawUrl);
      } catch (_) {
        return;
      }
      if (resolved.scheme != 'http' && resolved.scheme != 'https') return;
      final resolvedString = resolved.toString();
      if (resolvedString == pageUrlString) return;
      if (!seen.add(resolvedString)) return;
      candidates.add(resolved);
    }

    for (final match in _iframeSrcPattern.allMatches(html)) {
      addRaw(match.group(1) ?? match.group(2));
    }
    for (final match in _embedSrcPattern.allMatches(html)) {
      addRaw(match.group(1) ?? match.group(2));
    }
    for (final entry in MetaTagScanner.scan(html)) {
      if (entry.key == 'og:video:url') addRaw(entry.value);
    }

    return candidates;
  }
}
