import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/download/media_merger.dart';
import 'package:mida/core/download/stream_downloader.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/features/download/services/all_format_candidates_failed_exception.dart';
import 'package:mida/features/download/services/download_service_io.dart';
import 'package:mida/features/download/services/media_download_pipeline.dart';

/// A merger whose `run` always throws, standing in for "ffmpeg is missing"
/// (ProcessException) or "ffmpeg exited non-zero" (MediaMergeException)
/// without needing a real ffmpeg binary in this test.
class _ThrowingMerger extends MediaMerger {
  @override
  Future<void> run(List<String> args) async {
    throw const MediaMergeException('simulated ffmpeg failure');
  }
}

Future<HttpServer> _startByteServer(
  Uint8List content, {
  void Function(HttpHeaders headers)? onRequest,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    onRequest?.call(request.headers);
    final range = request.headers.value('range');
    var start = 0;
    var end = content.length - 1;
    if (range != null) {
      final match = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(range);
      if (match != null) {
        start = int.parse(match.group(1)!);
        end = int.parse(match.group(2)!);
      }
    }
    request.response.statusCode = range == null ? 200 : 206;
    if (range != null) {
      // `StreamDownloader` now requires a 206 response's own Content-Range
      // to confirm it actually starts where it was asked to - a fixture
      // that omitted it (as this one used to) is exactly what that check
      // exists to catch, not something worth exempting the test server
      // from.
      request.response.headers.set('Content-Range', 'bytes $start-$end/${content.length}');
    }
    request.response.add(content.sublist(start, (end + 1).clamp(0, content.length)));
    await request.response.close();
  });
  return server;
}

// `.mida_tmp_` inside the OUTPUT dir (not `mida_yt_`/`mida_dl_` in system
// temp): a later pass moved `MediaDownloadPipeline`'s temp files into the
// output directory itself (so the final move is same-volume). Keeping
// this pattern/location in sync matters - a stale one would never match
// anything and this leftover-cleanup guard would pass vacuously
// regardless of whether temp files actually leaked.
List<FileSystemEntity> _leftoversFor(Directory dir, String videoId) {
  return dir
      .listSync()
      .where((e) => e.path.contains('.mida_tmp_${videoId}_'))
      .toList();
}

/// With a single-format `MediaInfo` (as every test below uses), there is
/// only one ranked candidate, so `MediaDownloadPipeline` exhausts its one
/// attempt and wraps the underlying failure in
/// `AllFormatCandidatesFailedException` rather than letting it surface
/// raw - this matcher unwraps it back down to the real cause.
Matcher throwsWrapping(Object causeMatcher) {
  return throwsA(isA<AllFormatCandidatesFailedException>().having((e) => e.lastError, 'lastError', causeMatcher));
}

/// Every test here downloads from a local loopback fixture server, so the
/// default (production-safe) `StreamDownloader(allowPrivateHosts: false)`
/// would refuse every request; this factory is the test-only opt-in.
MediaDownloadPipeline _pipelineWithLoopbackAllowed({required MediaMerger merger}) {
  return MediaDownloadPipeline(
    merger: merger,
    downloaderFactory: () => StreamDownloader(allowPrivateHosts: true),
  );
}

void main() {
  late Uint8List content;
  late HttpServer server;
  late Directory outDir;

  setUp(() async {
    content = Uint8List.fromList(List.generate(2000, (i) => i % 256));
    server = await _startByteServer(content);
    outDir = await Directory.systemTemp.createTemp('mida_pipeline_out_');
  });

  tearDown(() async {
    await server.close(force: true);
    await outDir.delete(recursive: true);
  });

  MediaFormat videoFormat(String id) => MediaFormat(
        id: id,
        url: 'http://127.0.0.1:${server.port}/$id',
        container: 'mp4',
        videoCodec: 'avc1.640028',
        height: 1080,
        contentLength: content.length,
        bitrate: 1000,
        hasVideo: true,
        hasAudio: false,
      );

  MediaFormat audioFormat(String id) => MediaFormat(
        id: id,
        url: 'http://127.0.0.1:${server.port}/$id',
        container: 'mp4',
        audioCodec: 'mp4a.40.2',
        contentLength: content.length,
        bitrate: 128000,
        hasVideo: false,
        hasAudio: true,
      );

  test('a merger that throws during the adaptive-pair merge still cleans up both temps', () async {
    const videoId = 'cleanup_adaptive';
    final info = MediaInfo(
      id: videoId,
      title: 'cleanup test adaptive',
      sourceUrl: Uri.parse('https://example.invalid'),
      formats: [videoFormat('v1'), audioFormat('a1')],
    );
    final pipeline = _pipelineWithLoopbackAllowed(merger: _ThrowingMerger());

    await expectLater(
      pipeline.download(
        info: info,
        type: DownloadType.video,
        options: const DownloadOptions(videoQuality: VideoQuality.p1080, videoFormat: VideoFormat.mp4),
        outputDir: outDir.path,
      ),
      throwsWrapping(isA<MediaMergeException>()),
    );

    final leftovers = _leftoversFor(outDir, videoId);
    expect(leftovers, isEmpty, reason: 'temp files leaked: $leftovers');
  });

  test('a merger that throws during audio-only conversion still cleans up the temp', () async {
    const videoId = 'cleanup_audio';
    final info = MediaInfo(
      id: videoId,
      title: 'cleanup test audio',
      sourceUrl: Uri.parse('https://example.invalid'),
      formats: [audioFormat('a1')],
    );
    final pipeline = _pipelineWithLoopbackAllowed(merger: _ThrowingMerger());

    await expectLater(
      pipeline.download(
        info: info,
        type: DownloadType.audio,
        options: const DownloadOptions(audioFormat: AudioFormat.mp3),
        outputDir: outDir.path,
      ),
      throwsWrapping(isA<MediaMergeException>()),
    );

    final leftovers = _leftoversFor(outDir, videoId);
    expect(leftovers, isEmpty, reason: 'temp files leaked: $leftovers');
  });

  test('info.requestHeaders reach the server for both the video and audio format downloads', () async {
    final capturedUserAgents = <String?>[];
    await server.close(force: true);
    server = await _startByteServer(
      content,
      onRequest: (headers) => capturedUserAgents.add(headers.value('user-agent')),
    );

    const videoId = 'headers_reach_server';
    final info = MediaInfo(
      id: videoId,
      title: 'headers test',
      sourceUrl: Uri.parse('https://example.invalid'),
      formats: [videoFormat('v1'), audioFormat('a1')],
      requestHeaders: const {'User-Agent': 'mida-pipeline-test-agent'},
    );
    final pipeline = _pipelineWithLoopbackAllowed(merger: _ThrowingMerger());

    await expectLater(
      pipeline.download(
        info: info,
        type: DownloadType.video,
        options: const DownloadOptions(videoQuality: VideoQuality.p1080, videoFormat: VideoFormat.mp4),
        outputDir: outDir.path,
      ),
      throwsWrapping(isA<MediaMergeException>()),
    );

    expect(capturedUserAgents, isNotEmpty);
    expect(capturedUserAgents.every((ua) => ua == 'mida-pipeline-test-agent'), isTrue,
        reason: 'expected every request (video + audio) to carry the MediaInfo.requestHeaders User-Agent');
  });

  test('no downloadable formats throws NoDownloadableFormatsException before anything is written', () async {
    final info = MediaInfo(
      id: 'no_formats',
      title: 'empty',
      sourceUrl: Uri.parse('https://example.invalid'),
      formats: const [],
    );
    final pipeline = MediaDownloadPipeline(merger: _ThrowingMerger());

    await expectLater(
      pipeline.download(
        info: info,
        type: DownloadType.video,
        options: const DownloadOptions(),
        outputDir: outDir.path,
      ),
      throwsA(isA<NoDownloadableFormatsException>()),
    );
  });
}
