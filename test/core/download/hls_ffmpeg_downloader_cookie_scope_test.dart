import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/download/hls_ffmpeg_downloader.dart';
import 'package:mida/core/extractors/media_models.dart';

/// `cdn.example.com` never actually resolves (no A record beyond the
/// apex `example.com` itself) - a fake resolver keeps this hermetic and
/// independent of the manifest scanner's fail-closed DNS-answer check.
Future<List<InternetAddress>> _fakePublicResolver(String host) async => [InternetAddress('93.184.216.34')];

/// Records the args `downloadVerified` would have handed to ffmpeg instead
/// of ever spawning a real process - lets a test inspect the `-headers`
/// blob `_withScopedCookie` built without needing a real ffmpeg binary.
class _ArgsCapturingDownloader extends HlsFfmpegDownloader {
  List<String>? capturedArgs;

  _ArgsCapturingDownloader({super.httpClientFactory}) : super(resolveHost: _fakePublicResolver);

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

void main() {
  group('HlsFfmpegDownloader cookie domain scoping (Item D - partial, whole-invocation)', () {
    test('the manifest URL\'s own host gets its cookie; an unrelated domain\'s cookie is left out', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.headers.contentType = ContentType('application', 'vnd.apple.mpegurl');
        request.response.write('#EXTM3U\n#EXTINF:10,\nhttps://93.184.216.34/seg1.ts\n');
        await request.response.close();
      });

      HttpClient pinnedToFixture() {
        final client = HttpClient();
        client.connectionFactory = (uri, proxyHost, proxyPort) =>
            Socket.startConnect(InternetAddress.loopbackIPv4, server.port);
        return client;
      }

      final downloader = _ArgsCapturingDownloader(httpClientFactory: pinnedToFixture);
      await downloader.downloadVerified(
        url: 'https://93.184.216.34/media.m3u8',
        outputPath: 'C:/out/video.mp4',
        cookiesByDomain: const {
          '93.184.216.34': [CookieEntry(domain: '93.184.216.34', path: '/', secure: false, name: 'sid', value: 'xyz')],
          'unrelated.example.com': [
            CookieEntry(domain: 'unrelated.example.com', path: '/', secure: false, name: 'other', value: 'nope'),
          ],
        },
      );

      final args = downloader.capturedArgs;
      expect(args, isNotNull);
      final headersIndex = args!.indexOf('-headers');
      expect(headersIndex, greaterThanOrEqualTo(0));
      final headerBlob = args[headersIndex + 1];

      expect(headerBlob, contains('Cookie: sid=xyz'));
      // Guard can fail: proves the manifest-host scoping, not "any
      // cookiesByDomain present", decides what ends up in ffmpeg's own
      // global -headers blob.
      expect(headerBlob, isNot(contains('other=nope')));
    });

    test('cookiesByDomain omitted entirely leaves headers exactly as passed in (no behavior change)', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.headers.contentType = ContentType('application', 'vnd.apple.mpegurl');
        request.response.write('#EXTM3U\n#EXTINF:10,\nhttps://93.184.216.34/seg1.ts\n');
        await request.response.close();
      });

      HttpClient pinnedToFixture() {
        final client = HttpClient();
        client.connectionFactory = (uri, proxyHost, proxyPort) =>
            Socket.startConnect(InternetAddress.loopbackIPv4, server.port);
        return client;
      }

      final downloader = _ArgsCapturingDownloader(httpClientFactory: pinnedToFixture);
      await downloader.downloadVerified(
        url: 'https://93.184.216.34/media.m3u8',
        outputPath: 'C:/out/video.mp4',
        headers: const {'Cookie': 'legacy=1'},
      );

      final args = downloader.capturedArgs!;
      final headerBlob = args[args.indexOf('-headers') + 1];
      expect(headerBlob, contains('Cookie: legacy=1'));
    });
  });
}
