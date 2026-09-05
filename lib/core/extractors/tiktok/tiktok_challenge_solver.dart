import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../media_models.dart';

/// A parsed "wafchallenge" proof-of-work page, ready to be solved.
///
/// TikTok's anti-bot challenge embeds a base64 JSON blob in the `class`
/// attribute of an `id="cs"` element: `{v: {a: <base64 seed>, c: <base64
/// sha256 digest>}, ...}` (the `...` covers other keys TikTok includes that
/// this extractor does not need to understand, only preserve). Solving it
/// means finding the smallest non-negative integer `i` such that
/// `sha256(seed + ascii(i)) == digest`; the second request then has to prove
/// that work was done by sending a cookie built from the same JSON with a
/// `d` key added (`base64(ascii(i))`), re-encoded to base64.
///
/// Verified live 2026-09-05 (`docs/plan-phase2-extractors.md` TikTok
/// section; reference spike: `docs/spikes/tiktok_pow_spike.dart`).
class TikTokChallenge {
  /// The full decoded `id="cs"` JSON, kept intact (not just the fields this
  /// class understands) so [TikTokChallengeSolver.buildCookies] can add
  /// `d` and re-encode without dropping keys TikTok's server checks for.
  final Map<String, dynamic> raw;
  final List<int> seed;
  final List<int> expectedDigest;

  /// Cookie name for the solved-challenge value, from the `id="wci"`
  /// element's class attribute (falls back to TikTok's own default name,
  /// `_wafchallengeid`, if that element is missing).
  final String cookieName;

  /// Second cookie pair TikTok sometimes sends alongside the challenge
  /// (`id="rci"` class = cookie name, `id="rs"` class = cookie value). Both
  /// null when the page did not include one.
  final String? redirectCookieName;
  final String? redirectCookieValue;

  const TikTokChallenge({
    required this.raw,
    required this.seed,
    required this.expectedDigest,
    required this.cookieName,
    this.redirectCookieName,
    this.redirectCookieValue,
  });
}

class TikTokChallengeSolver {
  const TikTokChallengeSolver._();

  static const _defaultCookieName = '_wafchallengeid';

  /// True when [html] is a wafchallenge interstitial rather than the real
  /// video-detail page, without doing the (much more expensive) full
  /// [parse]. Callers should check this before deciding whether to solve a
  /// challenge at all.
  static bool isChallengePage(String html) => _attrClass(html, 'cs') != null;

  /// Decodes the `id="cs"` challenge blob in [html].
  ///
  /// Returns null when [html] has no `id="cs"` element at all (nothing to
  /// solve; callers should not treat that as an error by itself). Throws
  /// [MediaExtractionException] (`CHALLENGE_FAILED`) when a challenge
  /// element exists but its payload cannot be decoded as the expected
  /// `{v: {a, c}}` shape, since that means TikTok changed the challenge
  /// format underneath this parser.
  static TikTokChallenge? parse(String html) {
    final cs = _attrClass(html, 'cs');
    if (cs == null) return null;

    final Map<String, dynamic> challenge;
    try {
      challenge = jsonDecode(utf8.decode(base64.decode(_padBase64(cs)))) as Map<String, dynamic>;
    } catch (_) {
      throw const MediaExtractionException(
        'CHALLENGE_FAILED',
        'TikTok served a challenge page MiDa could not decode.',
      );
    }

    final v = challenge['v'];
    final a = v is Map ? v['a'] as String? : null;
    final c = v is Map ? v['c'] as String? : null;
    if (a == null || c == null) {
      throw const MediaExtractionException(
        'CHALLENGE_FAILED',
        'TikTok served a challenge page in a shape MiDa did not recognize.',
      );
    }

    return TikTokChallenge(
      raw: challenge,
      seed: base64.decode(_padBase64(a)),
      expectedDigest: base64.decode(_padBase64(c)),
      cookieName: _attrClass(html, 'wci') ?? _defaultCookieName,
      redirectCookieName: _attrClass(html, 'rci'),
      redirectCookieValue: _attrClass(html, 'rs'),
    );
  }

  /// Brute-forces the smallest `i` in `[0, maxAttempts]` with
  /// `sha256(challenge.seed + ascii(i)) == challenge.expectedDigest`.
  ///
  /// [maxAttempts] is an upper bound against a runaway search, not a tuned
  /// production value: the real challenge solves at i=78 in single-digit
  /// milliseconds (live-verified against
  /// `https://www.tiktok.com/@hankgreen1/video/7047596209028074758`, well
  /// inside the default). Throws [MediaExtractionException]
  /// (`CHALLENGE_FAILED`) when no `i` up to [maxAttempts] matches.
  static int solve(TikTokChallenge challenge, {int maxAttempts = 1000000}) {
    final seed = challenge.seed;
    final expected = challenge.expectedDigest;
    for (var i = 0; i <= maxAttempts; i++) {
      final digest = sha256.convert([...seed, ...utf8.encode('$i')]).bytes;
      if (_bytesEqual(digest, expected)) return i;
    }
    throw const MediaExtractionException(
      'CHALLENGE_FAILED',
      "Could not solve TikTok's anti-bot challenge within the attempt limit.",
    );
  }

  /// Builds the cookie jar entries the second request needs to prove
  /// [challenge] was solved with [solvedIndex]: the challenge cookie
  /// ([TikTokChallenge.raw] plus a `d` key, base64-re-encoded) under
  /// [TikTokChallenge.cookieName], plus the redirect-tracking cookie pair
  /// when the page sent one.
  static Map<String, String> buildCookies(TikTokChallenge challenge, int solvedIndex) {
    final solved = Map<String, dynamic>.from(challenge.raw);
    solved['d'] = base64.encode(utf8.encode('$solvedIndex'));

    final cookies = <String, String>{
      challenge.cookieName: base64.encode(utf8.encode(jsonEncode(solved))),
    };
    final redirectName = challenge.redirectCookieName;
    final redirectValue = challenge.redirectCookieValue;
    if (redirectName != null && redirectValue != null) {
      cookies[redirectName] = redirectValue;
    }
    return cookies;
  }

  static bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Reads the `class` attribute of the element with `id="$id"` (e.g.
  /// `<p id="cs" class="...">`), tolerant of attribute order. Returns null
  /// when no such element exists.
  static String? _attrClass(String html, String id) {
    final tag = RegExp('<[^>]+\\bid="$id"[^>]*>').firstMatch(html);
    if (tag == null) return null;
    return RegExp('class="([^"]*)"').firstMatch(tag.group(0)!)?.group(1);
  }

  /// TikTok's challenge blobs are base64 without padding. Appending `===`
  /// and truncating to the nearest multiple of 4 pads unpadded input back
  /// to a decodable length without disturbing already-padded input.
  static String _padBase64(String value) => '$value==='.substring(0, (value.length + 3) ~/ 4 * 4);
}
