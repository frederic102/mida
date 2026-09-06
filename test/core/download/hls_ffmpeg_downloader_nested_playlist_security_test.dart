import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/download/hls_ffmpeg_downloader.dart';
import 'package:mida/core/extractors/media_models.dart';

/// Phase 6 B-R1: a `HostPolicy` rejection raised while fetching a
/// variant/rendition playlist must propagate as a refusal of the whole
/// manifest. Before this round the scanner wrapped that fetch in a bare
/// `catch (_) { continue; }`, so a master pointing at a private-host
/// variant was treated as an availability hiccup and the download went
/// ahead - handing ffmpeg a manifest whose nested references nothing had
/// checked.
///
/// Round 3 B-R3-1 closed the last hole in that: a transport failure on a
/// variant used to be skipped as "an availability hiccup", but a playlist
/// nobody could READ is a playlist nobody CHECKED, and ffmpeg opens it
/// regardless. The last test here pins that inversion.
Future<List<InternetAddress>> _fakePublicResolver(String host) async => [InternetAddress('93.184.216.34')];

const _mpegurl = 'application/vnd.apple.mpegurl';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('mida_hls_nested_');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('guard can fail: a master referencing https://127.0.0.1/private.m3u8 as a variant is refused end to end',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.headers.contentType = ContentType.parse(_mpegurl);
      request.response.write(
        '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000000\nhttps://127.0.0.1/private.m3u8\n',
      );
      await request.response.close();
    });

    final downloader = HlsFfmpegDownloader(
      allowPrivateHosts: true,
      resolveHost: _fakePublicResolver,
      ffmpegPathResolver: () async => throw StateError('ffmpeg must never be reached for a refused manifest'),
    );
    await expectLater(
      downloader.downloadVerified(
        url: 'http://127.0.0.1:${server.port}/master.m3u8',
        outputPath: '${tempDir.path}/out.mp4',
      ),
      throwsA(isA<MediaExtractionException>()
          .having((e) => e.status, 'status', 'UNSUPPORTED_URL')
          .having((e) => e.reason, 'reason', contains('127.0.0.1'))),
    );
    // Guard can fail (see report): the `allowPrivateHosts` exemption is
    // now scoped to the root manifest's own ORIGIN (scheme + host +
    // port). Widening `_ReferenceGate.isExemptOrigin` back to a bare host
    // comparison (`allowPrivateHosts && uri.host == root.host`, which is
    // what `HostPolicy.guardedRequest`'s own hop-0 exemption does on its
    // own) made this test fail: `https://127.0.0.1/private.m3u8` became
    // exempt, its fetch failed as a plain connection error, and the old
    // "skip an unfetchable variant" path let the whole scan pass.
  });

  test('guard can fail: a variant that redirects to a private host is refused, not swallowed as '
      '"could not read that one"', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      if (request.uri.path == '/variant.m3u8') {
        // HostPolicy.guardedRequest re-checks every redirect hop; the
        // exemption covers hop 0 only, so this throws INSIDE the fetch -
        // exactly the throw the old catch-all swallowed.
        request.response.statusCode = 302;
        request.response.headers.set('location', 'http://127.0.0.1:1/private.m3u8');
        await request.response.close();
        return;
      }
      request.response.headers.contentType = ContentType.parse(_mpegurl);
      request.response.write(
        '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000000\nhttp://127.0.0.1:${server.port}/variant.m3u8\n',
      );
      await request.response.close();
    });

    final downloader = HlsFfmpegDownloader(
      allowPrivateHosts: true,
      resolveHost: _fakePublicResolver,
      ffmpegPathResolver: () async => throw StateError('ffmpeg must never be reached for a refused manifest'),
    );
    await expectLater(
      downloader.downloadVerified(
        url: 'http://127.0.0.1:${server.port}/master.m3u8',
        outputPath: '${tempDir.path}/out.mp4',
      ),
      throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'UNSUPPORTED_URL')),
    );
    // Guard can fail (see report): replacing the scanner's
    // `on MediaExtractionException { rethrow; } on IOException { skip }`
    // pair with the pre-phase-6 `catch (_) { continue; }` made this test
    // fail - the redirect refusal was swallowed, the scan "passed", and
    // the run reached the StateError from ffmpegPathResolver instead.
  });

  test('B-R3-1: a variant this scanner cannot read (transport failure, host already validated) now refuses '
      'the whole manifest instead of being skipped past', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      switch (request.uri.path) {
        case '/broken.m3u8':
          // A truncated response: an IOException, not a security signal.
          final socket = await request.response.detachSocket(writeHeaders: false);
          socket.destroy();
        case '/good.m3u8':
          request.response.headers.contentType = ContentType.parse(_mpegurl);
          request.response.write('#EXTM3U\n#EXTINF:10,\nhttps://cdn.example.invalid/seg.ts\n');
          await request.response.close();
        default:
          request.response.headers.contentType = ContentType.parse(_mpegurl);
          request.response.write(
            '#EXTM3U\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=1\nhttp://127.0.0.1:${server.port}/broken.m3u8\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=2\nhttp://127.0.0.1:${server.port}/good.m3u8\n',
          );
          await request.response.close();
      }
    });

    final downloader = HlsFfmpegDownloader(
      allowPrivateHosts: true,
      resolveHost: _fakePublicResolver,
      ffmpegPathResolver: () async => throw StateError('ffmpeg must never be reached for a refused manifest'),
    );
    await expectLater(
      downloader.downloadVerified(
        url: 'http://127.0.0.1:${server.port}/master.m3u8',
        outputPath: '${tempDir.path}/out.mp4',
      ),
      throwsA(isA<MediaExtractionException>()
          .having((e) => e.status, 'status', 'PARSE_ERROR')
          .having((e) => e.reason, 'reason', contains('could not be read'))),
    );
    // The good variant existing alongside the broken one is the point:
    // a scan that "mostly worked" is still a scan that left one
    // playlist's references unchecked.
  });
}
