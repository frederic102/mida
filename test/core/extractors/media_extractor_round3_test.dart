import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/fallback_failure.dart';
import 'package:mida/core/extractors/media_extractor.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/net/retry_policy.dart';

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

const _login = MediaExtractionException('LOGIN_REQUIRED', 'Instagram asks to log in to watch this reel.');
final _platformUrl = Uri.parse('https://platform.example/video/1');
final _pageUrl = Uri.parse('https://news.example/article/1');

Future<MediaInfo> _noMedia(Uri url) async => throw const MediaExtractionException('NO_MEDIA_FOUND', 'nothing on the page');
Future<MediaInfo> _found(Uri url) async => MediaInfo(id: 'ok', title: 'ok', sourceUrl: url, formats: const [_fakeFormat]);
_Extract _throws(Object error) => (url) async => throw error;
/// A failed `as` cast: a real `TypeError`, the shape of a parser bug.
Object _notInfo() => 'not a MediaInfo';
_Extract _typeError() => (url) async => _notInfo() as MediaInfo;

ExtractorRegistry _registry(
  List<String> calls, {
  _Extract? platform,
  bool Function(Uri)? platformHandles,
  _Extract catchAll = _noMedia,
  List<_Extract>? browsers,
  bool loginSessionAvailable = false,
}) {
  final fallbacks = browsers ?? const [_noMedia];
  return ExtractorRegistry(
    [
      _Spy('platform', platformHandles ?? (u) => u.host == 'platform.example', calls, platform ?? _throws(_login)),
      _Spy('catchAll', (u) => true, calls, catchAll),
    ],
    fallbacks: [
      for (var i = 0; i < fallbacks.length; i++) _Spy('browser$i', (u) => true, calls, fallbacks[i]),
    ],
    retryPolicy: RetryPolicy(maxAttempts: 2, sleeper: (_) async {}),
    loginSessionAvailable: loginSessionAvailable,
  );
}

TypeMatcher<MediaExtractionException> _status(String status) =>
    isA<MediaExtractionException>().having((e) => e.status, 'status', status);

void main() {
  group('Vigil N2: unexpected Exceptions and Errors fall through, never escape', () {
    test('a TypeError from the primary platform parser falls through to the catch-all', () async {
      final calls = <String>[];
      final registry = _registry(calls, platform: _typeError(), catchAll: _found);
      expect((await registry.resolveInfo(_platformUrl)).id, 'ok');
      expect(calls, ['platform', 'catchAll']);
    });

    test('a FormatException from the primary falls through; when all fail it is PARSE_ERROR with fixed text', () async {
      final calls = <String>[];
      final registry = _registry(calls, platform: _throws(const FormatException('Unexpected <SECRET> at 3')));
      Object? caught;
      try {
        await registry.resolveInfo(_platformUrl);
      } catch (e) {
        caught = e;
      }
      expect(caught, _status('PARSE_ERROR'));
      expect(caught.toString(), isNot(contains('SECRET')));
      expect(calls, ['platform', 'catchAll', 'browser0']);
    });

    test('a StateError / TypeError from a fallback is folded and the next fallback still runs', () async {
      final calls = <String>[];
      final registry = _registry(calls,
          platform: _throws(const MediaExtractionException('CHALLENGE_FAILED', 'waf')),
          catchAll: _throws(StateError('bad state')),
          browsers: [_typeError(), _found]);
      expect((await registry.resolveInfo(_platformUrl)).id, 'ok');
      expect(calls, ['platform', 'catchAll', 'browser0', 'browser1']);
    });

    test('astra round 3: a catch-all (primary) StateError continues to the browser, whose result wins', () async {
      final calls = <String>[];
      final registry = _registry(calls, catchAll: _throws(StateError('parser bug')), browsers: [_found]);
      expect((await registry.resolveInfo(_pageUrl)).id, 'ok');
      expect(calls, ['catchAll', 'browser0']);
    });

    test('a FormatException from the only fallback ends as the first status, not a crash', () async {
      final registry = _registry(<String>[], browsers: [_throws(const FormatException('x'))]);
      await expectLater(registry.resolveInfo(_pageUrl), throwsA(_status('NO_MEDIA_FOUND')));
    });
  });

  group('Vigil N4: a catch-all NETWORK or policy status ends the chain before any browser launch', () {
    test('platform NETWORK -> catch-all NETWORK -> the browser is never invoked', () async {
      final calls = <String>[];
      final registry = _registry(calls,
          platform: _throws(const MediaExtractionException('NETWORK', 'offline')),
          catchAll: _throws(const SocketException('Failed host lookup')),
          browsers: [_found]);
      await expectLater(registry.resolveInfo(_platformUrl), throwsA(_status('NETWORK')));
      // The platform's NETWORK is retried once; the raw SocketException is not retryable. No browser.
      expect(calls, ['platform', 'platform', 'catchAll']);
    });

    test('Gadfly r3: after a native CHALLENGE_FAILED, even a catch-all DNS failure still tries the browser', () async {
      final calls = <String>[];
      final registry = _registry(calls,
          platform: _throws(const MediaExtractionException('CHALLENGE_FAILED', 'waf')),
          catchAll: _throws(const SocketException('Failed host lookup: cdn.example')),
          browsers: [_found]);
      expect((await registry.resolveInfo(_platformUrl)).id, 'ok');
      expect(calls, ['platform', 'catchAll', 'browser0']);
    });

    test('Vigil r3 M1: native NETWORK + catch-all connection reset (not offline) still tries the browser', () async {
      final calls = <String>[];
      final registry = _registry(calls,
          platform: _throws(const MediaExtractionException('NETWORK', 'reset')),
          catchAll: _throws(const SocketException('Connection reset by peer')),
          browsers: [_found]);
      expect((await registry.resolveInfo(_platformUrl)).id, 'ok');
      expect(calls, ['platform', 'platform', 'catchAll', 'browser0']);
    });

    test('Vigil r3 M1: a Generic-primary TLS HandshakeException goes to the browser, whose result wins', () async {
      final calls = <String>[];
      final registry = _registry(calls, catchAll: _throws(const HandshakeException('WRONG_VERSION_NUMBER')), browsers: [_found]);
      expect((await registry.resolveInfo(_pageUrl)).id, 'ok');
      expect(calls, ['catchAll', 'browser0']);
    });

    test('Vigil r3 M1: a Generic-primary DNS failure (HostPolicy kind) is terminal, no browser', () async {
      final calls = <String>[];
      final registry = _registry(calls, catchAll: _throws(const OfflineNetworkException('no dns')), browsers: [_found]);
      await expectLater(registry.resolveInfo(_pageUrl), throwsA(_status('NETWORK')));
      expect(calls, ['catchAll', 'catchAll']); // NETWORK is retried once, never a browser
    });

    test('Vigil r3 M2: FileSystemException is EXTRACTION_FAILED, not NETWORK; DNS SocketException is offline', () {
      expect(asFallbackFailure(const FileSystemException('locked', r'C:\x')).status, 'EXTRACTION_FAILED');
      expect(asFallbackFailure(const SocketException('Failed host lookup: a.example')), isA<OfflineNetworkException>());
      expect(asFallbackFailure(const SocketException('Connection reset by peer')), isNot(isA<OfflineNetworkException>()));
      expect(asFallbackFailure(const HandshakeException('x')).status, 'NETWORK');
    });

    test('a catch-all DRM_PROTECTED after a platform fall-through also stops (and surfaces)', () async {
      final calls = <String>[];
      final registry = _registry(calls,
          platform: _throws(const MediaExtractionException('CHALLENGE_FAILED', 'waf')),
          catchAll: _throws(const MediaExtractionException('DRM_PROTECTED', 'Widevine')),
          browsers: [_found]);
      await expectLater(registry.resolveInfo(_platformUrl), throwsA(_status('DRM_PROTECTED')));
      expect(calls, ['platform', 'catchAll']);
    });

    test('a plain catch-all NO_MEDIA_FOUND still goes on to the browser (no over-stopping)', () async {
      final calls = <String>[];
      final registry = _registry(calls,
          platform: _throws(const MediaExtractionException('CHALLENGE_FAILED', 'waf')), browsers: [_found]);
      expect((await registry.resolveInfo(_platformUrl)).id, 'ok');
      expect(calls, ['platform', 'catchAll', 'browser0']);
    });

    test('with a login session, a catch-all LOGIN_REQUIRED does not stop the browser', () async {
      final calls = <String>[];
      final registry = _registry(calls,
          catchAll: _throws(const MediaExtractionException('LOGIN_REQUIRED', 'generic saw a wall')),
          browsers: [_found],
          loginSessionAvailable: true);
      expect((await registry.resolveInfo(_platformUrl)).id, 'ok');
      expect(calls, ['platform', 'catchAll', 'browser0']);
    });
  });

  group('Gadfly C7: on a login wall with a session, a browser bot block outranks LOGIN_REQUIRED', () {
    const blocked = MediaExtractionException('HEADLESS_BLOCKED', 'the page looks like a bot-check');
    const botCheck = MediaExtractionException('BOT_CHECK_REQUIRED', 'captcha page');

    test('order 1: block first, then a plain NO_MEDIA_FOUND -> HEADLESS_BLOCKED, login reason folded', () async {
      final registry = _registry(<String>[], browsers: [_throws(blocked), _noMedia], loginSessionAvailable: true);
      await expectLater(
        registry.resolveInfo(_platformUrl),
        throwsA(_status('HEADLESS_BLOCKED').having(
            (e) => e.reason, 'reason', allOf(contains('log in to watch'), contains('bot-check')))),
      );
    });

    test('order 2: NO_MEDIA_FOUND first, then BOT_CHECK_REQUIRED -> BOT_CHECK_REQUIRED', () async {
      final registry = _registry(<String>[], browsers: [_noMedia, _throws(botCheck)], loginSessionAvailable: true);
      await expectLater(
        registry.resolveInfo(_platformUrl),
        throwsA(_status('BOT_CHECK_REQUIRED').having((e) => e.reason, 'reason', contains('log in to watch'))),
      );
    });

    test('a browser NO_MEDIA_FOUND keeps the original LOGIN_REQUIRED object', () async {
      final registry = _registry(<String>[], browsers: [_noMedia], loginSessionAvailable: true);
      await expectLater(registry.resolveInfo(_platformUrl), throwsA(same(_login)));
    });

    test('a catch-all HEADLESS_BLOCKED (not a browser attempt) does not replace LOGIN_REQUIRED', () async {
      final registry = _registry(<String>[], catchAll: _throws(blocked), loginSessionAvailable: true);
      await expectLater(registry.resolveInfo(_platformUrl), throwsA(same(_login)));
    });
  });

  group('Bulwark round 2: a throwing canHandle counts as "does not handle"', () {
    test('find skips it and resolution continues with the next extractor', () async {
      final calls = <String>[];
      final registry = _registry(calls, platformHandles: (u) => throw StateError('matcher bug'), catchAll: _found);
      expect(registry.find(_platformUrl), isNotNull);
      expect((await registry.resolveInfo(_platformUrl)).id, 'ok');
      expect(calls, ['catchAll']);
    });
  });
}
