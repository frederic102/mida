import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/services/browser_profile.dart';

/// Hermetic: every case here builds a synthetic fake "User Data" tree
/// under a temp directory and points [BrowserProfile.stageCopy] at it via
/// `realUserDataDirOverride`. Nothing here reads or writes the developer
/// machine's real Edge/Chrome profile. Per
/// `docs/plan-phase4-cookies-resilience.md` SCOPE 1.
void main() {
  late Directory workDir;

  setUp(() {
    workDir = Directory.systemTemp.createTempSync('mida_bp_test_');
  });

  tearDown(() {
    if (workDir.existsSync()) workDir.deleteSync(recursive: true);
  });

  Directory buildFakeRealProfile({bool withCookies = true, bool withJournal = true}) {
    final realDir = Directory('${workDir.path}${Platform.pathSeparator}fake_user_data')..createSync();
    File('${realDir.path}${Platform.pathSeparator}Local State').writeAsStringSync('LOCAL_STATE_CONTENT');
    final defaultNetwork = Directory('${realDir.path}${Platform.pathSeparator}Default${Platform.pathSeparator}Network')
      ..createSync(recursive: true);
    if (withCookies) {
      File('${defaultNetwork.path}${Platform.pathSeparator}Cookies').writeAsStringSync('COOKIES_CONTENT');
    }
    if (withJournal) {
      File('${defaultNetwork.path}${Platform.pathSeparator}Cookies-journal').writeAsStringSync('JOURNAL_CONTENT');
    }
    // The one file this class must never copy: saved passwords/autofill.
    File('${realDir.path}${Platform.pathSeparator}Default${Platform.pathSeparator}Login Data')
        .writeAsStringSync('LOGIN_DATA_CONTENT_SHOULD_NEVER_BE_COPIED');
    // A second never-copy file, for good measure (history).
    File('${realDir.path}${Platform.pathSeparator}Default${Platform.pathSeparator}History')
        .writeAsStringSync('HISTORY_CONTENT_SHOULD_NEVER_BE_COPIED');
    return realDir;
  }

  group('BrowserProfile.kindForExecutable', () {
    test('recognizes msedge.exe as edge', () {
      expect(
        BrowserProfile.kindForExecutable(r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'),
        BrowserProfileKind.edge,
      );
    });

    test('recognizes chrome.exe as chrome', () {
      expect(
        BrowserProfile.kindForExecutable(r'C:\Program Files\Google\Chrome\Application\chrome.exe'),
        BrowserProfileKind.chrome,
      );
    });

    test('returns null for a browser this class does not know a profile layout for (brave)', () {
      expect(
        BrowserProfile.kindForExecutable(r'C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe'),
        isNull,
      );
    });
  });

  group('BrowserProfile.stageCopy', () {
    test('copies Local State and cookies (+ journal) but never Login Data or History', () async {
      final realDir = buildFakeRealProfile();

      final staged = await BrowserProfile.stageCopy(BrowserProfileKind.chrome, realUserDataDirOverride: realDir);
      addTearDown(() async {
        if (staged != null) await BrowserProfile.cleanup(staged);
      });

      expect(staged, isNotNull);
      final sep = Platform.pathSeparator;

      final stagedLocalState = File('${staged!.path}${sep}Local State');
      expect(stagedLocalState.existsSync(), isTrue);
      expect(stagedLocalState.readAsStringSync(), 'LOCAL_STATE_CONTENT');

      final stagedCookies = File('${staged.path}${sep}Default${sep}Network${sep}Cookies');
      expect(stagedCookies.existsSync(), isTrue);
      expect(stagedCookies.readAsStringSync(), 'COOKIES_CONTENT');

      final stagedJournal = File('${staged.path}${sep}Default${sep}Network${sep}Cookies-journal');
      expect(stagedJournal.existsSync(), isTrue);
      expect(stagedJournal.readAsStringSync(), 'JOURNAL_CONTENT');

      // The hard requirement: no copy of Login Data or History anywhere in
      // the staged tree, checked both by exact path and by content (in
      // case some future change nested it somewhere unexpected).
      expect(File('${staged.path}${sep}Default${sep}Login Data').existsSync(), isFalse);
      expect(File('${staged.path}${sep}Default${sep}History').existsSync(), isFalse);
      final everyStagedFileContent =
          staged.listSync(recursive: true).whereType<File>().map((f) => f.readAsStringSync()).join('\n');
      expect(everyStagedFileContent, isNot(contains('LOGIN_DATA_CONTENT_SHOULD_NEVER_BE_COPIED')));
      expect(everyStagedFileContent, isNot(contains('HISTORY_CONTENT_SHOULD_NEVER_BE_COPIED')));

      // Guard-can-fail evidence (see report): temporarily adding
      // `await File('${realDir.path}$sep Default$sep Login Data').copy(...)`
      // into `BrowserProfile.stageCopy` (mirroring the Cookies copy line)
      // and re-running this test turns the two `isFalse`/`isNot(contains)`
      // expectations above red, proving they exercise the real exclusion
      // rather than something that always passes.
    });

    test('cleanup deletes the staged tree', () async {
      final realDir = buildFakeRealProfile();
      final staged = await BrowserProfile.stageCopy(BrowserProfileKind.chrome, realUserDataDirOverride: realDir);
      expect(staged, isNotNull);
      expect(staged!.existsSync(), isTrue);

      await BrowserProfile.cleanup(staged);

      expect(staged.existsSync(), isFalse);
    });

    test('returns null when the real profile has no cookie store (nothing logged in)', () async {
      final realDir = buildFakeRealProfile(withCookies: false);

      final staged = await BrowserProfile.stageCopy(BrowserProfileKind.chrome, realUserDataDirOverride: realDir);

      expect(staged, isNull);
    });

    test('returns null when the real profile directory does not exist', () async {
      final missingDir = Directory('${workDir.path}${Platform.pathSeparator}does_not_exist');

      final staged = await BrowserProfile.stageCopy(BrowserProfileKind.edge, realUserDataDirOverride: missingDir);

      expect(staged, isNull);
    });

    test('a real profile with no Cookies-journal still stages (journal is optional)', () async {
      final realDir = buildFakeRealProfile(withJournal: false);

      final staged = await BrowserProfile.stageCopy(BrowserProfileKind.chrome, realUserDataDirOverride: realDir);
      addTearDown(() async {
        if (staged != null) await BrowserProfile.cleanup(staged);
      });

      expect(staged, isNotNull);
      final sep = Platform.pathSeparator;
      expect(File('${staged!.path}${sep}Default${sep}Network${sep}Cookies').existsSync(), isTrue);
      expect(File('${staged.path}${sep}Default${sep}Network${sep}Cookies-journal').existsSync(), isFalse);
    });
  });

  group('BrowserProfile.realUserDataDir', () {
    test('builds the expected Windows Edge/Chrome paths from LOCALAPPDATA', () {
      final env = {'LOCALAPPDATA': r'C:\Users\someone\AppData\Local'};

      final edgeDir = BrowserProfile.realUserDataDir(BrowserProfileKind.edge, environment: env);
      final chromeDir = BrowserProfile.realUserDataDir(BrowserProfileKind.chrome, environment: env);

      if (Platform.isWindows) {
        expect(edgeDir?.path, r'C:\Users\someone\AppData\Local\Microsoft\Edge\User Data');
        expect(chromeDir?.path, r'C:\Users\someone\AppData\Local\Google\Chrome\User Data');
      }
    }, skip: Platform.isWindows ? false : 'Windows-only path shape');

    test('returns null when LOCALAPPDATA is missing from the environment', () {
      final dir = BrowserProfile.realUserDataDir(BrowserProfileKind.edge, environment: const {});
      if (Platform.isWindows) expect(dir, isNull);
    }, skip: Platform.isWindows ? false : 'Windows-only path shape');
  });
}
