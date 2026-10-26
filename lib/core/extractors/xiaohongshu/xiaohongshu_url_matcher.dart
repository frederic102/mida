/// What [XiaohongshuUrlMatcher] recognized: a note id (24 hex digits), or a
/// `xhslink.com` short link that still has to be resolved to one.
class XiaohongshuRef {
  final String? noteId;

  /// The note page to fetch (with the share link's own `xsec_token` and
  /// `xsec_source` when the URL carried them), or null for a short link.
  final Uri? fetchUrl;

  /// The `xhslink.com/...` link to resolve, or null when [noteId] is known.
  final Uri? shortLink;

  const XiaohongshuRef.note(this.noteId, this.fetchUrl) : shortLink = null;
  const XiaohongshuRef.short(this.shortLink)
      : noteId = null,
        fetchUrl = null;
}

/// Pure, network-free URL recognition for `XiaohongshuExtractor` (Xiaohongshu
/// / RedNote notes):
///
/// - `xiaohongshu.com/explore/<id>`
/// - `xiaohongshu.com/discovery/item/<id>`
/// - `xhslink.com/<code>` and `xhslink.com/<letter>/<code>` (short links,
///   resolved through their `Location` header)
///
/// A note id is exactly 24 lowercase hex digits (anchored). The only query
/// parameters carried into the fetch URL are `xsec_token` and `xsec_source`,
/// the access token the share link itself contains (the site's page
/// requires it for logged-out visitors), each checked against a strict
/// character set. Nothing is synthesized.
class XiaohongshuUrlMatcher {
  const XiaohongshuUrlMatcher._();

  static const Set<String> _siteHosts = {'xiaohongshu.com', 'www.xiaohongshu.com'};
  static const Set<String> _shortHosts = {'xhslink.com', 'www.xhslink.com'};

  static final RegExp _notePath = RegExp(r'^/(?:explore|discovery/item)/([0-9a-f]{24})/?$');
  static final RegExp _shortPath = RegExp(r'^/((?:[a-z]/)?[0-9A-Za-z]{4,32})/?$');
  static final RegExp _tokenPattern = RegExp(r'^[A-Za-z0-9_\-=+/.]{1,400}$');
  static final RegExp _sourcePattern = RegExp(r'^[a-z_]{1,40}$');

  static bool isSiteHost(String host) => _siteHosts.contains(host.toLowerCase());

  /// Null when [url] is not one of the shapes in the class doc.
  static XiaohongshuRef? match(Uri url) {
    final scheme = url.scheme.toLowerCase();
    if (scheme != 'https' && scheme != 'http') return null;
    final host = url.host.toLowerCase();

    if (_shortHosts.contains(host)) {
      final path = _shortPath.firstMatch(url.path)?.group(1);
      return path == null ? null : XiaohongshuRef.short(Uri.https('xhslink.com', '/$path'));
    }
    if (!_siteHosts.contains(host)) return null;
    return _noteRef(url);
  }

  /// The note a short link landed on, or null when [url] is not a note URL
  /// on a Xiaohongshu host over HTTPS (so the redirect is refused).
  static XiaohongshuRef? fromLanding(Uri url) {
    if (url.scheme.toLowerCase() != 'https' || !isSiteHost(url.host)) return null;
    return _noteRef(url);
  }

  static XiaohongshuRef? _noteRef(Uri url) {
    final id = _notePath.firstMatch(url.path)?.group(1);
    if (id == null) return null;
    final query = <String, String>{};
    final params = _safeQuery(url);
    final token = params['xsec_token'];
    if (token != null && _tokenPattern.hasMatch(token)) {
      query['xsec_token'] = token;
      final source = params['xsec_source'];
      if (source != null && _sourcePattern.hasMatch(source)) query['xsec_source'] = source;
    }
    return XiaohongshuRef.note(id, Uri.https('www.xiaohongshu.com', '/explore/$id', query.isEmpty ? null : query));
  }

  /// The URL's query parameters, or none when the query cannot be decoded
  /// (`?xsec_token=%FF` makes `Uri.queryParameters` throw a
  /// `FormatException`). [match] runs from `canHandle`, which must never
  /// throw, so a bad query just means "no token".
  static Map<String, String> _safeQuery(Uri url) {
    try {
      return url.queryParameters;
    } on FormatException {
      return const {};
    } on ArgumentError {
      return const {};
    }
  }

  /// True when a redirect landed on the site's sign-in page.
  static bool isLoginPage(Uri url) {
    final path = url.path.toLowerCase();
    return path.startsWith('/login') || path.startsWith('/website-login');
  }

  /// True when a redirect landed on the site's not-found page.
  static bool isNotFoundPage(Uri url) => url.path.toLowerCase().startsWith('/404');
}
