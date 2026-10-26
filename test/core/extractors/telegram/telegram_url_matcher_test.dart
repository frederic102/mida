import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/telegram/telegram_url_matcher.dart';

void main() {
  group('TelegramUrlMatcher', () {
    test('accepts the public post shapes and builds the embed URL from validated parts', () {
      for (final input in [
        'https://t.me/mida_demo/101',
        'https://t.me/mida_demo/101/',
        'https://t.me/s/mida_demo/101',
        'http://t.me/mida_demo/101?single',
        'https://telegram.me/mida_demo/101',
        'https://www.t.me/Mida_Demo/101?comment=5',
      ]) {
        final ref = TelegramUrlMatcher.match(Uri.parse(input));
        expect(ref, isNotNull, reason: input);
        expect(ref!.postId, '101');
        expect(ref.embedUrl.scheme, 'https');
        expect(ref.embedUrl.host, 't.me');
        expect(ref.embedUrl.path, '/${ref.channel}/101');
        expect(ref.embedUrl.queryParameters, {'embed': '1', 'mode': 'tme'});
      }
    });

    test('rejects private-channel links, channel pages, bad ids and foreign hosts', () {
      for (final input in [
        'https://t.me/c/1234567/10',
        'https://t.me/mida_demo',
        'https://t.me/s/mida_demo',
        'https://t.me/mida_demo/abc',
        'https://t.me/mida_demo/0',
        'https://t.me/mida_demo/1234567890123',
        'https://t.me/mida_demo/101/extra',
        'https://t.me/+AbCdEfGh/5',
        'https://t.me/ab/101',
        'https://t.me/mida-demo/101',
        'https://t.me/joinchat/101',
        'https://evil.test/mida_demo/101',
        'https://t.me.evil.test/mida_demo/101',
        'ftp://t.me/mida_demo/101',
      ]) {
        expect(TelegramUrlMatcher.match(Uri.parse(input)), isNull, reason: input);
      }
    });

    test('undecodable percent bytes never throw: no match', () {
      expect(TelegramUrlMatcher.match(Uri.parse('https://t.me/mida_demo/%FF')), isNull);
      expect(TelegramUrlMatcher.match(Uri.parse('https://t.me/%FF/101')), isNull);
    });

    test('a path that tries to inject into the embed URL never matches', () {
      expect(TelegramUrlMatcher.match(Uri.parse('https://t.me/mida_demo/101%2F..%2Fx')), isNull);
      expect(TelegramUrlMatcher.match(Uri.parse('https://t.me/mida_demo%3Fx=1/101')), isNull);
    });
  });
}
