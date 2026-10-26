import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/extractor_registry_builder.dart';
import 'package:mida/core/extractors/generic/embeds/embed_delegation.dart';
import 'package:mida/core/extractors/media_extractor.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/net/retry_policy.dart';
import 'package:mida/core/services/cdp_client.dart';

const _fakeFormat = MediaFormat(
  id: 'f',
  url: 'https://example.invalid/video.mp4',
  container: 'mp4',
  hasVideo: true,
  hasAudio: true,
);

typedef _Extract = Future<MediaInfo> Function(Uri url);

class _Spy implements MediaExtractor {
  final String label;
  final bool Function(Uri) handles;
  final List<String> calls;
  final _Extract run;
  const _Spy(this.label, this.handles, this.calls, this.run);

  @override
  bool canHandle(Uri url) => handles(url);

  @override
  Future<MediaInfo> extract(Uri url) {
    calls.add(label);
    return run(url);
  }
}

const _secret = 'SIGSECRET123';
const _login = MediaExtractionException('LOGIN_REQUIRED', 'Facebook asks to log in to watch this video.');
final _platformUrl = Uri.parse('https://platform.example/video/1');
final _pageUrl = Uri.parse('https://news.example/article/1');

Future<MediaInfo> _noMedia(Uri url) async => throw const MediaExtractionException('NO_MEDIA_FOUND', 'nothing on the page');
Future<MediaInfo> _found(Uri url) async => MediaInfo(id: 'ok', title: 'ok', sourceUrl: url, formats: const [_fakeFormat]);
_Extract _throws(Object error) => (url) async => throw error;

/// platform (only platform.example) -> [youtube] -> catch-all -> one browser fallback.
ExtractorRegistry _registry(
  List<String> calls, {
  _Extract? platform,
  _Extract catchAll = _noMedia,
  _Extract browser = _noMedia,
  _Extract? youtube,
  bool loginSessionAvailable = false,
}) {
  return ExtractorRegistry(
    [
      _Spy('platform', (u) => u.host == 'platform.example', calls, platform ?? _throws(_login)),
      if (youtube != null) _Spy('youtube', (u) => u.host == 'www.youtube.com', calls, youtube),
      _Spy('catchAll', (u) => true, calls, catchAll),
    ],
    fallbacks: [_Spy('browser', (u) => true, calls, browser)],
    retryPolicy: RetryPolicy(maxAttempts: 2, sleeper: (_) async {}),
    loginSessionAvailable: loginSessionAvailable,
  );
}

TypeMatcher<MediaExtractionException> _status(String status) => isA<MediaExtractionException>().having((e) => e.status, 'status', status);

void main() {
  group('H1: a fallback policy status surfaces from the final fold', () {
    test('generic NO_MEDIA_FOUND + browser HEADLESS_BLOCKED -> HEADLESS_BLOCKED, both reasons kept', () async {
      final calls = <String>[];
      final registry = _registry(calls,
          browser: _throws(const MediaExtractionException('HEADLESS_BLOCKED', 'looks like a bot-check')));
      await expectLater(
        registry.resolveInfo(_pageUrl),
        throwsA(_status('HEADLESS_BLOCKED')
            .having((e) => e.reason, 'reason', allOf(contains('nothing on the page'), contains('bot-check')))),
      );
      expect(calls, ['catchAll', 'browser']);
    });

    for (final status in const [
      'HEADLESS_BLOCKED',
      'BOT_CHECK_REQUIRED',
      'LOGIN_REQUIRED',
      'DRM_PROTECTED',
      'PRIVATE',
      'AGE_VERIFICATION_REQUIRED',
      'CONTENT_CHECK_REQUIRED',
      'RATE_LIMITED',
    ]) {
      test('$status from the browser fallback wins over the platform CHALLENGE_FAILED', () async {
        final registry = _registry(<String>[],
            platform: _throws(const MediaExtractionException('CHALLENGE_FAILED', 'waf')),
            browser: _throws(MediaExtractionException(status, 'browser said $status')));
        await expectLater(registry.resolveInfo(_platformUrl), throwsA(_status(status)));
      });
    }

    test('an ordinary fallback NO_MEDIA_FOUND keeps the first status (no over-surfacing)', () async {
      final registry = _registry(<String>[], platform: _throws(const MediaExtractionException('PARSE_ERROR', 'bad json')));
      await expectLater(registry.resolveInfo(_platformUrl), throwsA(_status('PARSE_ERROR')));
    });

    test('a policy status from the catch-all is not lost behind a later plain NO_MEDIA_FOUND', () async {
      final registry = _registry(<String>[],
          platform: _throws(const MediaExtractionException('CHALLENGE_FAILED', 'waf')),
          catchAll: _throws(const MediaExtractionException('DRM_PROTECTED', 'Widevine')));
      await expectLater(
        registry.resolveInfo(_platformUrl),
        throwsA(_status('DRM_PROTECTED').having((e) => e.reason, 'reason', contains('Widevine'))),
      );
    });
  });

  group('H2: non-extraction exceptions from fallbacks are folded, never escape', () {
    final raw = <String, Exception>{
      'SocketException': const SocketException('connect failed https://cdn.example/v.mp4?sig=$_secret'),
      'TimeoutException': TimeoutException('timed out https://cdn.example/?sig=$_secret'),
      'HttpException': const HttpException('bad https://cdn.example/?sig=$_secret'),
      'ProcessException': const ProcessException('chrome.exe', ['--token=$_secret'], 'not found'),
      'CdpCommandException': const CdpCommandException('Network.getCookies', {'cookie': _secret}),
    };
    raw.forEach((name, error) {
      test('$name from the browser fallback becomes the folded failure with a fixed safe message', () async {
        final calls = <String>[];
        final registry = _registry(calls, browser: _throws(error));
        Object? caught;
        try {
          await registry.resolveInfo(_pageUrl);
        } catch (e) {
          caught = e;
        }
        expect(caught, _status('NO_MEDIA_FOUND'));
        expect((caught! as MediaExtractionException).reason, contains('An extractor'));
        expect(caught.toString(), isNot(contains(_secret)));
        expect(calls, ['catchAll', 'browser']);
      });
    });

    // Round 3 (Vigil N4): a catch-all NETWORK now ends the chain (see
    // media_extractor_round3_test.dart), so a parser-style failure is used
    // here to show a raw catch-all exception is folded and the chain goes on.
    test('a catch-all FormatException still lets the browser fallback run and win', () async {
      final calls = <String>[];
      final registry = _registry(calls,
          platform: _throws(const MediaExtractionException('CHALLENGE_FAILED', 'waf')),
          catchAll: _throws(const FormatException('unexpected token')),
          browser: _found);
      expect((await registry.resolveInfo(_platformUrl)).id, 'ok');
      expect(calls, ['platform', 'catchAll', 'browser']);
    });

    test('platform LOGIN_REQUIRED is rethrown as the same object when the fallbacks throw raw exceptions', () async {
      final calls = <String>[];
      final registry = _registry(calls,
          catchAll: _throws(const FormatException('bad page')),
          browser: _throws(const CdpCommandException('Page.navigate', 'boom')),
          loginSessionAvailable: true);
      await expectLater(registry.resolveInfo(_platformUrl), throwsA(same(_login)));
      expect(calls, ['platform', 'catchAll', 'browser']);
    });

    test('a delegated native target throwing SocketException falls back to the browser', () async {
      final calls = <String>[];
      final youtubeUrl = Uri.https('www.youtube.com', '/watch', {'v': 'abc'});
      final registry = _registry(calls,
          catchAll: _throws(EmbedDelegationException(youtubeUrl, platform: 'YouTube')),
          youtube: _throws(const SocketException('reset')),
          browser: _found);
      expect((await registry.resolveInfo(_pageUrl)).id, 'ok');
      expect(calls, ['catchAll', 'youtube', 'browser']);
    });
  });

  group('G2: LOGIN_REQUIRED reaches the browser only with a login session', () {
    test('toggle OFF: catch-all is tried, the browser is never launched, the original is rethrown', () async {
      final calls = <String>[];
      final registry = _registry(calls);
      await expectLater(registry.resolveInfo(_platformUrl), throwsA(same(_login)));
      expect(calls, ['platform', 'catchAll']);
    });

    test('toggle OFF: a catch-all success still wins', () async {
      final calls = <String>[];
      final registry = _registry(calls, catchAll: _found);
      expect((await registry.resolveInfo(_platformUrl)).id, 'ok');
      expect(calls, ['platform', 'catchAll']);
    });

    test('toggle ON: the browser fallback is launched after the catch-all', () async {
      final calls = <String>[];
      final registry = _registry(calls, browser: _found, loginSessionAvailable: true);
      expect((await registry.resolveInfo(_platformUrl)).id, 'ok');
      expect(calls, ['platform', 'catchAll', 'browser']);
    });

    test('toggle OFF does not affect other fall-through statuses', () async {
      final calls = <String>[];
      final registry = _registry(calls,
          platform: _throws(const MediaExtractionException('CHALLENGE_FAILED', 'waf')), browser: _found);
      expect((await registry.resolveInfo(_platformUrl)).id, 'ok');
      expect(calls, ['platform', 'catchAll', 'browser']);
    });

    test('buildExtractorRegistry wires loginSessionAvailable from useBrowserLoginSession', () {
      expect(buildExtractorRegistry().loginSessionAvailable, isFalse);
      expect(buildExtractorRegistry(useBrowserLoginSession: true).loginSessionAvailable, isTrue);
    });
  });

  group('astra round 2: a delegated target failure takes part in the final status', () {
    final youtubeUrl = Uri.https('www.youtube.com', '/watch', {'v': 'abc'});
    _Extract delegate() => _throws(EmbedDelegationException(youtubeUrl, platform: 'YouTube'));

    for (final status in const ['DRM_PROTECTED', 'LOGIN_REQUIRED', 'PRIVATE']) {
      test('Generic delegates, the native target says $status, the browser finds nothing -> $status', () async {
        final calls = <String>[];
        final registry = _registry(calls,
            catchAll: delegate(),
            youtube: _throws(MediaExtractionException(status, 'native said $status')),
            browser: _noMedia);
        await expectLater(
          registry.resolveInfo(_pageUrl),
          throwsA(_status(status).having((e) => e.reason, 'reason', contains('native said $status'))),
        );
        expect(calls, ['catchAll', 'youtube', 'browser']);
      });
    }

    test('after a platform fall-through: delegated DRM_PROTECTED survives a browser NO_MEDIA_FOUND', () async {
      final registry = _registry(<String>[],
          platform: _throws(const MediaExtractionException('CHALLENGE_FAILED', 'waf')),
          catchAll: delegate(),
          youtube: _throws(const MediaExtractionException('DRM_PROTECTED', 'Widevine')),
          browser: _noMedia);
      await expectLater(registry.resolveInfo(_platformUrl), throwsA(_status('DRM_PROTECTED')));
    });

    test('a delegated DRM_PROTECTED does not block a later browser success', () async {
      final calls = <String>[];
      final registry = _registry(calls,
          catchAll: delegate(),
          youtube: _throws(const MediaExtractionException('DRM_PROTECTED', 'Widevine')),
          browser: _found);
      expect((await registry.resolveInfo(_pageUrl)).id, 'ok');
      expect(calls, ['catchAll', 'youtube', 'browser']);
    });

    test('a delegated plain failure (PARSE_ERROR) does not override the first status', () async {
      final registry = _registry(<String>[],
          catchAll: delegate(),
          youtube: _throws(const MediaExtractionException('PARSE_ERROR', 'bad json')),
          browser: _noMedia);
      await expectLater(registry.resolveInfo(_pageUrl), throwsA(_status('NO_MEDIA_FOUND')));
    });
  });
}
