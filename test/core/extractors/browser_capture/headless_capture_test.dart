import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/browser_capture/browser_capture_extractor.dart';
import 'package:mida/core/extractors/extractor_registry_builder.dart';
import 'package:mida/core/extractors/media_models.dart';

import 'fake_devtools_session.dart';

const String _longText =
    'This is an ordinary article page with plenty of readable body text and no video at all. '
    'It goes on for well over the empty shell threshold so it must never look blocked.';

/// A page that fires `load`, has no media, and reports title/body/html.
FakeDevtoolsSession _page({
  required String title,
  required String bodyText,
  String html = '<html><body>x</body></html>',
  bool fireLoad = true,
  int? status,
  bool evalFails = false,
}) {
  late FakeDevtoolsSession session;
  session = FakeDevtoolsSession(
    onSend: (method, params) async {
      if (method == 'Page.navigate') {
        if (status != null) {
          // The main document's own response, as MainDocumentStatusTracker sees it.
          session.emit('Network.requestWillBeSent', {
            'type': 'Document',
            'requestId': 'main',
            'request': {'url': _url.toString()},
          });
          session.emit('Network.responseReceived', {
            'type': 'Document',
            'requestId': 'main',
            'response': {'url': _url.toString(), 'status': status, 'mimeType': 'text/html'},
          });
        }
        if (fireLoad) Timer(const Duration(milliseconds: 10), () => session.emit('Page.loadEventFired', const {}));
        return {};
      }
      if (method == 'Runtime.evaluate' && evalFails) throw StateError('Runtime.evaluate failed');
      if (method != 'Runtime.evaluate') return {};
      final expression = params?['expression'] as String? ?? '';
      if (expression.contains('querySelectorAll')) return stringEvalResult('[]');
      if (expression.contains('outerHTML')) return stringEvalResult(html);
      if (expression.contains('JSON.stringify')) {
        return stringEvalResult(
          jsonEncode({'title': title, 'ogTitle': null, 'ogImage': null, 'href': 'https://example.com/v'}),
        );
      }
      if (expression == 'document.title') return stringEvalResult(title);
      if (expression.contains('innerText')) return stringEvalResult(bodyText);
      return {};
    },
  );
  return session;
}

BrowserCaptureExtractor _extractor(
  FakeDevtoolsSession Function() sessionFactory,
  List<bool> launches, {
  bool forceHeadless = false,
  Map<String, String>? environment,
}) =>
    BrowserCaptureExtractor(
      sessionLauncher: ({connectTimeout = const Duration()}) async => sessionFactory(),
      launchObserver: ({required preferHeaded}) => launches.add(preferHeaded),
      forceHeadless: forceHeadless,
      environment: environment ?? const <String, String>{},
      loadTimeout: const Duration(milliseconds: 100),
      postLoadDelay: const Duration(milliseconds: 5),
      autoplayRetryDelay: const Duration(milliseconds: 5),
      firstCandidateTimeout: const Duration(milliseconds: 20),
      variantSettleDelay: const Duration(milliseconds: 5),
      pollInterval: const Duration(milliseconds: 5),
    );

Matcher _throwsStatus(String status) =>
    throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', status));

final Uri _url = Uri.parse('https://example.com/v');

void main() {
  group('forceHeadless launch policy', () {
    test('forceHeadless makes exactly one launch, preferHeaded=false, even when the page never loads', () async {
      final launches = <bool>[];
      final extractor = _extractor(
        () => _page(title: 'Plain', bodyText: _longText, fireLoad: false),
        launches,
        forceHeadless: true,
      );
      await expectLater(extractor.extract(_url), _throwsStatus('NO_MEDIA_FOUND'));
      expect(launches, [false]);
    });

    test('without forceHeadless the first launch prefers headed (guard can fail)', () async {
      final launches = <bool>[];
      final extractor = _extractor(() => _page(title: 'Plain', bodyText: _longText), launches);
      await expectLater(extractor.extract(_url), _throwsStatus('NO_MEDIA_FOUND'));
      expect(launches.first, isTrue);
    });

    test('MIDA_HEADLESS=1 in the environment behaves like forceHeadless', () async {
      final launches = <bool>[];
      final extractor = _extractor(
        () => _page(title: 'Plain', bodyText: _longText, fireLoad: false),
        launches,
        environment: const {'MIDA_HEADLESS': '1'},
      );
      await expectLater(extractor.extract(_url), _throwsStatus('NO_MEDIA_FOUND'));
      expect(launches, [false]);
    });

    test('buildExtractorRegistry threads forceHeadless into the browser-capture fallback', () {
      final on = buildExtractorRegistry(forceHeadless: true).fallbacks.whereType<BrowserCaptureExtractor>().single;
      final off = buildExtractorRegistry().fallbacks.whereType<BrowserCaptureExtractor>().single;
      expect(on.forceHeadless, isTrue);
      expect(off.forceHeadless, isFalse);
    });
  });

  group('HEADLESS_BLOCKED', () {
    test('a challenge-title page with no media throws HEADLESS_BLOCKED naming the site and a headed run', () async {
      final extractor = _extractor(
        () => _page(title: 'Just a moment...', bodyText: _longText),
        <bool>[],
        forceHeadless: true,
      );
      await expectLater(
        extractor.extract(_url),
        throwsA(isA<MediaExtractionException>()
            .having((e) => e.status, 'status', 'HEADLESS_BLOCKED')
            .having((e) => e.reason, 'reason', allOf(contains('example.com'), contains('headed')))),
      );
    });

    test('an "Access denied" title (not in the bot-check title list) is HEADLESS_BLOCKED headless', () async {
      final extractor = _extractor(
        () => _page(title: 'Access denied', bodyText: _longText),
        <bool>[],
        forceHeadless: true,
      );
      await expectLater(extractor.extract(_url), _throwsStatus('HEADLESS_BLOCKED'));
    });

    test('DataDome markup with a neutral title and long text is HEADLESS_BLOCKED', () async {
      final extractor = _extractor(
        () => _page(
          title: 'example.com',
          bodyText: _longText,
          html: '<html><script src="https://ct.captcha-delivery.com/c.js"></script></html>',
        ),
        <bool>[],
        forceHeadless: true,
      );
      await expectLater(extractor.extract(_url), _throwsStatus('HEADLESS_BLOCKED'));
    });

    test('an empty shell (tiny body text) served 403 is HEADLESS_BLOCKED', () async {
      final extractor =
          _extractor(() => _page(title: 'App', bodyText: '', status: 403), <bool>[], forceHeadless: true);
      await expectLater(extractor.extract(_url), _throwsStatus('HEADLESS_BLOCKED'));
    });

    test('round 2 (G1/P2): a player-only 200 page with tiny body text is NOT blocked', () async {
      final extractor =
          _extractor(() => _page(title: 'Watch', bodyText: '', status: 200), <bool>[], forceHeadless: true);
      await expectLater(extractor.extract(_url), _throwsStatus('NO_MEDIA_FOUND'));
    });

    test('round 2 (B3/astra B#8): a loaded media-free 429 page is RATE_LIMITED, not HEADLESS_BLOCKED', () async {
      final extractor =
          _extractor(() => _page(title: 'Too Many Requests', bodyText: '', status: 429), <bool>[], forceHeadless: true);
      await expectLater(extractor.extract(_url), _throwsStatus('RATE_LIMITED'));
    });

    test('round 2 (B3): a 503 main document is NETWORK headless and headed', () async {
      final headless =
          _extractor(() => _page(title: 'Unavailable', bodyText: '', status: 503), <bool>[], forceHeadless: true);
      await expectLater(headless.extract(_url), _throwsStatus('NETWORK'));
      final headed = _extractor(() => _page(title: 'Unavailable', bodyText: _longText, status: 503), <bool>[]);
      await expectLater(headed.extract(_url), _throwsStatus('NETWORK'));
    });

    test('round 2 (G1): a 429 page that is also a challenge document stays HEADLESS_BLOCKED', () async {
      final extractor = _extractor(
        () => _page(
          title: 'example.com',
          bodyText: '',
          status: 429,
          html: '<iframe src="https://geo.captcha-delivery.com/captcha/?initialCid=x"></iframe>',
        ),
        <bool>[],
        forceHeadless: true,
      );
      await expectLater(extractor.extract(_url), _throwsStatus('HEADLESS_BLOCKED'));
    });

    test('round 2 (G1): failed Runtime.evaluate reads are not evidence of a block', () async {
      final extractor =
          _extractor(() => _page(title: 'x', bodyText: '', evalFails: true), <bool>[], forceHeadless: true);
      await expectLater(extractor.extract(_url), _throwsStatus('NO_MEDIA_FOUND'));
    });

    test('flip-proof: a normal text-rich page with no media stays NO_MEDIA_FOUND headless', () async {
      // Together with the tests above this pins the detector from both
      // sides: an always-false detector fails the blocked cases, an
      // always-true one fails this case.
      final extractor = _extractor(
        () => _page(title: 'Plain article', bodyText: _longText),
        <bool>[],
        forceHeadless: true,
      );
      await expectLater(extractor.extract(_url), _throwsStatus('NO_MEDIA_FOUND'));
    });

    test('NOT thrown when forceHeadless=false: same fixtures keep their headed-path errors', () async {
      final challenge = _extractor(() => _page(title: 'Just a moment...', bodyText: _longText), <bool>[]);
      await expectLater(challenge.extract(_url), _throwsStatus('BOT_CHECK_REQUIRED'));
      final shell = _extractor(() => _page(title: 'App', bodyText: ''), <bool>[]);
      await expectLater(shell.extract(_url), _throwsStatus('NO_MEDIA_FOUND'));
    });

    test('a login wall stays LOGIN_REQUIRED headless (not reclassified as blocked)', () async {
      final extractor = _extractor(() => _page(title: 'Log in', bodyText: ''), <bool>[], forceHeadless: true);
      await expectLater(extractor.extract(_url), _throwsStatus('LOGIN_REQUIRED'));
    });

    test('a page that never fired load is not called blocked (nothing was seen)', () async {
      final extractor = _extractor(
        () => _page(title: 'App', bodyText: '', fireLoad: false),
        <bool>[],
        forceHeadless: true,
      );
      await expectLater(extractor.extract(_url), _throwsStatus('NO_MEDIA_FOUND'));
    });
  });
}
