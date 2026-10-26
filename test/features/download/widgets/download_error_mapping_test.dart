import 'package:flutter_test/flutter_test.dart';
import 'package:mida/features/download/widgets/download_error_mapping.dart';

/// Rate-limit text as DownloadService renders it: the extractor reason plus
/// the service's own "Use browser login session" suggestion.
const _rateLimitedWithLoginHint =
    'CHZZK is throttling this request. Wait a moment and try again. Check the URL and try again later. '
    'This can happen when a site is rate-limiting requests from this network. Try turning on '
    '"Use browser login session" in Settings so MiDa can reuse your signed-in browser session instead.';

void main() {
  group('classifyFailure', () {
    // Explicit status codes, in both shapes the app produces.
    final statusTable = <String, FailureKind>{
      'Could not fetch this video (status: LOGIN_REQUIRED). Check the URL and try again later.':
          FailureKind.loginRequired,
      'MediaExtractionException(DRM_PROTECTED)': FailureKind.drm,
      'MediaExtractionException(DRM)': FailureKind.drm,
      'Could not fetch this video (status: BROWSER_MISSING).': FailureKind.browserMissing,
      'Could not fetch this video (status: NETWORK).': FailureKind.network,
      'Could not fetch this video (status: RATE_LIMITED).': FailureKind.rateLimited,
      'Could not fetch this video (status: NO_MEDIA_FOUND).': FailureKind.noMediaFound,
      'MediaExtractionException(HEADLESS_BLOCKED: page looked empty)': FailureKind.headlessBlocked,
      'Could not fetch this video (status: UNSUPPORTED_URL).': FailureKind.unsupportedUrl,
    };
    statusTable.forEach((text, kind) {
      test('status code: $kind', () => expect(classifyFailure(text), kind));
    });

    // Real reason sentences the extractors throw (status code not shown).
    final reasonTable = <String, FailureKind>{
      'This Bilibili video requires logging in (or is age-restricted).': FailureKind.loginRequired,
      'This Vimeo video is private, unlisted, or password protected.': FailureKind.loginRequired,
      'This video is protected by DRM (Widevine, PlayReady, or FairPlay) and cannot be downloaded.':
          FailureKind.drm,
      'Browser network capture needs Microsoft Edge, Google Chrome, Brave, or Vivaldi installed. '
              r'Checked: C:\Program Files\x.exe.':
          FailureKind.browserMissing,
      'Bilibili returned HTTP 503 for this page.': FailureKind.network,
      'The download failed while fetching video or audio data: reset. Check your internet connection and try again.':
          FailureKind.network,
      _rateLimitedWithLoginHint: FailureKind.rateLimited,
      'No video found on this page. The site may load video only after sign-in or interaction.':
          FailureKind.noMediaFound,
      'The browser capture did not observe any media requests while loading this page. '
              'The page may require login, or the content may be private or removed.':
          FailureKind.noMediaFound,
      'Timed out looking for video on this page within the static-analysis time budget.':
          FailureKind.noMediaFound,
      'example.com did not serve its media to the headless browser: the page loaded but looks like a bot-check.':
          FailureKind.headlessBlocked,
      'Not a recognizable Instagram post URL: https://instagram.com/x': FailureKind.unsupportedUrl,
      'Converting or merging the downloaded file failed: exit 1 Make sure ffmpeg is installed correctly.':
          FailureKind.ffmpeg,
      'Something nobody planned for.': FailureKind.unknown,
    };
    reasonTable.forEach((text, kind) {
      test('reason text: $kind (${text.substring(0, 24)})', () => expect(classifyFailure(text), kind));
    });

    test('an explicit status code beats keywords in the same text', () {
      expect(classifyFailure('Please sign in. (status: NETWORK)'), FailureKind.network);
    });

    // Flip-proof: the rate-limit text also says "login" and "signed-in".
    // With the login rule moved ahead of the rate-limit rule the same text
    // classifies differently, so the table row above really depends on the
    // rule order and would fail if that order regressed.
    test('flip-proof: rule order decides rate-limit vs login for the same text', () {
      expect(classifyFailure(_rateLimitedWithLoginHint), FailureKind.rateLimited);
      final loginFirst = [
        ...defaultFailureRules.where((r) => r.kind == FailureKind.loginRequired),
        ...defaultFailureRules.where((r) => r.kind != FailureKind.loginRequired),
      ];
      expect(classifyFailure(_rateLimitedWithLoginHint, rules: loginFirst), FailureKind.loginRequired);
    });
  });

  group('describeFailure', () {
    test('every kind yields one sentence, one next step, and no emdash', () {
      const samples = [
        '(status: LOGIN_REQUIRED)', '(status: DRM)', '(status: BROWSER_MISSING)', '(status: NETWORK)',
        '(status: RATE_LIMITED)', '(status: NO_MEDIA_FOUND)', '(status: HEADLESS_BLOCKED)',
        '(status: UNSUPPORTED_URL)', 'ffmpeg exited', 'mystery',
      ];
      final kinds = <FailureKind>{};
      for (final s in samples) {
        final e = describeFailure(s, browserLoginEnabled: false);
        kinds.add(e.kind);
        expect(e.headline, endsWith('.'));
        expect(e.nextStep, isNotEmpty);
        expect('${e.headline}${e.nextStep}', isNot(contains('\u2014')));
      }
      expect(kinds, FailureKind.values.toSet());
    });

    test('LOGIN_REQUIRED offers to enable browser login only while it is off', () {
      const text = '(status: LOGIN_REQUIRED)';
      expect(describeFailure(text, browserLoginEnabled: false).action, FailureAction.enableBrowserLoginAndRetry);
      expect(describeFailure(text, browserLoginEnabled: true).action, FailureAction.retry);
    });

    test('BROWSER_MISSING names Edge/Chrome and MIDA_BROWSER_PATH', () {
      final e = describeFailure('(status: BROWSER_MISSING)', browserLoginEnabled: false);
      expect(e.headline, contains('Edge'));
      expect(e.headline, contains('Chrome'));
      expect(e.nextStep, contains('MIDA_BROWSER_PATH'));
    });

    test('DRM and unsupported links offer no retry button', () {
      expect(describeFailure('(status: DRM)', browserLoginEnabled: false).action, FailureAction.none);
      expect(describeFailure('(status: UNSUPPORTED_URL)', browserLoginEnabled: false).action, FailureAction.none);
    });

    test('details keep the URL host but drop its query string', () {
      final e = describeFailure(
        'HTTP 403 from https://cdn.example/seg.ts?token=abc123&exp=1 (status: NETWORK)',
        browserLoginEnabled: false,
      );
      // UrlParser.redactUrlsInText reduces a URL to scheme://host/...
      expect(e.details, contains('https://cdn.example'));
      expect(e.details, isNot(contains('abc123')));
    });
  });
}
