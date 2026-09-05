import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/browser_capture/browser_capture_extractor.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/services/browser_executable_locator.dart';
import 'package:mida/core/services/browser_profile.dart';

/// Live SCOPE 4 re-verification, per
/// `docs/plan-phase4-cookies-resilience.md`: does using the lead's own
/// browser login session (a staged **copy** of the real profile, per
/// SCOPE 1 - never a decrypted cookie value) change what Vimeo/Instagram
/// hand back, versus the logged-out baseline `test/live/browser_capture_
/// live_test.dart` already measures.
///
/// This is a **report**, not a hard pass/fail on the login-dependent
/// outcome: whether the lead happens to be signed in to Vimeo/Instagram in
/// their real browser right now is outside this test's control (and
/// outside this app's business - it never logs anyone in). What IS
/// hard-asserted: extraction runs to completion without leaking an
/// msedge/chrome process or a staged temp directory. Skips cleanly (not a
/// failure) when no browser, no known profile kind, or no real cookie
/// store is found.
///
/// Uses the lead's own account only, per the personal/company separation
/// rule - never a company account.
///
/// Run with:
/// `MIDA_LIVE=1 flutter test test/live/lead_login_session_live_test.dart`
void main() {
  final isLive = Platform.environment['MIDA_LIVE'] == '1';
  final skipReason = isLive ? false : 'set MIDA_LIVE=1 to run this against the real network, browser, and profile';

  test(
    'BrowserCaptureExtractor with the real login session: Vimeo + Instagram',
    () async {
      final lookup = await BrowserExecutableLocator.find();
      final executable = lookup.path;
      if (executable == null) {
        stdout.writeln('lead_login_session_live: skipping, no browser executable found '
            '(checked: ${lookup.checkedPaths.join(', ')})');
        return;
      }

      final kind = BrowserProfile.kindForExecutable(executable);
      if (kind == null) {
        stdout.writeln('lead_login_session_live: skipping, resolved browser has no known profile layout '
            '(not Edge/Chrome)');
        return;
      }

      // Pre-check only, so this test can skip cleanly instead of reporting
      // a false "not logged in": `BrowserCaptureExtractor` below stages
      // (and cleans up) its own copy internally regardless.
      final precheck = await BrowserProfile.stageCopy(kind);
      if (precheck == null) {
        stdout.writeln('lead_login_session_live: skipping, no real $kind profile with a cookie store found '
            '(browser never signed in to anything, or the profile is unreadable)');
        return;
      }
      await BrowserProfile.cleanup(precheck);

      final processesBefore = await _browserProcessCount();

      final vimeoOutcome = await _tryExtract(
        Uri.parse('https://vimeo.com/76979871'),
        check: (info) => info.formats.any((f) => f.container == 'm3u8' && !_looksDrm(f.url)),
        checkLabel: 'has_non_drm_hls',
      );
      stdout.writeln('lead_login_session_live: vimeo -> $vimeoOutcome');

      final instagramOutcome = await _tryExtract(
        Uri.parse('https://www.instagram.com/reel/Chunk8-jurw/'),
        check: (info) => info.formats.any((f) => f.hasAudio),
        checkLabel: 'has_audio_bearing_format',
      );
      stdout.writeln('lead_login_session_live: instagram -> $instagramOutcome');

      final processesAfter = await _browserProcessCount();
      expect(processesAfter, lessThanOrEqualTo(processesBefore),
          reason: 'no leaked msedge/chrome process after the run');

      final leakedTempDirs = Directory.systemTemp
          .listSync()
          .whereType<Directory>()
          .where((d) => d.path.contains('mida_profile_') || d.path.contains('mida_cdp_'))
          .toList();
      expect(leakedTempDirs, isEmpty, reason: 'no staged profile / CDP temp dir left behind: $leakedTempDirs');
    },
    skip: skipReason,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}

Future<String> _tryExtract(
  Uri url, {
  required bool Function(MediaInfo info) check,
  required String checkLabel,
}) async {
  final extractor = BrowserCaptureExtractor(useBrowserLoginSession: true);
  try {
    final info = await extractor.extract(url);
    return '${info.formats.length} formats, $checkLabel=${check(info)}';
  } on MediaExtractionException catch (e) {
    return 'extraction failed: ${e.status}${e.reason == null ? '' : ' (${e.reason})'}';
  } catch (e) {
    return 'extraction failed: $e';
  }
}

bool _looksDrm(String url) {
  final lower = url.toLowerCase();
  return lower.contains('/drm/') || lower.contains('cbcs') || lower.contains('cenc');
}

/// Best-effort count of running Edge/Chrome processes, used only as a
/// before/after leak check (not an exact accounting: the lead's own
/// browser windows, if any are already open, count on both sides equally).
Future<int> _browserProcessCount() async {
  try {
    if (Platform.isWindows) {
      final result = await Process.run('tasklist', const ['/FI', 'IMAGENAME eq msedge.exe']);
      final edge = (result.stdout as String? ?? '').toLowerCase().split('\n').where((l) => l.contains('msedge.exe')).length;
      final result2 = await Process.run('tasklist', const ['/FI', 'IMAGENAME eq chrome.exe']);
      final chrome =
          (result2.stdout as String? ?? '').toLowerCase().split('\n').where((l) => l.contains('chrome.exe')).length;
      return edge + chrome;
    }
    final result = await Process.run('ps', const ['-A', '-o', 'comm']);
    final lines = (result.stdout as String? ?? '').toLowerCase();
    return lines.split('\n').where((l) => l.contains('msedge') || l.contains('chrome')).length;
  } catch (_) {
    // Best-effort: if the process listing itself fails, report 0 on both
    // sides rather than failing this diagnostic count.
    return 0;
  }
}
