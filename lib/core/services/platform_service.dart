import 'dart:io';

/// Pure Dart (no `package:flutter`), so the agent CLI can import it. The app
/// ships for desktop only, so the old `kIsWeb` guards were dead branches;
/// `dart:io` itself is not available on web, which makes a web build of this
/// file impossible anyway.
class PlatformService {
  static bool get isDesktop {
    return Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  }

  static bool get isMobile {
    return Platform.isAndroid || Platform.isIOS;
  }

  static bool get isWindows {
    return Platform.isWindows;
  }

  static bool get isMacOS {
    return Platform.isMacOS;
  }

  static bool get isAndroid {
    return Platform.isAndroid;
  }

  static String get platformName {
    if (Platform.isWindows) return 'Windows';
    if (Platform.isMacOS) return 'macOS';
    if (Platform.isLinux) return 'Linux';
    if (Platform.isAndroid) return 'Android';
    if (Platform.isIOS) return 'iOS';
    return 'Unknown';
  }
}
