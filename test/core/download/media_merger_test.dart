import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/download/media_merger.dart';
import 'package:mida/features/download/services/download_service_io.dart';

void main() {
  final merger = MediaMerger(ffmpegPathResolver: () async => 'ffmpeg');

  group('MediaMerger.buildMergeArgs (case a: video + audio -> mux)', () {
    test('compatible codecs copy both streams without re-encoding', () {
      final args = merger.buildMergeArgs(
        videoPath: 'video.mp4',
        audioPath: 'audio.m4a',
        outputPath: 'out.mp4',
        container: VideoFormat.mp4,
      );
      expect(
        args,
        ['-y', '-i', 'video.mp4', '-i', 'audio.m4a', '-c:v', 'copy', '-c:a', 'copy', 'out.mp4'],
      );
    });

    test('an incompatible audio codec for mp4 is transcoded to aac, video stays copied', () {
      final args = merger.buildMergeArgs(
        videoPath: 'video.mp4',
        audioPath: 'audio.webm',
        outputPath: 'out.mp4',
        container: VideoFormat.mp4,
        transcodeAudio: true,
      );
      expect(args, containsAllInOrder(['-c:v', 'copy']));
      expect(args, containsAllInOrder(['-c:a', 'aac']));
    });

    test('an incompatible video codec for mp4 is transcoded to libx264, audio stays copied', () {
      final args = merger.buildMergeArgs(
        videoPath: 'video.webm',
        audioPath: 'audio.m4a',
        outputPath: 'out.mp4',
        container: VideoFormat.mp4,
        transcodeVideo: true,
      );
      expect(args, containsAllInOrder(['-c:v', 'libx264']));
      expect(args, containsAllInOrder(['-c:a', 'copy']));
    });

    test('an incompatible video codec for webm is transcoded to libvpx-vp9, not libx264', () {
      final args = merger.buildMergeArgs(
        videoPath: 'video.mp4',
        audioPath: 'audio.webm',
        outputPath: 'out.webm',
        container: VideoFormat.webm,
        transcodeVideo: true,
      );
      expect(args, containsAllInOrder(['-c:v', 'libvpx-vp9']));
    });

    test('an incompatible audio codec for webm is transcoded to libopus', () {
      final args = merger.buildMergeArgs(
        videoPath: 'video.webm',
        audioPath: 'audio.m4a',
        outputPath: 'out.webm',
        container: VideoFormat.webm,
        transcodeAudio: true,
      );
      expect(args, containsAllInOrder(['-c:a', 'libopus']));
    });

    test('mkv always copies both, transcode flags are ignored by the caller (selector never sets them for mkv)', () {
      final args = merger.buildMergeArgs(
        videoPath: 'video.webm',
        audioPath: 'audio.webm',
        outputPath: 'out.mkv',
        container: VideoFormat.mkv,
      );
      expect(args, containsAllInOrder(['-c:v', 'copy']));
      expect(args, containsAllInOrder(['-c:a', 'copy']));
    });
  });

  group('MediaMerger.buildAudioConvertArgs (case b: audio-only transcode)', () {
    test('best quality omits an explicit bitrate flag', () {
      final args = merger.buildAudioConvertArgs(
        inputPath: 'in.webm',
        outputPath: 'out.mp3',
        format: AudioFormat.mp3,
        quality: AudioQuality.best,
      );
      expect(args, contains('-c:a'));
      expect(args, contains('libmp3lame'));
      expect(args, isNot(contains('-b:a')));
      expect(args.last, 'out.mp3');
    });

    test('an explicit quality maps to -b:a Nk', () {
      final args = merger.buildAudioConvertArgs(
        inputPath: 'in.webm',
        outputPath: 'out.mp3',
        format: AudioFormat.mp3,
        quality: AudioQuality.high,
      );
      expect(args, containsAllInOrder(['-b:a', '320k']));
    });

    test('each AudioFormat maps to its expected ffmpeg codec', () {
      final expected = {
        AudioFormat.mp3: 'libmp3lame',
        AudioFormat.m4a: 'aac',
        AudioFormat.opus: 'libopus',
        AudioFormat.flac: 'flac',
        AudioFormat.wav: 'pcm_s16le',
      };
      for (final entry in expected.entries) {
        final args = merger.buildAudioConvertArgs(
          inputPath: 'in.webm',
          outputPath: 'out',
          format: entry.key,
          quality: AudioQuality.best,
        );
        expect(args, containsAllInOrder(['-c:a', entry.value]), reason: entry.key.name);
      }
    });
  });

  group('MediaMerger.buildRemuxArgs (case c: muxed container change only)', () {
    test('remuxes with -c copy, no re-encode flags', () {
      final args = merger.buildRemuxArgs(inputPath: 'in.mp4', outputPath: 'out.mkv');
      expect(args, ['-y', '-i', 'in.mp4', '-c', 'copy', 'out.mkv']);
    });
  });

  group('MediaMerger.run against a real (fake) ffmpeg executable', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('mida_merger_run_');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('a script that exits non-zero surfaces as MediaMergeException', () async {
      final scriptPath = '${tempDir.path}/fake_ffmpeg.bat';
      await File(scriptPath).writeAsString('@echo off\necho fake ffmpeg failure 1>&2\r\nexit /b 1\r\n');

      final failingMerger = MediaMerger(ffmpegPathResolver: () async => scriptPath);
      await expectLater(
        failingMerger.run(['-y', '-i', 'in.mp4', 'out.mp4']),
        throwsA(isA<MediaMergeException>()),
      );
    });

    test('a script that exits zero completes without throwing', () async {
      final scriptPath = '${tempDir.path}/fake_ffmpeg_ok.bat';
      await File(scriptPath).writeAsString('@echo off\r\nexit /b 0\r\n');

      final okMerger = MediaMerger(ffmpegPathResolver: () async => scriptPath);
      await okMerger.run(['-y', '-i', 'in.mp4', 'out.mp4']);
    });

    test('a nonexistent ffmpeg path surfaces as ProcessException, not MediaMergeException', () async {
      final missingMerger = MediaMerger(
        ffmpegPathResolver: () async => '${tempDir.path}/does_not_exist_ffmpeg.exe',
      );
      await expectLater(
        missingMerger.run(['-y', '-i', 'in.mp4', 'out.mp4']),
        throwsA(isA<ProcessException>()),
      );
    });
  });
}
