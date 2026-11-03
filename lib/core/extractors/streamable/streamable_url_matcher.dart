/// Pure, network-free URL recognition for the Streamable extractor.
///
/// - `streamable.com/<code>`
/// - `streamable.com/e/<code>` (the embed player)
/// - the same on `www.streamable.com`
///
/// A code is 3 to 10 ASCII letters or digits (most are 5 or 6 lowercase
/// characters; early ones such as `moo` are 3). A short list of site pages that look like codes (`/login`,
/// `/about`, ...) is excluded. The code is the only thing that ever reaches
/// the API URL, and only after this anchored check.
class StreamableUrlMatcher {
  const StreamableUrlMatcher._();

  static const Set<String> _hosts = {'streamable.com', 'www.streamable.com'};

  static final RegExp _plainPath = RegExp(r'^/([A-Za-z0-9]{3,10})/?$');
  static final RegExp _embedPath = RegExp(r'^/e/([A-Za-z0-9]{3,10})/?$');

  static const Set<String> _siteRoutes = {
    'login', 'signup', 'about', 'terms', 'privacy', 'copyright', 'contact', 'upgrade', 'settings', 'videos',
    'help', 'blog', 'account', 'library', 'search', 'explore', 'trending', 'embed', 'report', 'dmca', 'pricing',
    'logout', 'jobs', 'press', 'api', 'apps', 'tools', 'faq',
  };

  /// The video code, or null when [url] is not a Streamable video URL.
  static String? match(Uri url) {
    final scheme = url.scheme.toLowerCase();
    if (scheme != 'https' && scheme != 'http') return null;
    if (!_hosts.contains(url.host.toLowerCase())) return null;
    final embed = _embedPath.firstMatch(url.path)?.group(1);
    if (embed != null) return embed;
    final code = _plainPath.firstMatch(url.path)?.group(1);
    // Site pages such as /login only collide with codes at the top level.
    if (code == null || _siteRoutes.contains(code.toLowerCase())) return null;
    return code;
  }
}
