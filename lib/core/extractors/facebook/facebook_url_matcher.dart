/// What [FacebookUrlMatcher.match] recognized in a URL: the page to GET
/// and, when the URL itself names it, the numeric video id the page is
/// expected to describe.
class FacebookVideoRef {
  /// The page this extractor fetches. For a `facebook.com` URL this is the
  /// same path and query on `www.facebook.com` (an `m.`/`web.` host would
  /// only redirect there for a desktop User-Agent anyway); for `fb.watch`
  /// it is the short link itself, whose `Location` header leads to the
  /// real video page.
  final Uri fetchUrl;

  /// Numeric video id, or null for a short link (`/share/v/<slug>`,
  /// `fb.watch/<slug>`) whose id is only known after its redirect.
  final String? videoId;

  const FacebookVideoRef({required this.fetchUrl, this.videoId});
}

/// Pure, network-free URL recognition for [FacebookExtractor]. Supported
/// shapes (anything else is left to the generic and browser tiers):
///
/// - `facebook.com/<page>/videos/<id>` and
///   `facebook.com/<page>/videos/<slug>/<id>` (the corpus URL has the slug)
/// - `facebook.com/watch/?v=<id>` (also `/watch?v=<id>`)
/// - `facebook.com/reel/<id>`
/// - `facebook.com/share/v/<slug>` (short share link, redirects)
/// - `fb.watch/<slug>` (short link, redirects)
///
/// Hosts: `facebook.com`, `www.`, `m.`, `web.` and `fb.watch`/`www.fb.watch`
/// exactly; no other subdomain. `http` input is accepted but always fetched
/// as `https` ([FacebookVideoRef.fetchUrl] is never plain HTTP): a first
/// request in the clear would let anyone on the path substitute the page
/// before any redirect to HTTPS could happen.
class FacebookUrlMatcher {
  const FacebookUrlMatcher._();

  static const Set<String> _facebookHosts = {
    'facebook.com',
    'www.facebook.com',
    'm.facebook.com',
    'web.facebook.com',
  };
  static const Set<String> _shortLinkHosts = {'fb.watch', 'www.fb.watch'};
  static const String _canonicalHost = 'www.facebook.com';

  static final RegExp _pageVideoPath = RegExp(r'^/[^/]+/videos/(?:[^/]+/)?(\d+)/?$');
  static final RegExp _reelPath = RegExp(r'^/reel/(\d+)/?$');
  static final RegExp _watchPath = RegExp(r'^/watch/?$');
  static final RegExp _sharePath = RegExp(r'^/share/v/([0-9A-Za-z_-]+)/?$');
  static final RegExp _shortLinkPath = RegExp(r'^/([0-9A-Za-z_-]+)/?$');
  static final RegExp _numericId = RegExp(r'^\d+$');

  /// Null when [url] is not one of the shapes in the class doc.
  static FacebookVideoRef? match(Uri url) {
    final scheme = url.scheme.toLowerCase();
    if (scheme != 'https' && scheme != 'http') return null;
    final host = url.host.toLowerCase();

    if (_shortLinkHosts.contains(host)) {
      if (!_shortLinkPath.hasMatch(url.path)) return null;
      return FacebookVideoRef(fetchUrl: Uri(scheme: 'https', host: host, path: url.path));
    }
    if (!_facebookHosts.contains(host)) return null;

    final id = videoIdFromFacebookPath(url);
    if (id != null) {
      return FacebookVideoRef(fetchUrl: _canonical(url), videoId: id);
    }
    if (_sharePath.hasMatch(url.path)) {
      return FacebookVideoRef(fetchUrl: _canonical(url));
    }
    return null;
  }

  /// The numeric video id a `facebook.com` page path names directly
  /// (`/videos/`, `/watch?v=`, `/reel/`), or null. Also used on the
  /// effective URL a short link redirected to.
  static String? videoIdFromFacebookPath(Uri url) {
    final pageMatch = _pageVideoPath.firstMatch(url.path);
    if (pageMatch != null) return pageMatch.group(1);
    final reelMatch = _reelPath.firstMatch(url.path);
    if (reelMatch != null) return reelMatch.group(1);
    if (_watchPath.hasMatch(url.path)) {
      final v = url.queryParameters['v'];
      if (v != null && _numericId.hasMatch(v)) return v;
    }
    return null;
  }

  /// True for `facebook.com` and any `*.facebook.com` host: where a short
  /// link is allowed to land.
  static bool isFacebookHost(String host) {
    final lower = host.toLowerCase();
    return lower == 'facebook.com' || lower.endsWith('.facebook.com');
  }

  /// True for every host a Facebook page fetch may visit, redirects
  /// included: `facebook.com`, `fb.com`, `fb.watch` and their subdomains.
  static bool isFetchableHost(String host) {
    final lower = host.toLowerCase();
    for (final domain in const ['facebook.com', 'fb.com', 'fb.watch']) {
      if (lower == domain || lower.endsWith('.$domain')) return true;
    }
    return false;
  }

  static Uri _canonical(Uri url) => Uri(
        scheme: 'https',
        host: _canonicalHost,
        path: url.path,
        query: url.hasQuery ? url.query : null,
      );
}
