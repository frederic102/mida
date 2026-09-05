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

  /// Same idea as [stripQuery] but for free-form text (e.g. an already
  /// stringified exception) that may have a URL embedded in it.
  static String redactUrlsInText(String text) {
    return text.replaceAllMapped(
      RegExp(r'(https?://[^\s"]+?)\?[^\s"]*'),
      (match) => match.group(1)!,
    );
  }
}
