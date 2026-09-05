import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/download/media_merger.dart';
import 'package:mida/core/extractors/extractor_registry_builder.dart';
import 'package:mida/features/download/services/download_service_io.dart';
import 'package:mida/features/download/services/media_download_pipeline.dart';

/// Lead-level seam verification: the real pipeline classes end to end
/// against the real network and the real bundled ffmpeg/ffprobe, without
/// the GUI. Gated by `MIDA_LIVE=1`.
///
/// Run with: `MIDA_LIVE=1 flutter test test/live/lead_pipeline_live_test.dart`
void main() {
  final isLive = Platform.environment['MIDA_LIVE'] == '1';
  final projectDir = Directory.current.path;
  final ffmpeg = '$projectDir/windows_binaries/ffmpeg.exe';
  final ffprobe = '$projectDir/windows_binaries/ffprobe.exe';

  Future<List<List<String>>> probe(String path) async {
    final r = await Process.run(ffprobe, [
      '-v', 'error',
      '-show_entries', 'stream=codec_type,codec_name,height',
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

  group('MediaDownloadPipeline live (lead seam check)', () {
    late Directory outDir;

    setUp(() async {
      outDir = await Directory.systemTemp.createTemp('mida_lead_live_');
    });

    tearDown(() async {
      if (await outDir.exists()) await outDir.delete(recursive: true);
    });

    test('1080p mp4 with Korean subtitle produces a playable file', () async {
      final pipeline = MediaDownloadPipeline(
        merger: MediaMerger(ffmpegPathResolver: () async => ffmpeg),
      );
      final info = await buildExtractorRegistry()
          .resolveInfo(Uri.parse('https://www.youtube.com/watch?v=dQw4w9WgXcQ'));
      expect(info.title, isNotEmpty);

      final path = await pipeline.download(
        info: info,
        type: DownloadType.video,
        options: const DownloadOptions(
          videoQuality: VideoQuality.p1080,
          videoFormat: VideoFormat.mp4,
          subtitleOption: SubtitleOption.korean,
        ),
        outputDir: outDir.path,
        onProgress: (p) => expect(p, inInclusiveRange(0.0, 1.0)),
        onStatus: (s) => stdout.writeln('status: $s'),
      );

      final file = File(path);
      expect(await file.exists(), isTrue, reason: 'output missing: $path');
      final size = await file.length();
      stdout.writeln('video output: $path (${(size / 1024 / 1024).toStringAsFixed(1)} MB)');
      expect(size, greaterThan(5 * 1024 * 1024));
      expect(path.toLowerCase().endsWith('.mp4'), isTrue);

      final streams = await probe(path);
      stdout.writeln('ffprobe streams: $streams');
      final video = streams.where((s) => s[1] == 'video').toList();
      final audio = streams.where((s) => s[1] == 'audio').toList();
      expect(video.length, 1, reason: 'expected exactly one video stream');
      expect(audio.length, 1, reason: 'expected exactly one audio stream');
      expect(int.tryParse(video.first.length > 2 ? video.first[2] : ''), 1080);

      final entries = await outDir.list().map((e) => e.path).toList();
      stdout.writeln('output dir: $entries');
      final srt = entries.where((p) => p.toLowerCase().endsWith('.srt')).toList();
      expect(srt, isNotEmpty, reason: 'expected a Korean .srt next to the video');
      final srtText = await File(srt.first).readAsString();
      expect(srtText.contains('-->'), isTrue, reason: 'srt should contain cue timings');
      final leftovers = entries.where((p) => p.endsWith('.part') || p.endsWith('.vtt'));
      expect(leftovers, isEmpty, reason: 'temp files left behind: $leftovers');
    }, skip: isLive ? false : 'set MIDA_LIVE=1', timeout: const Timeout(Duration(minutes: 6)));

    test('audio mp3 320k produces an mp3 stream', () async {
      final pipeline = MediaDownloadPipeline(
        merger: MediaMerger(ffmpegPathResolver: () async => ffmpeg),
      );
      final info = await buildExtractorRegistry()
          .resolveInfo(Uri.parse('https://www.youtube.com/watch?v=dQw4w9WgXcQ'));
      final path = await pipeline.download(
        info: info,
        type: DownloadType.audio,
        options: const DownloadOptions(
          audioFormat: AudioFormat.mp3,
          audioQuality: AudioQuality.high,
        ),
        outputDir: outDir.path,
      );
      final size = await File(path).length();
      stdout.writeln('audio output: $path (${(size / 1024 / 1024).toStringAsFixed(1)} MB)');
      expect(path.toLowerCase().endsWith('.mp3'), isTrue);
      final streams = await probe(path);
      stdout.writeln('ffprobe streams: $streams');
      expect(streams.any((s) => s[1] == 'audio' && s[0] == 'mp3'), isTrue);
      expect(streams.any((s) => s[1] == 'video'), isFalse);
    }, skip: isLive ? false : 'set MIDA_LIVE=1', timeout: const Timeout(Duration(minutes: 4)));
  });
}
