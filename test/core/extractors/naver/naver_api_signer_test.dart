import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/naver/naver_api_signer.dart';

void main() {
  group('NaverApiSigner.sign', () {
    // Reproduces a real request captured live 2026-09-05 via CDP against
    // tv.naver.com's own web client (docs/plan-phase5-coverage.md Lane C):
    // for this exact url + msgpad, the real client sent
    // md=o1aSl7E5MVDG5oE0cCi6vf8%2BPHg%3D (url-decoded: o1aSl7E5MVDG5oE0cCi6vf8+PHg=).
    // This is the guard-can-fail case: any change to the message
    // construction (truncation point, key, or hash algorithm) changes this
    // signature, so a regression here is caught exactly, not just
    // "produces *a* string".
    test('matches a known-good signature captured from the real web client', () {
      const signer = NaverApiSigner();
      final url = Uri.parse(
        'https://apis.naver.com/now_web2/now_web_api/v1/clips/72311805/play-info',
      );

      final signed = signer.sign(url, nowMillis: 1788609332593);

      expect(signed.queryParameters['msgpad'], '1788609332593');
      expect(signed.queryParameters['md'], 'o1aSl7E5MVDG5oE0cCi6vf8+PHg=');
    });

    test('appends msgpad/md with "?" when the url has no existing query', () {
      const signer = NaverApiSigner();
      final signed = signer.sign(Uri.parse('https://apis.naver.com/x/y'), nowMillis: 1);
      expect(signed.toString(), startsWith('https://apis.naver.com/x/y?msgpad=1&md='));
    });

    test('appends msgpad/md with "&" when the url already has a query', () {
      const signer = NaverApiSigner();
      final signed = signer.sign(Uri.parse('https://apis.naver.com/x/y?a=b'), nowMillis: 1);
      expect(signed.toString(), startsWith('https://apis.naver.com/x/y?a=b&msgpad=1&md='));
    });

    test('two different nowMillis values produce two different signatures', () {
      const signer = NaverApiSigner();
      final url = Uri.parse('https://apis.naver.com/x/y');
      final first = signer.sign(url, nowMillis: 1000);
      final second = signer.sign(url, nowMillis: 2000);
      expect(first.queryParameters['md'], isNot(second.queryParameters['md']));
    });
  });
}
