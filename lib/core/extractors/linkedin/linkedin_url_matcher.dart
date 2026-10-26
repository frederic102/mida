/// What [LinkedInUrlMatcher.match] recognized in a URL.
class LinkedInPostRef {
  /// The page this extractor fetches: `https://www.linkedin.com<path>`
  /// (query and fragment dropped; they are tracking parameters).
  final Uri fetchUrl;

  /// The numeric post id the URL names (`activity-<id>` in a `/posts/` slug,
  /// or the id of the `urn:li:...` in a feed URL), or null for a `/posts/`
  /// slug that carries none. Used to pick the right video when a page holds
  /// more than one.
  final String? postId;

  const LinkedInPostRef({required this.fetchUrl, this.postId});
}

/// Pure, network-free URL recognition for `LinkedInExtractor`. Public post
/// shapes only (learning courses, profiles, company pages, `/pulse/` articles
/// are left to the generic tiers):
///
/// - `linkedin.com/posts/<slug>` (the slug ends `...-activity-<id>-<hash>`)
/// - `linkedin.com/feed/update/urn:li:(activity|ugcPost|share):<id>`
/// - `linkedin.com/embed/feed/update/urn:li:(activity|ugcPost|share):<id>`
///
/// Hosts: `linkedin.com`, `www.linkedin.com` and two-letter country
/// subdomains (`uk.linkedin.com`). Every pattern is anchored; the fetch URL
/// is rebuilt from the matched path on `www.linkedin.com`.
class LinkedInUrlMatcher {
  const LinkedInUrlMatcher._();

  static final RegExp _hostPattern = RegExp(r'^(?:www\.|[a-z]{2}\.)?linkedin\.com$');
  static final RegExp _postsPath = RegExp(r'^/posts/((?:[A-Za-z0-9_.\-]|%[0-9A-Fa-f]{2}){3,300})/?$');
  static final RegExp _slugId = RegExp(r'(?:activity|ugcPost|share)-(\d{15,25})(?:-|$)');
  static final RegExp _feedPath = RegExp(r'^(/(?:embed/)?feed/update/urn:li:(?:activity|ugcPost|share):(\d{15,25}))/?$');

  static bool isLinkedInHost(String host) => _hostPattern.hasMatch(host.toLowerCase());

  /// Null when [url] is not one of the shapes in the class doc.
  static LinkedInPostRef? match(Uri url) {
    final scheme = url.scheme.toLowerCase();
    if (scheme != 'https' && scheme != 'http') return null;
    if (!isLinkedInHost(url.host)) return null;

    final posts = _postsPath.firstMatch(url.path);
    if (posts != null) {
      final slug = posts.group(1)!;
      return LinkedInPostRef(
        fetchUrl: Uri.parse('https://www.linkedin.com/posts/$slug'),
        postId: _slugId.firstMatch(slug)?.group(1),
      );
    }
    final feed = _feedPath.firstMatch(url.path);
    if (feed != null) {
      return LinkedInPostRef(fetchUrl: Uri.https('www.linkedin.com', feed.group(1)!), postId: feed.group(2));
    }
    return null;
  }

  /// True when a redirect landed on LinkedIn's anonymous-visitor wall
  /// (`/authwall`) or its security checkpoint. Both are walls put in front of
  /// a logged-out client for a public post, not proof that the post needs
  /// an account.
  static bool isAuthwall(Uri url) {
    final path = url.path.toLowerCase();
    return path.startsWith('/authwall') || path.startsWith('/checkpoint');
  }

  /// True when a redirect landed on the explicit sign-in form.
  static bool isLoginPage(Uri url) {
    final path = url.path.toLowerCase();
    return path.startsWith('/login') || path.startsWith('/uas/login');
  }
}
