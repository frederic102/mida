import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/extractors/tiktok/tiktok_extractor.dart';

/// Builds a synthetic wafchallenge page whose answer is [answerIndex] (kept
/// small so the extractor's real brute-force solver finishes instantly in
/// this hermetic test, same construction as
/// `tiktok_challenge_solver_test.dart`).
String _buildChallengeHtml(int answerIndex, {required String wciCookieName}) {
  final seed = utf8.encode('server-seed');
  final digest = sha256.convert([...seed, ...utf8.encode('$answerIndex')]).bytes;
  final challenge = {
    'v': {'a': base64.encode(seed), 'c': base64.encode(digest)},
  };
  final cs = base64.encode(utf8.encode(jsonEncode(challenge))).replaceAll('=', '');
  return '<html><body>Please wait...'
      '<p id="wci" class="$wciCookieName"></p>'
      '<p id="cs" class="$cs"></p>'
      '</body></html>';
}

const _wciCookieName = 'testwafid';

String _universalDataHtml({String desc = 'a fake tiktok', String id = '123'}) {
  final json = jsonEncode({
    '__DEFAULT_SCOPE__': {
      'webapp.video-detail': {
        'statusCode': 0,
        'itemInfo': {
          'itemStruct': {
            'id': id,
            'desc': desc,
            'author': {'uniqueId': 'faketestuser'},
            'video': {
              'duration': 10,
              'cover': 'https://example.com/cover.jpg',
              'bitrateInfo': [
                {
                  'Bitrate': 500000,
                  'PlayAddr': {
                    'UrlList': ['https://example.com/v.mp4'],
                    'Width': 720,
                    'Height': 1280,
                    'UrlKey': 'k',
                    'DataSize': 12345,
                  },
                },
              ],
            },
          },
        },
      },
    },
  });
  return '<html><body><script id="__UNIVERSAL_DATA_FOR_REHYDRATION__" type="application/json">$json</script></body></html>';
}

/// Local stand-in for `www.tiktok.com`: serves the challenge page until it
/// sees a Cookie header containing [_wciCookieName], then serves
/// `__UNIVERSAL_DATA_FOR_REHYDRATION__`. Also answers a fixed 302 for
/// `/short-link` to exercise shortlink resolution. Same pattern as
/// `twitter_extractor_test.dart`'s `_FixedResponseServer`.
class _FakeTikTokServer {
  final HttpServer server;
  int fixedStatusCode = 0;
  int challengeAnswerIndex = 5;
  bool neverAcceptSolution = false;
  bool serveAntiBotShell = false;
  final List<String?> cookieHeadersSeen = [];

  _FakeTikTokServer(this.server);

  static Future<_FakeTikTokServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final instance = _FakeTikTokServer(server);
    server.listen(instance._handle);
    return instance;
  }

  Uri get baseUri => Uri(scheme: 'http', host: '127.0.0.1', port: server.port);

  Future<void> _handle(HttpRequest request) async {
    cookieHeadersSeen.add(request.headers.value('cookie'));

    if (request.uri.path == '/short-link') {
      request.response.statusCode = 302;
      request.response.headers.set('location', '/@resolveduser/video/999888777');
      await request.response.close();
      return;
    }

    if (fixedStatusCode != 0) {
      request.response.statusCode = fixedStatusCode;
      await request.response.close();
      return;
    }

    if (serveAntiBotShell) {
      request.response.statusCode = 200;
      // Modeled on the real ~44KB interstitial observed live 2026-09-05:
      // no `id="cs"` challenge element, no rehydration script - just an
      // unrelated tracking/config script tag.
      request.response.write(
        '<html><head><script id="pumbaa-rule" type="application/json">{"_r":"unrelated"}</script>'
        '</head><body>Please wait...</body></html>',
      );
      await request.response.close();
      return;
    }

    final cookieHeader = request.headers.value('cookie') ?? '';
    request.response.statusCode = 200;
    if (!neverAcceptSolution && cookieHeader.contains(_wciCookieName)) {
      request.response.write(_universalDataHtml());
    } else {
      request.response.write(_buildChallengeHtml(challengeAnswerIndex, wciCookieName: _wciCookieName));
    }
    await request.response.close();
  }

  Future<void> close() => server.close(force: true);
}

void main() {
  late _FakeTikTokServer server;

  setUp(() async => server = await _FakeTikTokServer.start());
  tearDown(() => server.close());

  TikTokExtractor buildExtractor() => TikTokExtractor(
        requestUrlBuilder: (url) => server.baseUri.replace(path: url.path, query: url.query),
      );

  group('TikTokExtractor.canHandle', () {
    test('accepts tiktok.com, vm.tiktok.com and vt.tiktok.com URLs', () {
      final extractor = buildExtractor();
      expect(extractor.canHandle(Uri.parse('https://www.tiktok.com/@user/video/123')), isTrue);
      expect(extractor.canHandle(Uri.parse('https://vm.tiktok.com/ZM6abc123/')), isTrue);
      expect(extractor.canHandle(Uri.parse('https://vt.tiktok.com/ZS6abc123/')), isTrue);
    });

    test('rejects unrelated hosts', () {
      expect(buildExtractor().canHandle(Uri.parse('https://evil.example/@user/video/123')), isFalse);
    });
  });

  group('TikTokExtractor.extract solving the challenge against a local fake server', () {
    test('solves the challenge, retries with the cookie, and parses the result', () async {
      final info = await buildExtractor().extract(Uri.parse('https://www.tiktok.com/@hankgreen1/video/7047596209028074758'));

      expect(info.title, '@faketestuser - a fake tiktok');
      expect(info.author, 'faketestuser');
      expect(info.formats.single.url, 'https://example.com/v.mp4');
      expect(server.cookieHeadersSeen.length, 2, reason: 'challenge GET then solved-cookie GET');
      expect(server.cookieHeadersSeen.first, isNull, reason: 'no cookie on the first request');
      expect(server.cookieHeadersSeen.last, contains(_wciCookieName));
    });

    test('the returned requestHeaders include User-Agent, Referer and the solved cookie', () async {
      final info = await buildExtractor().extract(Uri.parse('https://www.tiktok.com/@hankgreen1/video/7047596209028074758'));
      expect(info.requestHeaders['Referer'], 'https://www.tiktok.com/');
      expect(info.requestHeaders['User-Agent'], isNotEmpty);
      expect(info.requestHeaders['Cookie'], contains(_wciCookieName));
    });

    test('CHALLENGE_FAILED when the server keeps serving a challenge even after the solved cookie', () async {
      server.neverAcceptSolution = true;
      await expectLater(
        buildExtractor().extract(Uri.parse('https://www.tiktok.com/@hankgreen1/video/7047596209028074758')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'CHALLENGE_FAILED')),
      );
    });

    test('RATE_LIMITED (not CHALLENGE_FAILED) when the first response is the anti-bot shell '
        '(no id="cs", no universal data)', () async {
      server.serveAntiBotShell = true;
      await expectLater(
        buildExtractor().extract(Uri.parse('https://www.tiktok.com/@hankgreen1/video/7047596209028074758')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'RATE_LIMITED')),
      );
    });

    test('RATE_LIMITED when the *second* response (after a solved challenge) is the anti-bot shell', () async {
      // First hit gets the normal challenge and solves it; the server then
      // switches to the shell for the retry, modeling TikTok escalating
      // mid-session rather than from the very first request.
      var hits = 0;
      final extractor = TikTokExtractor(
        requestUrlBuilder: (url) {
          hits += 1;
          if (hits > 1) server.serveAntiBotShell = true;
          return server.baseUri.replace(path: url.path, query: url.query);
        },
      );
      await expectLater(
        extractor.extract(Uri.parse('https://www.tiktok.com/@hankgreen1/video/7047596209028074758')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'RATE_LIMITED')),
      );
    });
  });

  group('TikTokExtractor shortlink resolution', () {
    test('follows a relative redirect to the canonical /@user/video/id path', () async {
      final info = await buildExtractor().extract(Uri.parse('https://vm.tiktok.com/short-link'));
      expect(info.formats, isNotEmpty);
      expect(server.cookieHeadersSeen.length, 3, reason: '1 redirect hop + 1 challenge hop + 1 solved-cookie hop');
    });
  });

  group('TikTokExtractor photo post rejection', () {
    test('a canonical /photo/ URL throws UNSUPPORTED_MEDIA without any network call', () async {
      final extractor = buildExtractor();
      await expectLater(
        extractor.extract(Uri.parse('https://www.tiktok.com/@user/photo/123')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'UNSUPPORTED_MEDIA')),
      );
      expect(server.cookieHeadersSeen, isEmpty, reason: 'photo rejection must happen before any GET');
    });
  });

  group('TikTokExtractor page-status mapping', () {
    test('maps HTTP 404 to NOT_FOUND', () async {
      server.fixedStatusCode = 404;
      await expectLater(
        buildExtractor().extract(Uri.parse('https://www.tiktok.com/@user/video/1')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'NOT_FOUND')),
      );
    });

    test('maps HTTP 429 to RATE_LIMITED', () async {
      server.fixedStatusCode = 429;
      await expectLater(
        buildExtractor().extract(Uri.parse('https://www.tiktok.com/@user/video/1')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'RATE_LIMITED')),
      );
    });

    test('maps HTTP 500 to NETWORK', () async {
      server.fixedStatusCode = 500;
      await expectLater(
        buildExtractor().extract(Uri.parse('https://www.tiktok.com/@user/video/1')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'NETWORK')),
      );
    });
  });

  group('TikTokExtractor.extract() URL validation', () {
    test('throws UNSUPPORTED_URL for a non-TikTok URL', () async {
      await expectLater(
        buildExtractor().extract(Uri.parse('https://evil.example/@user/video/1')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'UNSUPPORTED_URL')),
      );
    });
  });
}
