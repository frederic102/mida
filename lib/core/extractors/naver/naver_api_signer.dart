import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Policy: this reproduces the site's own public web-player request contract
/// (a signing constant shipped in the site's JavaScript to every visitor). No
/// challenge solving, no fingerprint spoofing. If the site changes its
/// contract we stop working there; we do not evade.
///
/// Replicates the request-signing scheme `tv.naver.com`'s own web client
/// (the Next.js bundle's `_app` chunk) computes client-side before calling
/// its `apis.naver.com/now_web2/now_web_api/v1/...` gateway. Reverse
/// engineered live 2026-09-05 by reading the minified signing function out
/// of that bundle and confirming a known request's `md` value reproduces
/// byte-for-byte (`docs/plan-phase5-coverage.md` Lane C):
///
/// ```
/// msgpad = current time in epoch milliseconds
/// message = urlWithQueryParams.substring(0, min(255, length)) + msgpad
/// md = base64(HMAC-SHA1(message, key = secretKey))
/// signedUrl = urlWithQueryParams + (has '?' ? '&' : '?') + "msgpad=$msgpad&md=$urlEncodedMd"
/// ```
///
/// `secretKey` is a fixed string shipped in that same bundle (not a
/// per-user or per-session secret - every visitor's browser signs with the
/// identical key), so hardcoding it here carries no user credential.
class NaverApiSigner {
  const NaverApiSigner();

  static const _secretKey = 'nbxvs5nwNG9QKEWK0ADjYA4JZoujF4gHcIwvoCxFTPAeamq5eemvt5IWAYXxrbYM';
  static const _maxSignedLength = 255;

  /// Returns [url] with `msgpad`/`md` query parameters appended.
  /// [nowMillis] is injectable (defaults to [DateTime.now]) so tests can
  /// assert an exact, reproducible signature instead of one that changes
  /// every run.
  Uri sign(Uri url, {int? nowMillis}) {
    final msgpad = nowMillis ?? DateTime.now().millisecondsSinceEpoch;
    final urlString = url.toString();
    final truncated =
        urlString.substring(0, urlString.length < _maxSignedLength ? urlString.length : _maxSignedLength);
    final message = utf8.encode('$truncated$msgpad');
    final signature = base64.encode(Hmac(sha1, utf8.encode(_secretKey)).convert(message).bytes);

    final separator = urlString.contains('?') ? '&' : '?';
    return Uri.parse('$urlString$separator'
        'msgpad=$msgpad&md=${Uri.encodeComponent(signature)}');
  }
}
