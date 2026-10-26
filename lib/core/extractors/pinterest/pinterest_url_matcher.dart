/// What [PinterestUrlMatcher.match] recognized: a pin id the URL names, or
/// a `pin.it` short link that still has to be resolved to one.
class PinterestRef {
  /// Numeric pin id (anchored `\d{1,25}`), or null for a short link.
  final String? pinId;

  /// The `pin.it/<code>` link to resolve, or null when [pinId] is known.
  final Uri? shortLink;

  const PinterestRef.pin(this.pinId) : shortLink = null;
  const PinterestRef.short(this.shortLink) : pinId = null;
}

/// Pure, network-free URL recognition for `PinterestExtractor`:
///
/// - `pinterest.<tld>/pin/<id>/` on `pinterest.com`, `www.`/`<cc>.`
///   subdomains and Pinterest's explicit country domains (`pinterest.fr`,
///   `pinterest.co.uk`, `pinterest.com.au`, ... see [_countryDomains])
/// - `pin.it/<code>` (resolved through its `Location` header, which may only
///   lead to a Pinterest pin URL)
///
/// Every id is validated by an anchored regex before any URL is built from
/// it, so nothing but digits or `[0-9A-Za-z]` ever reaches a request.
class PinterestUrlMatcher {
  const PinterestUrlMatcher._();

  /// Pinterest-owned country domains (besides `pinterest.com`); an explicit
  /// list, so a look-alike on some other two-letter TLD is not trusted.
  static const List<String> _countryDomains = [
    'co.uk', 'ca', 'de', 'fr', 'es', 'it', 'jp', 'kr', 'com.au', 'com.mx', 'pt', 'ch', 'at', 'nz', 'ie', 'se',
    'dk', 'ph', 'cl', 'co.kr', 'ru', 'in',
  ];

  /// `pinterest.com` with `www.` or a two-letter country subdomain
  /// (`uk.pinterest.com`), or a [_countryDomains] domain with optional `www.`.
  static final RegExp _hostPattern = RegExp(
    r'^(?:(?:www\.|[a-z]{2}\.)?pinterest\.com|(?:www\.)?pinterest\.(?:' +
        _countryDomains.map(RegExp.escape).join('|') +
        r'))$',
  );

  /// The host the `pin.it` redirector sends visitors through.
  static const String redirectorHost = 'api.pinterest.com';

  static final RegExp _pinPath = RegExp(r'^/pin/(\d{1,25})/?$');

  /// Where a short link may land: also tolerates the `/sent/` suffix the
  /// share redirect appends.
  static final RegExp _landingPath = RegExp(r'^/pin/(\d{1,25})(?:/sent)?/?$');
  static final RegExp _shortPath = RegExp(r'^/([0-9A-Za-z]{3,32})/?$');

  static const Set<String> _shortHosts = {'pin.it', 'www.pin.it'};

  static bool isPinterestHost(String host) => _hostPattern.hasMatch(host.toLowerCase());

  /// [isPinterestHost] plus the `pin.it` redirector host: where a short-link
  /// chain or the API call may be sent, never a place a user-facing pin URL
  /// is accepted.
  static bool isPinterestOwnedHost(String host) => isPinterestHost(host) || host.toLowerCase() == redirectorHost;

  /// Null when [url] is not one of the shapes in the class doc.
  static PinterestRef? match(Uri url) {
    final scheme = url.scheme.toLowerCase();
    if (scheme != 'https' && scheme != 'http') return null;
    final host = url.host.toLowerCase();

    if (_shortHosts.contains(host)) {
      final code = _shortPath.firstMatch(url.path)?.group(1);
      if (code == null) return null;
      return PinterestRef.short(Uri.https('pin.it', '/$code'));
    }
    if (!isPinterestHost(host)) return null;
    final id = _pinPath.firstMatch(url.path)?.group(1);
    return id == null ? null : PinterestRef.pin(id);
  }

  /// The pin id of a URL a short link redirected to, or null when it is not
  /// a Pinterest pin URL (so the redirect is refused).
  static String? pinIdFromLanding(Uri url) {
    if (url.scheme.toLowerCase() != 'https' || !isPinterestHost(url.host)) return null;
    return _landingPath.firstMatch(url.path)?.group(1);
  }
}
