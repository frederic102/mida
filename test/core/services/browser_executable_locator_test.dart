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
}
