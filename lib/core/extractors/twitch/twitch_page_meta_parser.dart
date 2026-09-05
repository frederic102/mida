/// Pure HTML -> title/thumbnail/duration/author extraction from a Twitch
/// VOD watch page's server-rendered `<meta property="og:...">` tags.
///
/// Verified live 2026-09-05 (`docs/plan-phase5-coverage.md` Lane D):
/// Twitch's public GQL `video(id:...)` field returns `null` for anonymous
/// (unauthenticated, no-login) requests even for a real, publicly playable
/// VOD - only `videoPlaybackAccessToken` (handled by [TwitchGqlClient]) is
/// exposed anonymously. The watch page's Open Graph tags, meant for link
/// previews, are the one place that still carries title/thumbnail/duration
/// for an anonymous request, so this extractor fetches the page for
/// metadata purposes only (playback itself never touches this HTML).
class TwitchPageMetaParser {
  const TwitchPageMetaParser();

  static final _ogTagPattern = RegExp(
    r'<meta property="og:([a-z:]+)" content="([^"]*)"',
  );

  /// Twitch's `og:title` is `"<clip/stream title> - <channel> on Twitch"`;
  /// this captures the channel name from that suffix so the extractor does
  /// not need a second (GQL) request just for an author string.
  static final _titleAuthorSuffix = RegExp(r'^(.*) - (.+) on Twitch$');

  ({String? title, String? author, String? thumbnailUrl, Duration? duration}) parse(String html) {
    final tags = <String, String>{};
    for (final match in _ogTagPattern.allMatches(html)) {
      tags[match.group(1)!] = _unescapeHtml(match.group(2)!);
    }

    final rawTitle = tags['title'];
    final titleAuthorMatch = rawTitle != null ? _titleAuthorSuffix.firstMatch(rawTitle) : null;

    final durationSeconds = int.tryParse(tags['video:duration'] ?? '');

    return (
      title: titleAuthorMatch?.group(1) ?? rawTitle,
      author: titleAuthorMatch?.group(2),
      thumbnailUrl: tags['image'],
      duration: durationSeconds != null ? Duration(seconds: durationSeconds) : null,
    );
  }

  String _unescapeHtml(String value) => value
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>');
}
