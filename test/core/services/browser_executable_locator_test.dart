import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/services/browser_executable_locator.dart';

void main() {
  group('BrowserExecutableLocator.find with fixedCandidatePaths override', () {
    test('returns the first candidate that exists, and skips env var/PATH probe entirely', () async {
      final result = await BrowserExecutableLocator.find(
        fixedCandidatePaths: () => ['/nope/a', '/nope/b', '/yes/c'],
        exists: (path) async => path == '/yes/c',
        environment: {'MIDA_BROWSER_PATH': '/should-be-ignored'},
        probePath: () async => ['/should-also-be-ignored'],
      );

      expect(result.found, isTrue);
      expect(result.path, '/yes/c');
      expect(result.checkedPaths, ['/nope/a', '/nope/b', '/yes/c']);
    });

    test('returns not-found with every checked path listed when none exist', () async {
      final result = await BrowserExecutableLocator.find(
        fixedCandidatePaths: () => ['/nope/a', '/nope/b'],
        exists: (path) async => false,
      );

      expect(result.found, isFalse);
      expect(result.path, isNull);
      expect(result.checkedPaths, ['/nope/a', '/nope/b']);
    });
  });

  group('BrowserExecutableLocator.find production search order (env var, then fixed, then PATH probe)', () {
    test('MIDA_BROWSER_PATH wins when set and it exists', () async {
      final result = await BrowserExecutableLocator.find(
        environment: {'MIDA_BROWSER_PATH': r'C:\custom\my-browser.exe', 'ProgramFiles': r'C:\Program Files'},
        exists: (path) async => path == r'C:\custom\my-browser.exe',
        probePath: () async => [],
      );

      expect(result.found, isTrue);
      expect(result.path, r'C:\custom\my-browser.exe');
      expect(result.checkedPaths.first, r'C:\custom\my-browser.exe');
    });

    test('MIDA_BROWSER_PATH set but missing on disk falls through to fixed candidate paths', () async {
      final result = await BrowserExecutableLocator.find(
        environment: {
          'MIDA_BROWSER_PATH': r'C:\custom\stale-browser.exe',
          'ProgramFiles': r'C:\Program Files',
          'ProgramFiles(x86)': r'C:\Program Files (x86)',
        },
        exists: (path) async => path == r'C:\Program Files\Google\Chrome\Application\chrome.exe',
        probePath: () async => [],
      );

      expect(result.found, isTrue);
      expect(result.path, r'C:\Program Files\Google\Chrome\Application\chrome.exe');
      expect(result.checkedPaths, contains(r'C:\custom\stale-browser.exe'));
    });

    test('falls through to the PATH probe when no fixed candidate exists', () async {
      final result = await BrowserExecutableLocator.find(
        environment: {'ProgramFiles': r'C:\Program Files', 'ProgramFiles(x86)': r'C:\Program Files (x86)'},
        exists: (path) async => path == r'C:\on-path\brave.exe',
        probePath: () async => [r'C:\on-path\brave.exe'],
      );

      expect(result.found, isTrue);
      expect(result.path, r'C:\on-path\brave.exe');
    });

    test('reports not-found with a checked-paths list covering env var, fixed candidates, and PATH probe results',
        () async {
      final result = await BrowserExecutableLocator.find(
        environment: {
          'MIDA_BROWSER_PATH': r'C:\custom\gone.exe',
          'ProgramFiles': r'C:\Program Files',
          'ProgramFiles(x86)': r'C:\Program Files (x86)',
        },
        exists: (path) async => false,
        probePath: () async => [r'C:\on-path\also-gone.exe'],
      );

      expect(result.found, isFalse);
      expect(result.checkedPaths, contains(r'C:\custom\gone.exe'));
      expect(result.checkedPaths, contains(r'C:\on-path\also-gone.exe'));
      expect(result.checkedPaths.length, greaterThan(2)); // env var + fixed candidates + PATH probe result
    });
  });

  group('BrowserExecutableLocator.defaultFixedCandidatePaths', () {
    test('a Windows-shaped environment includes Edge, Chrome, Brave, and Vivaldi', () {
      final paths = BrowserExecutableLocator.defaultFixedCandidatePaths(
        environment: {
          'ProgramFiles': r'C:\Program Files',
          'ProgramFiles(x86)': r'C:\Program Files (x86)',
          'LOCALAPPDATA': r'C:\Users\test\AppData\Local',
        },
      );

      expect(paths.any((p) => p.toLowerCase().contains('msedge.exe')), isTrue);
      expect(paths.any((p) => p.toLowerCase().contains('chrome.exe')), isTrue);
      expect(paths.any((p) => p.toLowerCase().contains('brave.exe')), isTrue);
      expect(paths.any((p) => p.toLowerCase().contains('vivaldi.exe')), isTrue);
    });
  });

  group('BrowserExecutableLocator Chrome preference and chromeOnly', () {
    const env = {
      'ProgramFiles': r'C:\Program Files',
      'ProgramFiles(x86)': r'C:\Program Files (x86)',
      'LOCALAPPDATA': r'C:\Users\test\AppData\Local',
    };
    const chrome = r'C:\Program Files\Google\Chrome\Application\chrome.exe';
    const edge = r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe';

    test('Chrome wins over Edge when both exist', () async {
      final result = await BrowserExecutableLocator.find(
        environment: env,
        exists: (path) async => path == chrome || path == edge,
        probePath: () async => [],
      );
      expect(result.path, chrome);
    });

    test('Chrome is listed before Edge in the fixed candidates and the PATH probe', () {
      final paths = BrowserExecutableLocator.defaultFixedCandidatePaths(environment: env).map((p) => p.toLowerCase());
      final list = paths.toList();
      expect(list.indexWhere((p) => p.contains('chrome.exe')), lessThan(list.indexWhere((p) => p.contains('msedge.exe'))));
      expect(BrowserExecutableLocator.pathProbeNames, ['chrome', 'msedge', 'brave']);
    });

    test('without chromeOnly, Edge is the fallback when Chrome is missing', () async {
      final result = await BrowserExecutableLocator.find(
        environment: env,
        exists: (path) async => path == edge,
        probePath: () async => [],
      );
      expect(result.path, edge);
    });

    test('chromeOnly with only Edge installed finds nothing and never checks Edge', () async {
      final result = await BrowserExecutableLocator.find(
        chromeOnly: true,
        environment: env,
        exists: (path) async => path == edge,
        probePath: () async => [edge],
      );
      expect(result.path, isNull);
      expect(result.checkedPaths, isNotEmpty);
      expect(result.checkedPaths.where((p) => p.toLowerCase().contains('msedge')), isEmpty);
    });

    test('chromeOnly ignores MIDA_BROWSER_PATH pointing at msedge.exe', () async {
      final result = await BrowserExecutableLocator.find(
        chromeOnly: true,
        environment: {...env, 'MIDA_BROWSER_PATH': r'D:\tools\msedge.exe'},
        exists: (path) async => path == r'D:\tools\msedge.exe',
        probePath: () async => [],
      );
      expect(result.path, isNull);
      expect(result.checkedPaths, isNot(contains(r'D:\tools\msedge.exe')));
    });

    test('chromeOnly accepts MIDA_BROWSER_PATH pointing at chrome.exe', () async {
      const custom = r'D:\tools\chrome.exe';
      final result = await BrowserExecutableLocator.find(
        chromeOnly: true,
        environment: {...env, 'MIDA_BROWSER_PATH': custom},
        exists: (path) async => path == custom,
        probePath: () async => [],
      );
      expect(result.path, custom);
    });

    test('chromeOnly also filters an injected fixedCandidatePaths list', () async {
      final result = await BrowserExecutableLocator.find(
        chromeOnly: true,
        fixedCandidatePaths: () => [edge, chrome],
        exists: (path) async => true,
      );
      expect(result.path, chrome);
      expect(result.checkedPaths, [chrome]);
    });

    test('isChromePath matches the file name only', () {
      expect(BrowserExecutableLocator.isChromePath(chrome), isTrue);
      expect(BrowserExecutableLocator.isChromePath('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'), isTrue);
      expect(BrowserExecutableLocator.isChromePath(r'C:\chrome\msedge.exe'), isFalse);
      expect(BrowserExecutableLocator.isChromePath(r'C:\x\chromium.exe'), isFalse);
    });
  });
}
