import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/browser_capture/headless_block_detector.dart';

const String _longText =
    'This is an ordinary article page with plenty of readable body text and no video at all. '
    'It goes on for well over the empty shell threshold so it must never look blocked.';

HeadlessVerdict _classify({String title = 'x', String? body = _longText, String? html, int? status}) =>
    HeadlessBlockDetector.classify(title: title, bodyText: body, html: html, mainDocumentStatus: status);

/// Phase 7 round 2 (Gadfly G1, Bulwark B3, Plumbline P2, astra B#8): every
/// positive below has a negative twin that differs only in the evidence, so
/// an always-blocked or never-blocked detector fails one of each pair.
void main() {
  group('positives: challenge-document shapes', () {
    test('challenge title', () {
      expect(_classify(title: 'Attention Required! | Cloudflare'), HeadlessVerdict.blocked);
      expect(_classify(title: 'Just a moment...', status: 503), HeadlessVerdict.blocked);
    });

    test('DataDome captcha iframe / script host', () {
      expect(_classify(html: '<iframe src="https://geo.captcha-delivery.com/captcha/?initialCid=a"></iframe>'),
          HeadlessVerdict.blocked);
      expect(_classify(html: "<script src='https://ct.captcha-delivery.com/c.js'></script>"), HeadlessVerdict.blocked);
    });

    test('Cloudflare challenge-page orchestrator and _cf_chl_opt global', () {
      expect(
        _classify(html: '<script src="/cdn-cgi/challenge-platform/h/b/orchestrate/chl_page/v1?ray=1"></script>'),
        HeadlessVerdict.blocked,
      );
      expect(_classify(html: '<script>window._cf_chl_opt={cvId:"3"};</script>'), HeadlessVerdict.blocked);
    });

    test('PerimeterX captcha container', () {
      expect(_classify(html: '<div id="px-captcha"></div>'), HeadlessVerdict.blocked);
    });

    test('thin body with a 403 main document', () {
      expect(_classify(body: 'short', status: 403), HeadlessVerdict.blocked);
    });

    test('Turnstile iframe counts only together with a non-2xx status', () {
      const turnstile = '<iframe src="https://challenges.cloudflare.com/cdn-cgi/challenge-platform/x"></iframe>';
      expect(_classify(html: turnstile, status: 403), HeadlessVerdict.blocked);
      expect(_classify(html: turnstile, status: 200), HeadlessVerdict.notBlocked);
    });
  });

  group('negatives: never evidence of a block', () {
    test('sensor-only article page (DataDome + PerimeterX + CF jsd scripts, 200)', () {
      const html = '<html><head>'
          '<script src="https://js.datadome.co/tags.js"></script>'
          '<script>window.ddjskey="ABC"; window._pxAppId="PXabc"; // perimeterx sensor</script>'
          '<script src="//client.perimeterx.net/PXabc/main.min.js"></script>'
          '<script src="/cdn-cgi/challenge-platform/scripts/jsd/main.js"></script>'
          '</head><body><article>datadome perimeterx</article></body></html>';
      expect(_classify(html: html, status: 200), HeadlessVerdict.notBlocked);
    });

    test('player-only 200 page with almost no text', () {
      expect(_classify(body: '', html: '<video></video>', status: 200), HeadlessVerdict.notBlocked);
    });

    test('tech article mentioning DataDome and captcha-delivery.com in prose', () {
      const html = '<p>We compared DataDome, PerimeterX and the geo.captcha-delivery.com flow '
          'in cdn-cgi/challenge-platform/h/b/orchestrate docs.</p>';
      expect(_classify(html: html, status: 200), HeadlessVerdict.notBlocked);
    });

    test('thin body with an unknown status (no main-document response seen)', () {
      expect(_classify(body: ''), HeadlessVerdict.notBlocked);
    });

    test('failed eval reads (null title/body) are not evidence', () {
      expect(HeadlessBlockDetector.classify(mainDocumentStatus: 403), HeadlessVerdict.notBlocked);
      expect(HeadlessBlockDetector.classify(), HeadlessVerdict.notBlocked);
    });

    test('a 403 with a full content page and no markup', () {
      expect(_classify(status: 403), HeadlessVerdict.notBlocked);
    });

    test('a look-alike host is not the DataDome captcha host', () {
      expect(_classify(html: '<script src="https://captcha-delivery.com.evil.example/x.js"></script>'),
          HeadlessVerdict.notBlocked);
    });
  });

  group('astra round 2: only real attributes with exact values count', () {
    test('data-id="px-captcha-demo" is not the px-captcha container', () {
      expect(_classify(html: '<div data-id="px-captcha-demo">Tutorial</div>', status: 200), HeadlessVerdict.notBlocked);
      expect(_classify(html: '<div data-id="px-captcha"></div>', status: 200), HeadlessVerdict.notBlocked);
    });

    test('a suffixed id="px-captcha-demo" is not the container', () {
      expect(_classify(html: '<div id="px-captcha-demo"></div>', status: 200), HeadlessVerdict.notBlocked);
    });

    test('an HTML comment is not evidence', () {
      expect(_classify(html: '<!-- <div id="px-captcha"></div> <iframe src="https://geo.captcha-delivery.com/c"> -->'),
          HeadlessVerdict.notBlocked);
    });

    test('escaped or quoted markup in a code sample is not evidence', () {
      expect(_classify(html: '<p>&lt;div id="px-captcha"&gt;&lt;/div&gt;</p>'), HeadlessVerdict.notBlocked);
      expect(_classify(html: '<pre><div id="px-captcha"></div></pre>'), HeadlessVerdict.notBlocked);
      expect(_classify(html: '<code><iframe src="https://geo.captcha-delivery.com/c"></iframe></code>'),
          HeadlessVerdict.notBlocked);
      expect(_classify(html: '<div title=\'<div id="px-captcha">\'>docs</div>'), HeadlessVerdict.notBlocked);
      expect(_classify(html: '<script>const sample = \'<div id="px-captcha"></div>\';</script>'),
          HeadlessVerdict.notBlocked);
    });

    test('astra round 3: script/iframe srcs in template, noscript or a quoted attribute are not evidence', () {
      expect(_classify(html: '<template><script src="https://geo.captcha-delivery.com/check"></script></template>'),
          HeadlessVerdict.notBlocked);
      expect(_classify(html: '<noscript><iframe src="https://geo.captcha-delivery.com/c"></iframe></noscript>'),
          HeadlessVerdict.notBlocked);
      expect(_classify(html: '<div title=\'<script src="https://geo.captcha-delivery.com/x"></script>\'>doc</div>'),
          HeadlessVerdict.notBlocked);
      // Positive twin: the same script in live markup is still a challenge.
      expect(_classify(html: '<body><script src="https://geo.captcha-delivery.com/check"></script></body>'),
          HeadlessVerdict.blocked);
    });

    test('a _cf_chl_opt mention in text or a JS comment is not the global', () {
      expect(_classify(html: '<p>window._cf_chl_opt = {} is set by Cloudflare</p>'), HeadlessVerdict.notBlocked);
      expect(_classify(html: '<script>/* window._cf_chl_opt={} */ var x = 1;</script>'), HeadlessVerdict.notBlocked);
    });

    test('positive twins: the real container and an unquoted / single-quoted id still count', () {
      expect(_classify(html: '<div id=px-captcha></div>'), HeadlessVerdict.blocked);
      expect(_classify(html: "<div class='c' id='px-captcha'></div>"), HeadlessVerdict.blocked);
      expect(_classify(html: '<form id="challenge-form" action="/x"></form>'), HeadlessVerdict.blocked);
    });
  });

  group('status mapping without challenge evidence', () {
    test('429 is rateLimited, even with a thin body', () {
      expect(_classify(body: '', status: 429), HeadlessVerdict.rateLimited);
    });

    test('5xx is serverError', () {
      expect(_classify(body: '', status: 500), HeadlessVerdict.serverError);
      expect(_classify(status: 503), HeadlessVerdict.serverError);
    });

    test('challenge evidence outranks the status', () {
      expect(_classify(status: 429, html: '<div id="px-captcha"></div>'), HeadlessVerdict.blocked);
    });
  });
}
