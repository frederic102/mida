enum PlatformType {
  youtube,
  twitter,
  instagram,
  tiktok,
  unknown,
}

class UrlParser {
  static final _twitterStatusIdPattern = RegExp(r'^\d+$');

  /// Extracts the numeric status id from a `/<user>/status/<id>` or
  /// `/i/status/<id>` path on a recognized X/Twitter host (both shapes are
  /// the same three path segments: `<user-or-i>`, `status`, `<id>`).
  /// Promoted here from `TwitterExtractor` (Phase 2b, per the X lane
  /// report in `docs/plan-phase2b-wiring.md`) so every URL-shape rule for
  /// every platform lives in one file; `TwitterExtractor.canHandle`/
  /// `extract` call this instead of keeping their own copy.
  static String? extractTwitterStatusId(Uri url) {
    if (detectPlatform(url.toString()) != PlatformType.twitter) return null;
    final segments = url.pathSegments;
    if (segments.length < 3) return null;
    if (segments[1] != 'status') return null;
    final id = segments[2];
    return _twitterStatusIdPattern.hasMatch(id) ? id : null;
  }

  /// True when [host] is exactly [domain] or a subdomain of it
  /// (`m.youtube.com` matches `youtube.com`). A plain substring check would
  /// also match `youtube.com.evil.example` or `evil-youtube.com`, so this
  /// is deliberately not `host.contains(domain)`.
  static bool _hostMatches(String host, String domain) {
    return host == domain || host.endsWith('.$domain');
  }

  static PlatformType detectPlatform(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return PlatformType.unknown;

    final host = uri.host.toLowerCase();

    if (_hostMatches(host, 'youtube.com') || _hostMatches(host, 'youtu.be')) {
      return PlatformType.youtube;
    }
    if (_hostMatches(host, 'twitter.com') || _hostMatches(host, 'x.com')) {
      return PlatformType.twitter;
    }
    if (_hostMatches(host, 'instagram.com')) {
      return PlatformType.instagram;
    }
    if (_hostMatches(host, 'tiktok.com')) {
      return PlatformType.tiktok;
    }

    return PlatformType.unknown;
  }

  static String? extractYouTubeVideoId(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    final host = uri.host.toLowerCase();

    // youtu.be/VIDEO_ID
    if (_hostMatches(host, 'youtu.be')) {
      return uri.pathSegments.isNotEmpty ? uri.pathSegments.first : null;
    }

    if (_hostMatches(host, 'youtube.com')) {
      // youtube.com/shorts/VIDEO_ID
      if (uri.pathSegments.length >= 2 && uri.pathSegments.first == 'shorts') {
        return uri.pathSegments[1];
      }
      // youtube.com/watch?v=VIDEO_ID
      return uri.queryParameters['v'];
    }

    return null;
  }

  static String getPlatformName(PlatformType platform) {
    switch (platform) {
      case PlatformType.youtube:
        return 'YouTube';
      case PlatformType.twitter:
        return 'Twitter/X';
      case PlatformType.instagram:
        return 'Instagram';
      case PlatformType.tiktok:
        return 'TikTok';
      case PlatformType.unknown:
        return 'Unknown';
    }
  }

  static String getPlatformIcon(PlatformType platform) {
    switch (platform) {
      case PlatformType.youtube:
        return '🎬';
      case PlatformType.twitter:
        return '🐦';
      case PlatformType.instagram:
        return '📷';
      case PlatformType.tiktok:
        return '🎵';
      case PlatformType.unknown:
        return '❓';
    }
  }

  static bool isValidUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    return uri.hasScheme && (uri.scheme == 'http' || uri.scheme == 'https');
  }

  /// Strips the query string from a single URI before it goes into a log
  /// line or exception message. YouTube stream/caption URLs carry signed
  /// access tokens in their query string; the path alone is enough to
  /// identify what failed.
  ///
  /// `uri.replace(query: '')` is deliberately not used here: it sets an
  /// empty (non-null) query component, which still renders a trailing `?`
  /// in `toString()`. Rebuilding from the string is the simplest way to
  /// drop the `?` entirely.
  static Uri stripQuery(Uri uri) {
    final str = uri.toString();
    final queryStart = str.indexOf('?');
    if (queryStart == -1) return uri;
    return Uri.parse(str.substring(0, queryStart));
  }

  /// An http(s)/ws(s) URL inside free-form text: case-insensitive scheme,
  /// no word boundary required before it (`_https://`, `1https://`), and
  /// slashes written plainly (`://`), backslash-escaped once or more
  /// (`:\/\/`, `:\\/\\/`), as `/` escapes, or percent-encoded
  /// (`%3A%2F%2F`). Group 1 is the scheme, group 2 everything after the
  /// slashes up to a delimiter.
  static final RegExp _urlInText = RegExp(
    r'''(https?|wss?)(?::(?:\\*/){2}|:(?:\\+u002f){2}|%3a%2f%2f)([^\s"'<>`]*)''',
    caseSensitive: false,
  );

  /// A protocol-relative URL (`//cdn.example/v.mp4?sig=...`) at the start of
  /// the text or after whitespace, a quote, `(`, `[`, `{`, `=` or `,`.
  /// Group 1 is that lead-in, 2 the host, 3 the rest. A `:` lead-in is never
  /// matched, so an already redacted `https://host/...` is left alone.
  static final RegExp _protocolRelativeUrl = RegExp(
    r'''(^|[\s"'(\[{=,])//(?:[^\s/@"'<>`]+@)?([a-z0-9-]+(?:\.[a-z0-9-]+)+)(?::\d+)?([/?#][^\s"'<>`]*)?''',
    caseSensitive: false,
  );

  /// Ends the authority (`userinfo@host:port`): a path, query, fragment,
  /// the backslash of an escaped slash, or their percent-encoded forms.
  static final RegExp _authorityEnd = RegExp(r'[/\\?#]|%2f|%3f|%23', caseSensitive: false);

  /// The last userinfo separator: `@` or `%40`.
  static final RegExp _userinfoEnd = RegExp(r'@|%40', caseSensitive: false);

  /// Punctuation that ends a sentence rather than the URL (`... /x: could
  /// not resolve`); kept outside the redacted URL.
  static final RegExp _trailingPunctuation = RegExp(r'''[.,;:!?)\]}'"]+$''');

  /// Redacts every URL in user-facing free-form text (an exception message,
  /// a log line) down to `scheme://host/...`: no userinfo, no port, no path,
  /// no query, no fragment (Phase 7 round 2, Bulwark B2 / Assay D2). Paths
  /// carry secrets too (Kaltura `/ks/<token>/`, CDN `exp=~hmac=` path
  /// signatures), so the host is the most this keeps. A bare `scheme://host`
  /// or `scheme://host/` keeps its shape. Text without a URL is unchanged.
  /// The name is kept from the query-only version so every caller gets the
  /// stronger behavior.
  static String redactUrlsInText(String text) {
    final schemed = text.replaceAllMapped(_urlInText, (match) {
      var rest = match.group(2)!;
      final trailing = _trailingPunctuation.firstMatch(rest)?.group(0) ?? '';
      rest = rest.substring(0, rest.length - trailing.length);
      final scheme = match.group(1)!.toLowerCase();
      final authorityEnd = rest.indexOf(_authorityEnd);
      var authority = authorityEnd == -1 ? rest : rest.substring(0, authorityEnd);
      final remainder = authorityEnd == -1 ? '' : rest.substring(authorityEnd);
      final userinfo = _userinfoEnd.allMatches(authority).lastOrNull;
      if (userinfo != null) authority = authority.substring(userinfo.end);
      authority = _hostOnly(authority);
      return '$scheme://$authority${_pathSuffix(remainder)}$trailing';
    });
    return schemed.replaceAllMapped(_protocolRelativeUrl, (match) {
      var rest = match.group(3) ?? '';
      final trailing = _trailingPunctuation.firstMatch(rest)?.group(0) ?? '';
      rest = rest.substring(0, rest.length - trailing.length);
      return '${match.group(1)}//${match.group(2)}${_pathSuffix(rest)}$trailing';
    });
  }

  /// `''` for no path, `/` for a bare root (plain or escaped), else `/...`.
  static String _pathSuffix(String remainder) {
    if (remainder.isEmpty) return '';
    final bareRoot = remainder == '/' || RegExp(r'^\\+/$').hasMatch(remainder) || remainder.toLowerCase() == '%2f';
    return bareRoot ? '/' : '/...';
  }

  /// Drops a `:port` (or `%3A` port) from [authority], keeping a bracketed
  /// IPv6 literal.
  static String _hostOnly(String authority) {
    if (authority.startsWith('[')) {
      final close = authority.indexOf(']');
      return close == -1 ? authority : authority.substring(0, close + 1);
    }
    final colon = authority.indexOf(RegExp(r':|%3a', caseSensitive: false));
    return colon == -1 ? authority : authority.substring(0, colon);
  }
}
