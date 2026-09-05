import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/services/browser_launch_args.dart';

void main() {
  group('BrowserLaunchArgs.build', () {
    test('headed omits --headless=new and positions the window off-screen', () {
      final args = BrowserLaunchArgs.build(headed: true, profileDirPath: r'C:\tmp\p', port: 1234);

      expect(args, isNot(contains('--headless=new')));
      expect(args, contains('--window-position=-32000,-32000'));
    });

    test('headless includes --headless=new and never positions a window', () {
      final args = BrowserLaunchArgs.build(headed: false, profileDirPath: r'C:\tmp\p', port: 1234);

      expect(args, contains('--headless=new'));
      expect(args, isNot(contains('--window-position=-32000,-32000')));
    });

    test('neither mode ever passes --enable-automation', () {
      // Guard can fail: this is the flag that actually sets
      // navigator.webdriver on current Chromium (not the debugging port
      // itself) - if a future edit added it back for either mode, this
      // assertion is what would catch it.
      for (final headed in [true, false]) {
        final args = BrowserLaunchArgs.build(headed: headed, profileDirPath: r'C:\tmp\p', port: 1234);
        expect(args.any((a) => a.contains('enable-automation')), isFalse);
      }
    });

    test('both modes still pass the loopback-only debugging address and the given port', () {
      final args = BrowserLaunchArgs.build(headed: true, profileDirPath: r'C:\tmp\p', port: 9222);

      expect(args, contains('--remote-debugging-address=127.0.0.1'));
      expect(args, contains('--remote-debugging-port=9222'));
      expect(args, contains(r'--user-data-dir=C:\tmp\p'));
    });
  });
}
