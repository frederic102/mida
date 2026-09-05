import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/download/media_merger.dart';
import 'package:mida/core/extractors/extractor_registry_builder.dart';
import 'package:mida/core/extractors/generic/generic_extractor.dart';
import 'package:mida/core/extractors/twitter/twitter_extractor.dart';
import 'package:mida/features/download/services/download_service_io.dart';
import 'package:mida/features/download/services/media_download_pipeline.dart';

/// End-to-end verification of the generalized [MediaDownloadPipeline]
/// against the real network and the real bundled ffmpeg/ffprobe, covering
/// the three non-YouTube cases from `docs/plan-phase2b-wiring.md` SCOPE 7
/// (YouTube itself is covered by the lead's
/// `test/live/lead_pipeline_live_test.dart`): an X/Twitter mp4, a public
/// HLS test stream (the ffmpeg-direct download path this phase added), and
/// a direct mp4 URL. Gated by `MIDA_LIVE=1`.
///
/// Run with: `MIDA_LIVE=1 flutter test test/live/pipeline_live_test.dart`
void main() {
  final isLive = Platform.environment['MIDA_LIVE'] == '1';
  final skipReason = isLive ? false : 'set MIDA_LIVE=1';
  final projectDir = Directory.current.path;
  final ffmpeg = '$projectDir/windows_binaries/ffmpeg.exe';
  final ffprobe = '$projectDir/windows_binaries/ffprobe.exe';

  Future<List<List<String>>> probe(String path) async {
    final r = await Process.run(ffprobe, [
      '-v', 'error',
      '-show_entries', 'stream=codec_type,codec_name',
      '-of', 'csv=p=0',
      path,
    ]);
    expect(r.exitCode, 0, reason: 'ffprobe failed: ${r.stderr}');
    return (r.stdout as String)
        .trim()
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .map((l) => l.trim().split(','))
        .toList();
  }

  group('MediaDownloadPipeline live', () {
    late Directory outDir;

    setUp(() async {
      outDir = await Directory.systemTemp.createTemp('mida_pipeline_live_');
    });

    tearDown(() async {
      if (await outDir.exists()) await outDir.delete(recursive: true);
    });

    test('X/Twitter mp4 downloads and probes as a playable video', () async {
      final pipeline = MediaDownloadPipeline(merger: MediaMerger(ffmpegPathResolver: () async => ffmpeg));
      final info = await buildExtractorRegistry().resolveInfo(
        Uri.parse('https://twitter.com/captainamerica/status/719944021058060289'),
      );
      expect(info.formats.every((f) => f.protocol == 'https'), isTrue);

      final path = await pipeline.download(
        info: info,
        type: DownloadType.video,
        options: const DownloadOptions(videoFormat: VideoFormat.mp4),
        outputDir: outDir.path,
      );

      final file = File(path);
      expect(await file.exists(), isTrue, reason: 'output missing: $path');
      expect(await file.length(), greaterThan(0));
      final streams = await probe(path);
      stdout.writeln('twitter pipeline streams: $streams');
      expect(streams.any((s) => s[1] == 'video'), isTrue);
    }, skip: skipReason, timeout: const Timeout(Duration(minutes: 3)));

    test('X/Twitter audio mp3 extracts audio from the muxed source (no audio-only stream exists)', () async {
      // X's syndication endpoint only ever exposes progressive (muxed)
      // mp4 renditions (`TwitterResponseParser`), never a dedicated
      // audio-only stream - this is exactly the case `FormatSelector`'s
      // muxed-audio fallback (`needsAudioExtraction`) exists for.
      final pipeline = MediaDownloadPipeline(merger: MediaMerger(ffmpegPathResolver: () async => ffmpeg));
      final info = await buildExtractorRegistry().resolveInfo(
        Uri.parse('https://twitter.com/captainamerica/status/719944021058060289'),
      );
      expect(info.formats.every((f) => f.isAudioOnly), isFalse, reason: 'expected only muxed mp4 renditions');

      final path = await pipeline.download(
        info: info,
        type: DownloadType.audio,
        options: const DownloadOptions(audioFormat: AudioFormat.mp3, audioQuality: AudioQuality.high),
        outputDir: outDir.path,
      );

      final file = File(path);
      expect(await file.exists(), isTrue, reason: 'output missing: $path');
      expect(await file.length(), greaterThan(0));
      expect(path.toLowerCase().endsWith('.mp3'), isTrue);
      final streams = await probe(path);
      stdout.writeln('twitter audio pipeline streams: $streams');
      expect(streams.any((s) => s[1] == 'audio'), isTrue);
      expect(streams.any((s) => s[1] == 'video'), isFalse, reason: 'audio extraction should have dropped the video track');
    }, skip: skipReason, timeout: const Timeout(Duration(minutes: 3)));

    test('public HLS test stream downloads through the ffmpeg-direct path and probes as playable', () async {
      final pipeline = MediaDownloadPipeline(merger: MediaMerger(ffmpegPathResolver: () async => ffmpeg));
      // Goes through the registry (not the extractor directly) so
      // `ExtractorRegistry.resolveInfo`'s protocol normalization actually
      // stamps these m3u8 formats `protocol: 'hls'`, which is what routes
      // the pipeline into `HlsFfmpegDownloader` below instead of the plain
      // ranged-GET path (which cannot resolve HLS segment URLs correctly:
      // they are relative to the manifest's network location, not to a
      // locally downloaded copy of it).
      final info = await buildExtractorRegistry().resolveInfo(
        Uri.parse('https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8'),
      );
      expect(info.formats, isNotEmpty);
      expect(info.formats.every((f) => f.protocol == 'hls'), isTrue);

      final path = await pipeline.download(
        info: info,
        type: DownloadType.video,
        options: const DownloadOptions(videoFormat: VideoFormat.mp4, videoQuality: VideoQuality.p720),
        outputDir: outDir.path,
      );

      final file = File(path);
      expect(await file.exists(), isTrue, reason: 'output missing: $path');
      expect(await file.length(), greaterThan(0));
      final streams = await probe(path);
      stdout.writeln('hls pipeline streams: $streams');
      expect(streams.any((s) => s[1] == 'video'), isTrue);
    }, skip: skipReason, timeout: const Timeout(Duration(minutes: 3)));

    test('a direct mp4 URL downloads through the plain https path and probes as playable', () async {
      final pipeline = MediaDownloadPipeline(merger: MediaMerger(ffmpegPathResolver: () async => ffmpeg));
      final info = await buildExtractorRegistry().resolveInfo(Uri.parse('https://www.w3schools.com/html/mov_bbb.mp4'));
      expect(info.formats.every((f) => f.protocol == 'https'), isTrue);

      final path = await pipeline.download(
        info: info,
        type: DownloadType.video,
        options: const DownloadOptions(videoFormat: VideoFormat.mp4),
        outputDir: outDir.path,
      );

      final file = File(path);
      expect(await file.exists(), isTrue, reason: 'output missing: $path');
      expect(await file.length(), greaterThan(0));
      final streams = await probe(path);
      stdout.writeln('direct mp4 pipeline streams: $streams');
      expect(streams.any((s) => s[1] == 'video'), isTrue);
    }, skip: skipReason, timeout: const Timeout(Duration(minutes: 3)));

    test('buildExtractorRegistry resolves all three URLs to the extractor Phase 2b intends', () {
      final registry = buildExtractorRegistry();
      expect(
        registry.find(Uri.parse('https://twitter.com/captainamerica/status/719944021058060289')),
        isA<TwitterExtractor>(),
      );
      expect(
        registry.find(Uri.parse('https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8')),
        isA<GenericExtractor>(),
      );
      expect(
        registry.find(Uri.parse('https://www.w3schools.com/html/mov_bbb.mp4')),
        isA<GenericExtractor>(),
      );
    });
  });
}
