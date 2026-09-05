import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/download/hls_ffmpeg_downloader.dart';
import 'package:mida/core/download/media_merger.dart';

void main() {
  group('HlsFfmpegDownloader.buildArgs', () {
    final downloader = HlsFfmpegDownloader();

    test('non-audio-only args copy both streams and fix up ADTS AAC', () {
      final args = downloader.buildArgs(
        url: 'https://example.invalid/master.m3u8',
        outputPath: 'C:/out/video.mp4',
        headers: const {'User-Agent': 'mida-test-ua', 'Referer': 'https://example.invalid/'},
      );

      expect(args, containsAllInOrder(['-user_agent', 'mida-test-ua']));
      expect(args, containsAllInOrder(['-headers', 'Referer: https://example.invalid/\r\n']));
      expect(args, containsAllInOrder(['-i', 'https://example.invalid/master.m3u8']));
      expect(args, containsAllInOrder(['-c', 'copy', '-bsf:a', 'aac_adtstoasc']));
      expect(args, containsAllInOrder(['-progress', 'pipe:1']));
      expect(args.last, 'C:/out/video.mp4');
      expect(args, isNot(contains('-vn')));
    });

    test('audio-only args drop video and use the requested codec instead of copy', () {
      final args = downloader.buildArgs(
        url: 'https://example.invalid/audio.m3u8',
        outputPath: 'C:/out/audio.mp3',
        audioOnly: true,
        audioCodecArgs: const ['-c:a', 'libmp3lame'],
      );

      expect(args, containsAllInOrder(['-vn', '-c:a', 'libmp3lame']));
      expect(args, isNot(contains('-bsf:a')));
      expect(args, isNot(containsAllInOrder(['-c', 'copy'])));
    });

    test('no User-Agent header omits -user_agent entirely', () {
      final args = downloader.buildArgs(url: 'https://example.invalid/x.m3u8', outputPath: 'out.mp4');
      expect(args, isNot(contains('-user_agent')));
      expect(args, isNot(contains('-headers')));
    });

    group('-protocol_whitelist locks the demuxer down (security)', () {
      test('an https manifest gets https,tcp,tls,crypto - no plain http', () {
        final args = downloader.buildArgs(url: 'https://example.invalid/x.m3u8', outputPath: 'out.mp4');
        expect(args, containsAllInOrder(['-protocol_whitelist', 'https,tcp,tls,crypto', '-i']));
      });

      test('an http manifest allows http too (only because the manifest URL itself is http)', () {
        final args = downloader.buildArgs(url: 'http://example.invalid/x.m3u8', outputPath: 'out.mp4');
        expect(args, containsAllInOrder(['-protocol_whitelist', 'http,https,tcp,tls,crypto', '-i']));
      });

      test('no `file`, `concat` or `subfile` in the whitelist regardless of scheme', () {
        for (final url in ['https://example.invalid/x.m3u8', 'http://example.invalid/x.m3u8']) {
          final args = downloader.buildArgs(url: url, outputPath: 'out.mp4');
          final whitelistValue = args[args.indexOf('-protocol_whitelist') + 1];
          for (final forbidden in ['file', 'concat', 'subfile']) {
            expect(whitelistValue, isNot(contains(forbidden)));
          }
        }
      });
    });

    group('header injection guard (security)', () {
      test('a CRLF in a header value throws HeaderInjectionException (guard: a cookie carrying an injected header)', () {
        expect(
          () => downloader.buildArgs(
            url: 'https://example.invalid/x.m3u8',
            outputPath: 'out.mp4',
            headers: const {'Cookie': 'session=abc\r\nX-Injected-Header: evil'},
          ),
          throwsA(isA<HeaderInjectionException>()),
        );
      });

      test('a bare LF in a header value also throws', () {
        expect(
          () => downloader.buildArgs(
            url: 'https://example.invalid/x.m3u8',
            outputPath: 'out.mp4',
            headers: const {'Referer': 'https://example.invalid/\nX-Injected: evil'},
          ),
          throwsA(isA<HeaderInjectionException>()),
        );
      });

      test('a CRLF in the User-Agent value also throws', () {
        expect(
          () => downloader.buildArgs(
            url: 'https://example.invalid/x.m3u8',
            outputPath: 'out.mp4',
            headers: const {'User-Agent': 'evil-ua\r\nX-Injected: evil'},
          ),
          throwsA(isA<HeaderInjectionException>()),
        );
      });

      test('other control characters (not CR/LF) are stripped, not rejected', () {
        final args = downloader.buildArgs(
          url: 'https://example.invalid/x.m3u8',
          outputPath: 'out.mp4',
          headers: const {'Cookie': 'a=b\x00c'},
        );
        expect(args, containsAllInOrder(['-headers', 'Cookie: a=bc\r\n']));
      });

      test('a clean header value is unaffected', () {
        final args = downloader.buildArgs(
          url: 'https://example.invalid/x.m3u8',
          outputPath: 'out.mp4',
          headers: const {'Cookie': 'session=abc123'},
        );
        expect(args, containsAllInOrder(['-headers', 'Cookie: session=abc123\r\n']));
      });
    });

    group('-bsf:a aac_adtstoasc is conditional on the output container', () {
      for (final ext in ['mp4', 'm4a', 'mov', 'MP4']) {
        test('applied for a .$ext output (mp4-family)', () {
          final args = downloader.buildArgs(url: 'https://example.invalid/x.m3u8', outputPath: 'out.$ext');
          expect(args, containsAllInOrder(['-c', 'copy', '-bsf:a', 'aac_adtstoasc']));
        });
      }

      for (final ext in ['webm', 'mkv']) {
        test('omitted for a .$ext output (not mp4-family)', () {
          final args = downloader.buildArgs(url: 'https://example.invalid/x.m3u8', outputPath: 'out.$ext');
          expect(args, containsAllInOrder(['-c', 'copy']));
          expect(args, isNot(contains('-bsf:a')));
        });
      }

      test('omitted for an output path with no extension at all', () {
        final args = downloader.buildArgs(url: 'https://example.invalid/x.m3u8', outputPath: 'out_no_ext');
        expect(args, isNot(contains('-bsf:a')));
      });
    });
  });

  group('HlsFfmpegDownloader.parseOutTime', () {
    test('parses a well-formed out_time_ms line into a Duration', () {
      expect(HlsFfmpegDownloader.parseOutTime('out_time_ms=2500000'), const Duration(microseconds: 2500000));
    });

    test('ignores every other progress key', () {
      expect(HlsFfmpegDownloader.parseOutTime('frame=120'), isNull);
      expect(HlsFfmpegDownloader.parseOutTime('fps=29.97'), isNull);
      expect(HlsFfmpegDownloader.parseOutTime('progress=continue'), isNull);
      expect(HlsFfmpegDownloader.parseOutTime(''), isNull);
    });

    test('tolerates surrounding whitespace/CR', () {
      expect(HlsFfmpegDownloader.parseOutTime(' out_time_ms=1000\r'), const Duration(microseconds: 1000));
    });
  });

  group('HlsFfmpegDownloader.run against a real (fake) ffmpeg executable', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('mida_hls_run_');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('reports progress from out_time_ms lines against a known total duration', () async {
      final scriptPath = '${tempDir.path}/fake_ffmpeg_progress.bat';
      await File(scriptPath).writeAsString(
        '@echo off\r\n'
        'echo out_time_ms=2000000\r\n'
        'echo out_time_ms=4000000\r\n'
        'exit /b 0\r\n',
      );

      final downloader = HlsFfmpegDownloader(ffmpegPathResolver: () async => scriptPath);
      final progressValues = <double>[];
      await downloader.run(
        ['-y', '-i', 'in.m3u8', 'out.mp4'],
        totalDuration: const Duration(microseconds: 4000000),
        onProgress: progressValues.add,
      );

      expect(progressValues, [0.5, 1.0]);
    });

    test('no totalDuration means onProgress is never called', () async {
      final scriptPath = '${tempDir.path}/fake_ffmpeg_no_total.bat';
      await File(scriptPath).writeAsString('@echo off\r\necho out_time_ms=1000\r\nexit /b 0\r\n');

      final downloader = HlsFfmpegDownloader(ffmpegPathResolver: () async => scriptPath);
      var called = false;
      await downloader.run(['-y', '-i', 'in.m3u8', 'out.mp4'], onProgress: (_) => called = true);

      expect(called, isFalse);
    });

    test('a script that exits non-zero surfaces as MediaMergeException with the stderr tail', () async {
      final scriptPath = '${tempDir.path}/fake_ffmpeg_fail.bat';
      await File(scriptPath).writeAsString(
        '@echo off\r\necho fake hls ffmpeg failure 1>&2\r\nexit /b 1\r\n',
      );

      final downloader = HlsFfmpegDownloader(ffmpegPathResolver: () async => scriptPath);
      await expectLater(
        downloader.run(['-y', '-i', 'in.m3u8', 'out.mp4']),
        throwsA(isA<MediaMergeException>().having(
          (e) => e.message,
          'message',
          contains('fake hls ffmpeg failure'),
        )),
      );
    });

    test('a script that exits zero completes without throwing', () async {
      final scriptPath = '${tempDir.path}/fake_ffmpeg_ok.bat';
      await File(scriptPath).writeAsString('@echo off\r\nexit /b 0\r\n');

      final downloader = HlsFfmpegDownloader(ffmpegPathResolver: () async => scriptPath);
      await downloader.run(['-y', '-i', 'in.m3u8', 'out.mp4']);
    });
  });

}
