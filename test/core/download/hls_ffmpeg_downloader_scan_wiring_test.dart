import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/download/hls_ffmpeg_downloader.dart';
import 'package:mida/core/download/media_merger.dart';

/// Phase 6 B-R4 and B-R6, both about what `downloadVerified` does with
/// the scan it already performed:
///  - B-R4: when the caller does not say whether the segments are
///    MPEG-TS, the manifest scan (which just read those media playlists
///    anyway) decides, so `-bsf:a aac_adtstoasc` is not applied to
///    fMP4/CMAF audio it would make ffmpeg fail on. Nothing new is
///    exposed to callers.
///  - B-R6: the `processTimeout` contract is forwarded to `run`, so a
///    hung ffmpeg is killed at the deadline rather than blocking the
///    download loop forever.
Future<List<InternetAddress>> _fakePublicResolver(String host) async => [InternetAddress('93.184.216.34')];

const _mpegurl = 'application/vnd.apple.mpegurl';

/// Captures the args `downloadVerified` built instead of spawning ffmpeg.
class _ArgsCapturingDownloader extends HlsFfmpegDownloader {
  List<String>? capturedArgs;

  _ArgsCapturingDownloader() : super(allowPrivateHosts: true, resolveHost: _fakePublicResolver);

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

Future<HttpServer> _serve(String body) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  server.listen((request) async {
    request.response.headers.contentType = ContentType.parse(_mpegurl);
    request.response.write(body);
    await request.response.close();
  });
  return server;
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('mida_hls_scan_wiring_');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  group('B-R4: segmentsAreTransportStream defaults to what the manifest scan saw', () {
    Future<List<String>> argsFor(String manifestBody, {bool? segmentsAreTransportStream}) async {
      final server = await _serve(manifestBody);
      final downloader = _ArgsCapturingDownloader();
      await downloader.downloadVerified(
        url: 'http://127.0.0.1:${server.port}/media.m3u8',
        outputPath: '${tempDir.path}/out.mp4',
        segmentsAreTransportStream: segmentsAreTransportStream,
      );
      return downloader.capturedArgs!;
    }

    test('guard can fail: an fMP4 manifest (#EXT-X-MAP + .m4s) drops aac_adtstoasc without the caller '
        'having to know', () async {
      final args = await argsFor(
        '#EXTM3U\n#EXT-X-MAP:URI="https://cdn.example.invalid/init.mp4"\n'
        '#EXTINF:10,\nhttps://cdn.example.invalid/seg1.m4s\n',
      );
      expect(args, containsAllInOrder(['-c', 'copy']));
      expect(args, isNot(contains('-bsf:a')));
      // Guard can fail (see report): reverting `downloadVerified` to pass
      // the caller's raw `segmentsAreTransportStream` (dropping
      // `?? scan.segmentsAreTransportStream`) made this test fail -
      // the args came back with `-bsf:a aac_adtstoasc` applied to
      // fMP4-framed audio, which is the ffmpeg hard failure ("Error
      // parsing ADTS frame header") this item exists to stop.
    });

    test('a .ts manifest still gets aac_adtstoasc', () async {
      final args = await argsFor('#EXTM3U\n#EXTINF:10,\nhttps://cdn.example.invalid/seg1.ts\n');
      expect(args, containsAllInOrder(['-c', 'copy', '-bsf:a', 'aac_adtstoasc']));
    });

    test('a manifest with no framing signal keeps the pre-phase-6 default (bsf applied)', () async {
      final args = await argsFor('#EXTM3U\n#EXTINF:10,\nhttps://cdn.example.invalid/seg1?token=abc\n');
      expect(args, containsAllInOrder(['-c', 'copy', '-bsf:a', 'aac_adtstoasc']));
    });

    test('an explicit caller value still wins over the scan (true on an fMP4 manifest)', () async {
      final args = await argsFor(
        '#EXTM3U\n#EXT-X-MAP:URI="https://cdn.example.invalid/init.mp4"\n'
        '#EXTINF:10,\nhttps://cdn.example.invalid/seg1.m4s\n',
        segmentsAreTransportStream: true,
      );
      expect(args, containsAllInOrder(['-bsf:a', 'aac_adtstoasc']));
    });

    test('an explicit caller value still wins over the scan (false on a .ts manifest)', () async {
      final args = await argsFor(
        '#EXTM3U\n#EXTINF:10,\nhttps://cdn.example.invalid/seg1.ts\n',
        segmentsAreTransportStream: false,
      );
      expect(args, isNot(contains('-bsf:a')));
    });
  });

  group('B-R3-7: downloadVerified returns the duration the manifest declared', () {
    Future<Duration?> declaredFor(String manifestBody) async {
      final server = await _serve(manifestBody);
      final downloader = _ArgsCapturingDownloader();
      return downloader.downloadVerified(
        url: 'http://127.0.0.1:${server.port}/media.m3u8',
        outputPath: '${tempDir.path}/out.mp4',
      );
    }

    test('an HLS media playlist returns its #EXTINF sum', () async {
      expect(
        await declaredFor('#EXTM3U\n#EXTINF:9,\nhttps://cdn.example.invalid/a.ts\n'
            '#EXTINF:11,\nhttps://cdn.example.invalid/b.ts\n'),
        const Duration(seconds: 20),
      );
    });

    test('a DASH MPD returns its mediaPresentationDuration', () async {
      expect(
        await declaredFor('<?xml version="1.0"?><MPD mediaPresentationDuration="PT2M30S"><Period>'
            '<AdaptationSet><Representation><BaseURL>https://cdn.example.invalid/s.mp4</BaseURL>'
            '</Representation></AdaptationSet></Period></MPD>'),
        const Duration(minutes: 2, seconds: 30),
      );
    });

    test('a manifest that declares nothing returns null, never a guess', () async {
      expect(await declaredFor('#EXTM3U\n#EXT-X-TARGETDURATION:10\nhttps://cdn.example.invalid/a.ts\n'), isNull);
    });
  });

  group('B-R6: downloadVerified keeps the processTimeout contract', () {
    test('guard can fail: a hung ffmpeg is killed at the deadline instead of blocking the download', () async {
      final server = await _serve('#EXTM3U\n#EXTINF:10,\nhttps://cdn.example.invalid/seg1.ts\n');
      final scriptPath = '${tempDir.path}/fake_ffmpeg_hang.bat';
      // Never exits on its own within any duration this test would wait.
      await File(scriptPath).writeAsString('@echo off\r\nping -n 120 127.0.0.1 >nul\r\n');

      final downloader = HlsFfmpegDownloader(
        allowPrivateHosts: true,
        resolveHost: _fakePublicResolver,
        ffmpegPathResolver: () async => scriptPath,
      );
      await expectLater(
        downloader.downloadVerified(
          url: 'http://127.0.0.1:${server.port}/media.m3u8',
          outputPath: '${tempDir.path}/out.mp4',
          processTimeout: const Duration(milliseconds: 300),
        ),
        throwsA(isA<MediaMergeException>().having((e) => e.message, 'message', contains('killed'))),
      );
      // Guard can fail (see report): dropping `processTimeout` from
      // `downloadVerified`'s call to `run` (the contract this item keeps)
      // made this test hang for the ping's full ~120s instead of failing
      // fast with the expected MediaMergeException.
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}
