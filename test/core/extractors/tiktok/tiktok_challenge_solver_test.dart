import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/extractors/tiktok/tiktok_challenge_solver.dart';

/// Builds a synthetic wafchallenge page whose answer is a known index, the
/// same shape TikTok's real `id="cs"` element uses (see
/// `docs/spikes/tiktok_pow_spike.dart` / `docs/plan-phase2-extractors.md`).
/// [answerIndex] fixes the "correct" i so tests can assert an exact solve
/// result instead of just "some digest matched".
String _buildChallengeHtml({
  required int answerIndex,
  String seedText = 'synthetic-seed-fixture-01',
  String wciCookieName = 'mycookiename',
  String? rciCookieName,
  String? rsCookieValue,
}) {
  final seed = utf8.encode(seedText);
  final digest = sha256.convert([...seed, ...utf8.encode('$answerIndex')]).bytes;
  final challenge = {
    'v': {'a': base64.encode(seed), 'c': base64.encode(digest)},
    // An extra key TikTok's real payload carries that this parser does not
    // need to understand, only preserve (proves buildCookies round-trips
    // the whole blob, not just `v`).
    'unrelated_key': 'must-round-trip',
  };
  final cs = base64.encode(utf8.encode(jsonEncode(challenge))).replaceAll('=', '');

  final buffer = StringBuffer()
    ..write('<html><body>Please wait...')
    ..write('<p id="wci" class="$wciCookieName"></p>')
    ..write('<p id="cs" class="$cs"></p>');
  if (rciCookieName != null) {
    buffer.write('<p id="rci" class="$rciCookieName"></p>');
    buffer.write('<p id="rs" class="$rsCookieValue"></p>');
  }
  buffer.write('</body></html>');
  return buffer.toString();
}

void main() {
  group('TikTokChallengeSolver.parse', () {
    test('null when the page has no id="cs" element at all', () {
      expect(TikTokChallengeSolver.parse('<html><body>ok</body></html>'), isNull);
      expect(TikTokChallengeSolver.isChallengePage('<html><body>ok</body></html>'), isFalse);
    });

    test('decodes seed/expectedDigest and cookie names from a synthetic challenge page', () {
      final html = _buildChallengeHtml(
        answerIndex: 4242,
        rciCookieName: 'redirectname',
        rsCookieValue: 'redirectvalue',
      );
      expect(TikTokChallengeSolver.isChallengePage(html), isTrue);

      final challenge = TikTokChallengeSolver.parse(html)!;
      expect(utf8.decode(challenge.seed), 'synthetic-seed-fixture-01');
      expect(challenge.cookieName, 'mycookiename');
      expect(challenge.redirectCookieName, 'redirectname');
      expect(challenge.redirectCookieValue, 'redirectvalue');
      expect(challenge.raw['unrelated_key'], 'must-round-trip');
    });

    test('falls back to the default cookie name when id="wci" is missing', () {
      final html = '<html><body><p id="cs" class="${base64.encode(utf8.encode(jsonEncode({
        'v': {'a': base64.encode(utf8.encode('s')), 'c': base64.encode(sha256.convert(utf8.encode('s0')).bytes)},
      })))}"></p></body></html>';
      final challenge = TikTokChallengeSolver.parse(html)!;
      expect(challenge.cookieName, '_wafchallengeid');
      expect(challenge.redirectCookieName, isNull);
    });

    test('CHALLENGE_FAILED when the id="cs" payload is not the expected {v:{a,c}} shape', () {
      const html = '<html><body><p id="cs" class="bm90LWpzb24="></p></body></html>';
      expect(
        () => TikTokChallengeSolver.parse(html),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'CHALLENGE_FAILED')),
      );
    });
  });

  group('TikTokChallengeSolver.solve', () {
    test('finds the known answer index (i=4242) for a synthetic challenge', () {
      final challenge = TikTokChallengeSolver.parse(_buildChallengeHtml(answerIndex: 4242))!;
      expect(TikTokChallengeSolver.solve(challenge), 4242);
    });

    // Guard-can-fail evidence: this asserts CHALLENGE_FAILED only because
    // solve() actually stops searching at maxAttempts. The real answer
    // (4242) is reachable well within the default 1,000,000 cap, so if the
    // upper-bound check were ever removed/broken (e.g. `i <= maxAttempts`
    // silently ignored, or maxAttempts hardcoded past 4242), this test
    // would flip from throwing to returning 4242 and go red - proving the
    // cap is load-bearing rather than decorative. Confirmed by temporarily
    // changing `i <= maxAttempts` to `i <= 1000000` in
    // `tiktok_challenge_solver.dart` while running this test: it fails.
    test('CHALLENGE_FAILED when the answer is beyond maxAttempts', () {
      final challenge = TikTokChallengeSolver.parse(_buildChallengeHtml(answerIndex: 4242))!;
      expect(
        () => TikTokChallengeSolver.solve(challenge, maxAttempts: 10),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'CHALLENGE_FAILED')),
      );
    });

    test('solve is inclusive of maxAttempts itself (off-by-one boundary)', () {
      final challenge = TikTokChallengeSolver.parse(_buildChallengeHtml(answerIndex: 7))!;
      expect(TikTokChallengeSolver.solve(challenge, maxAttempts: 7), 7);
      expect(
        () => TikTokChallengeSolver.solve(challenge, maxAttempts: 6),
        throwsA(isA<MediaExtractionException>()),
      );
    });
  });

  group('TikTokChallengeSolver.buildCookies', () {
    test('assembles the challenge cookie with a solved d value under the page-provided name', () {
      final challenge = TikTokChallengeSolver.parse(_buildChallengeHtml(
        answerIndex: 4242,
        wciCookieName: 'customwafname',
      ))!;
      final cookies = TikTokChallengeSolver.buildCookies(challenge, 4242);

      expect(cookies.keys, contains('customwafname'));
      final decoded = jsonDecode(utf8.decode(base64.decode(cookies['customwafname']!))) as Map<String, dynamic>;
      expect(decoded['d'], base64.encode(utf8.encode('4242')));
      expect(decoded['unrelated_key'], 'must-round-trip', reason: 'must not drop keys it does not understand');
    });

    test('includes the redirect cookie pair when the page sent one', () {
      final challenge = TikTokChallengeSolver.parse(_buildChallengeHtml(
        answerIndex: 1,
        rciCookieName: 'waforiginalreid',
        rsCookieValue: 'abc123',
      ))!;
      final cookies = TikTokChallengeSolver.buildCookies(challenge, 1);
      expect(cookies['waforiginalreid'], 'abc123');
    });

    // Guard-can-fail evidence: this only proves something because the
    // no-rci fixture genuinely omits the elements (verified above the rci
    // page's parse() sets redirectCookieName to null). If buildCookies
    // stopped checking for null and always added a redirect cookie key,
    // this would go red (cookies.length would be 2, not 1).
    test('does not invent a redirect cookie when the page sent none', () {
      final challenge = TikTokChallengeSolver.parse(_buildChallengeHtml(answerIndex: 1))!;
      final cookies = TikTokChallengeSolver.buildCookies(challenge, 1);
      expect(cookies.length, 1);
    });
  });
}
