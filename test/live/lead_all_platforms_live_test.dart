import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/download/media_merger.dart';
import 'package:mida/core/extractors/extractor_registry_builder.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/features/download/services/download_service_io.dart';
import 'package:mida/features/download/services/media_download_pipeline.dart';

/// Lead seam check across every platform through the real registry and the
/// real pipeline (no GUI): resolve, download a small video, ffprobe it.
/// Gated by MIDA_LIVE=1.
void main() {
  final isLive = Platform.environment['MIDA_LIVE'] == '1';
  final projectDir = Directory.current.path;
  final ffmpeg = '$projectDir/windows_binaries/ffmpeg.exe';
  final ffprobe = '$projectDir/windows_binaries/ffprobe.exe';

  Future<List<String>> codecTypes(String path) async {
    final r = await Process.run(ffprobe, ['-v', 'error', '-show_entries', 'stream=codec_type', '-of', 'csv=p=0', path]);
    return (r.stdout as String).trim().split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
  }

  const cases = <String, String>{
    'youtube': 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
    'twitter': 'https://twitter.com/captainamerica/status/719944021058060289',
    'tiktok': 'https://www.tiktok.com/@hankgreen1/video/7047596209028074758',
    'instagram': 'https://www.instagram.com/reel/Chunk8-jurw/',
    'vimeo (generic)': 'https://vimeo.com/76979871',
    'hls (generic)': 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
  };

  test('vimeo (generic): logged-out playlists are DRM, reported cleanly', () async {
    // Measured 2026-09-05: every playlist Vimeo serves without a login is
    // /playlist/drm/cbcs; yt-dlp fails here too ("only works when logged-in").
    try {
      await buildExtractorRegistry().resolveInfo(Uri.parse('https://vimeo.com/76979871'));
      fail('expected a DRM_PROTECTED extraction error');
    } on MediaExtractionException catch (e) {
      stdout.writeln('[vimeo] $e');
      expect(e.status, 'DRM_PROTECTED');
      expect(e.toString().contains('!'), isFalse);
    }
  }, skip: isLive ? false : 'set MIDA_LIVE=1', timeout: const Timeout(Duration(minutes: 3)));

  for (final entry in cases.entries) {
    if (entry.key.startsWith('vimeo')) continue;
    test('${entry.key}: resolve + 480p mp4 download + ffprobe', () async {
      final outDir = await Directory.systemTemp.createTemp('mida_lead_all_');
      try {
        final registry = buildExtractorRegistry();
        final sw = Stopwatch()..start();
        final info = await registry.resolveInfo(Uri.parse(entry.value));
        stdout.writeln('[${entry.key}] resolved in ${sw.elapsedMilliseconds}ms title="${info.title}" formats=${info.formats.length}');
        expect(info.formats, isNotEmpty);

        final pipeline = MediaDownloadPipeline(merger: MediaMerger(ffmpegPathResolver: () async => ffmpeg));
        final path = await pipeline.download(
          info: info,
          type: DownloadType.video,
          options: const DownloadOptions(videoQuality: VideoQuality.p480, videoFormat: VideoFormat.mp4),
          outputDir: outDir.path,
          onStatus: (s) => stdout.writeln('   status: $s'),
        );
        final size = await File(path).length();
        final types = await codecTypes(path);
        stdout.writeln('[${entry.key}] file=${path.split(RegExp(r'[\\/]')).last} size=${(size / 1024 / 1024).toStringAsFixed(1)}MB streams=$types total=${sw.elapsed.inSeconds}s');
        expect(size, greaterThan(30 * 1024));
        expect(types, contains('video'));
        final sourceHasAudio = info.formats.any((f) => f.hasAudio);
        if (sourceHasAudio) expect(types, contains('audio'));
        final leftovers = await outDir.list().where((e) => e.path.endsWith('.part')).toList();
        expect(leftovers, isEmpty);
      } finally {
        if (await outDir.exists()) await outDir.delete(recursive: true);
      }
    }, skip: isLive ? false : 'set MIDA_LIVE=1', timeout: const Timeout(Duration(minutes: 6)));
  }
}
