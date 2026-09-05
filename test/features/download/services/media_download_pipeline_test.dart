import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/download/media_merger.dart';
import 'package:mida/core/download/stream_downloader.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/features/download/services/all_format_candidates_failed_exception.dart';
import 'package:mida/features/download/services/download_outcome_verifier.dart';
import 'package:mida/features/download/services/download_service_io.dart';
import 'package:mida/features/download/services/media_download_pipeline.dart';

import 'media_download_pipeline_test_fakes.dart';

/// Protocol-branch behavior (which downloader gets used, container/codec
/// handling). Retry-across-candidates and sanity-check behavior live in
/// `media_download_pipeline_retry_test.dart` (split purely for the
/// 400-line rule; both files share fakes from
/// `media_download_pipeline_test_fakes.dart`).
void main() {
  late Directory outDir;

  setUp(() async {
    outDir = await Directory.systemTemp.createTemp('mida_media_pipeline_out_');
  });

  tearDown(() async {
    if (await outDir.exists()) await outDir.delete(recursive: true);
  });

  // Windows-safe path compare: `Directory.listSync()` joins with the
  // platform separator (backslash), while paths built in these tests (and
  // by `FileUtils.getUniqueFilePath`) use forward slashes - both point at
  // the same file, but as raw strings they would never `==`.
  String normalize(String path) => path.replaceAll('\\', '/');

  List<FileSystemEntity> leftoversExcluding(Set<String> keep) {
    final normalizedKeep = keep.map(normalize).toSet();
    return outDir.listSync().where((e) => !normalizedKeep.contains(normalize(e.path))).toList();
  }

  MediaInfo hlsMuxedInfo(String id, {int height = 720}) => MediaInfo(
        id: id,
        title: 'hls test $id',
        duration: const Duration(seconds: 10),
        sourceUrl: Uri.parse('https://example.invalid'),
        formats: [
          MediaFormat(
            id: 'v1',
            url: 'https://example.invalid/master.m3u8',
            container: 'm3u8',
            protocol: 'hls',
            height: height,
            hasVideo: true,
            hasAudio: true,
          ),
        ],
      );

  test('a muxed hls format is downloaded through HlsFfmpegDownloader, never StreamDownloader', () async {
    final hlsDownloader = RecordingHlsDownloader();
    final pipeline = MediaDownloadPipeline(
      hlsDownloader: hlsDownloader,
      verifier: DownloadOutcomeVerifier(prober: FixedProber({'video', 'audio'})),
    );
    final info = hlsMuxedInfo('muxed_hls');

    final path = await pipeline.download(
      info: info,
      type: DownloadType.video,
      options: const DownloadOptions(videoFormat: VideoFormat.mp4),
      outputDir: outDir.path,
    );

    expect(hlsDownloader.urlsRequested, ['https://example.invalid/master.m3u8']);
    expect(hlsDownloader.totalDurationsRequested.single, const Duration(seconds: 10));
    // The `.part` temp ffmpeg actually wrote to must still end in the
    // real target extension so its own muxer auto-detection sees `.mp4`,
    // not `.part` (regression: caught live against a title containing a
    // dot, e.g. "x36xhzz.m3u8" -> "x36xhzz.m3u8.mp4.part" made ffmpeg's
    // muxer init fail with "Invalid argument").
    expect(hlsDownloader.builtArgs.single.last, endsWith('.part.mp4'));
    expect(path, '${outDir.path}/hls test muxed_hls.mp4');
    expect(leftoversExcluding({path}), isEmpty, reason: 'the .part temp was not cleaned up after a successful move');
  });

  test('guard can fail: a muxed format labeled https whose URL itself ends in .m3u8 is still routed through '
      'HlsFfmpegDownloader (a mislabeled manifest, not routed by protocol alone)', () async {
    final hlsDownloader = RecordingHlsDownloader();
    final pipeline = MediaDownloadPipeline(
      hlsDownloader: hlsDownloader,
      // A StreamDownloader that would fail loudly if ever actually used -
      // proves this candidate never reaches it at all.
      downloaderFactory: () => StreamDownloader(allowPrivateHosts: false),
      verifier: DownloadOutcomeVerifier(prober: FixedProber({'video', 'audio'})),
    );
    final info = MediaInfo(
      id: 'mislabeled_manifest',
      title: 'mislabeled manifest test',
      duration: const Duration(seconds: 10),
      sourceUrl: Uri.parse('https://example.invalid'),
      formats: [
        const MediaFormat(
          id: 'v1',
          url: 'https://example.invalid/master.m3u8?token=abc',
          container: 'mp4',
          protocol: 'https', // mislabeled: the URL itself is a manifest
          height: 720,
          hasVideo: true,
          hasAudio: true,
        ),
      ],
    );

    final path = await pipeline.download(
      info: info,
      type: DownloadType.video,
      options: const DownloadOptions(videoFormat: VideoFormat.mp4),
      outputDir: outDir.path,
    );

    expect(hlsDownloader.urlsRequested, ['https://example.invalid/master.m3u8?token=abc']);
    expect(path, '${outDir.path}/mislabeled manifest test.mp4');
  });

  test('an ffmpeg failure on the hls path surfaces (wrapped) with no leftover .part file (guard: Vigil #1)', () async {
    final hlsDownloader = RecordingHlsDownloader()..shouldThrow = true;
    final pipeline = MediaDownloadPipeline(hlsDownloader: hlsDownloader);

    await expectLater(
      pipeline.download(
        info: hlsMuxedInfo('failing_hls'),
        type: DownloadType.video,
        options: const DownloadOptions(),
        outputDir: outDir.path,
      ),
      throwsA(isA<AllFormatCandidatesFailedException>()
          .having((e) => e.lastError, 'lastError', isA<MediaMergeException>())),
    );

    // The whole point of the .part-then-move discipline (Vigil #1): a
    // failed ffmpeg run must leave nothing behind in the real output
    // directory, `.part` included.
    expect(outDir.listSync(), isEmpty, reason: 'a leftover .part (or other) file was left in the output dir');
  });

  test('an audio-only hls-protocol format is downloaded through HlsFfmpegDownloader with -vn codec args', () async {
    final hlsDownloader = RecordingHlsDownloader();
    final pipeline = MediaDownloadPipeline(hlsDownloader: hlsDownloader);
    final info = MediaInfo(
      id: 'audio_hls',
      title: 'audio hls test',
      sourceUrl: Uri.parse('https://example.invalid'),
      formats: const [
        MediaFormat(
          id: 'a1',
          url: 'https://example.invalid/audio.m3u8',
          container: 'm3u8',
          protocol: 'hls',
          hasVideo: false,
          hasAudio: true,
        ),
      ],
    );

    final path = await pipeline.download(
      info: info,
      type: DownloadType.audio,
      options: const DownloadOptions(audioFormat: AudioFormat.mp3),
      outputDir: outDir.path,
    );

    expect(hlsDownloader.urlsRequested, ['https://example.invalid/audio.m3u8']);
    expect(path, '${outDir.path}/audio hls test.mp3');
    expect(leftoversExcluding({path}), isEmpty);
  });

  group('audio download falls back to a muxed/HLS source when no audio-only stream exists', () {
    late HttpServer server;
    final content = Uint8List.fromList(List.generate(200, (i) => i % 256));

    setUp(() async {
      server = await startByteServer(content);
    });

    tearDown(() async {
      await server.close(force: true);
    });

    MediaInfo muxedHttpsInfo(String id) => MediaInfo(
          id: id,
          title: 'muxed audio fallback $id',
          sourceUrl: Uri.parse('https://example.invalid'),
          formats: [
            MediaFormat(
              id: 'muxed1',
              url: 'http://127.0.0.1:${server.port}/muxed',
              container: 'mp4',
              videoCodec: 'avc1.640028',
              audioCodec: 'mp4a.40.2',
              height: 720,
              contentLength: content.length,
              hasVideo: true,
              hasAudio: true,
            ),
          ],
        );

    test('a muxed https-only format is converted with -vn (guard: this is the fix for X/TikTok/Instagram '
        'audio downloads, which never offer an audio-only stream), and the raw temp is cleaned up', () async {
      final recordingMerger = RecordingMerger();
      final pipeline = MediaDownloadPipeline(
        merger: recordingMerger,
        downloaderFactory: () => StreamDownloader(allowPrivateHosts: true),
      );
      const videoId = 'muxed_audio_fallback_ok';

      final path = await pipeline.download(
        info: muxedHttpsInfo(videoId),
        type: DownloadType.audio,
        options: const DownloadOptions(audioFormat: AudioFormat.mp3),
        outputDir: outDir.path,
      );

      expect(recordingMerger.runCalls, hasLength(1));
      expect(recordingMerger.runCalls.single, contains('-vn'));
      expect(path, '${outDir.path}/muxed audio fallback $videoId.mp3');
      expect(leftoversExcluding({path}), isEmpty, reason: 'the raw muxed download temp was not cleaned up');
    });

    test('a muxed https-only format still cleans up its raw temp when the ffmpeg -vn conversion fails', () async {
      final recordingMerger = RecordingMerger()..shouldThrow = true;
      final pipeline = MediaDownloadPipeline(
        merger: recordingMerger,
        downloaderFactory: () => StreamDownloader(allowPrivateHosts: true),
      );
      const videoId = 'muxed_audio_fallback_fail';

      await expectLater(
        pipeline.download(
          info: muxedHttpsInfo(videoId),
          type: DownloadType.audio,
          options: const DownloadOptions(audioFormat: AudioFormat.mp3),
          outputDir: outDir.path,
        ),
        throwsA(isA<AllFormatCandidatesFailedException>()),
      );

      expect(outDir.listSync(), isEmpty, reason: 'temp files leaked after a failed conversion');
    });

    test('a muxed hls format requested as audio uses the -vn path through HlsFfmpegDownloader, '
        'not a full-stream -c copy', () async {
      final hlsDownloader = RecordingHlsDownloader();
      final pipeline = MediaDownloadPipeline(hlsDownloader: hlsDownloader);

      final path = await pipeline.download(
        info: hlsMuxedInfo('muxed_hls_audio'),
        type: DownloadType.audio,
        options: const DownloadOptions(audioFormat: AudioFormat.mp3),
        outputDir: outDir.path,
      );

      expect(hlsDownloader.urlsRequested, ['https://example.invalid/master.m3u8']);
      expect(hlsDownloader.builtArgs.single, contains('-vn'));
      expect(hlsDownloader.builtArgs.single, isNot(contains('-c')));
      expect(path, '${outDir.path}/hls test muxed_hls_audio.mp3');
    });
  });
}
