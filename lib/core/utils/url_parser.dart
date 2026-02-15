enum PlatformType {
  youtube,
  twitter,
  instagram,
  tiktok,
  unknown,
}

class UrlParser {
  static PlatformType detectPlatform(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return PlatformType.unknown;

    final host = uri.host.toLowerCase();

    if (host.contains('youtube.com') || host.contains('youtu.be')) {
      return PlatformType.youtube;
    }
    if (host.contains('twitter.com') || host.contains('x.com')) {
      return PlatformType.twitter;
    }
    if (host.contains('instagram.com')) {
      return PlatformType.instagram;
    }
    if (host.contains('tiktok.com')) {
      return PlatformType.tiktok;
    }

    return PlatformType.unknown;
  }

  static String? extractYouTubeVideoId(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;

    // youtu.be/VIDEO_ID
    if (uri.host.contains('youtu.be')) {
      return uri.pathSegments.isNotEmpty ? uri.pathSegments.first : null;
    }

    // youtube.com/watch?v=VIDEO_ID
    if (uri.host.contains('youtube.com')) {
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
}
