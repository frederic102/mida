import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/browser_capture/page_status_detector.dart';

void main() {
  group('PageStatusDetector.detect', () {
    test('redirect to /accounts/login is loginRequired', () {
      final signal = PageStatusDetector.detect(
        finalUrl: Uri.parse('https://www.instagram.com/accounts/login/?next=/reel/xyz/'),
      );
      expect(signal, PageStatusSignal.loginRequired);
    });

    test('redirect to a bare /login path is loginRequired', () {
      final signal = PageStatusDetector.detect(finalUrl: Uri.parse('https://example.com/login'));
      expect(signal, PageStatusSignal.loginRequired);
    });

    test('a title containing "Log in" is loginRequired even without a login-shaped URL', () {
      final signal = PageStatusDetector.detect(
        finalUrl: Uri.parse('https://www.instagram.com/reel/xyz/'),
        title: 'Log in • Instagram',
      );
      expect(signal, PageStatusSignal.loginRequired);
    });

    test('a title containing "Sign in" is loginRequired', () {
      final signal = PageStatusDetector.detect(
        finalUrl: Uri.parse('https://example.com/watch'),
        title: 'Please Sign In to continue',
      );
      expect(signal, PageStatusSignal.loginRequired);
    });

    test('main-document HTTP 404 is notFound', () {
      final signal = PageStatusDetector.detect(
        finalUrl: Uri.parse('https://example.com/gone'),
        mainDocumentStatusCode: 404,
      );
      expect(signal, PageStatusSignal.notFound);
    });

    test('login signal takes priority over a coincidental 404', () {
      final signal = PageStatusDetector.detect(
        finalUrl: Uri.parse('https://example.com/login'),
        mainDocumentStatusCode: 404,
      );
      expect(signal, PageStatusSignal.loginRequired);
    });

    test('an ordinary page with a 200 and no login markers returns null', () {
      final signal = PageStatusDetector.detect(
        finalUrl: Uri.parse('https://example.com/watch?v=1'),
        title: 'Some Video Title',
        mainDocumentStatusCode: 200,
      );
      expect(signal, isNull);
    });

    test('guard can fail: a title that merely contains "login" as part of another word is not flagged', () {
      // "login" inside "loginwall" should not match \b(log ?in|sign ?in)\b
      // (a word-boundary check) - proves the pattern is not a naive
      // substring search, which would over-trigger on unrelated titles.
      final signal = PageStatusDetector.detect(
        finalUrl: Uri.parse('https://example.com/watch'),
        title: 'Behind the loginwall of a startup',
      );
      expect(signal, isNull);
    });
  });
}
