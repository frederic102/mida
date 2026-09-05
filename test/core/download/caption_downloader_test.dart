import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/download/caption_downloader.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/features/download/services/download_service_io.dart';

void main() {
  final tracks = [
    const CaptionTrack(languageCode: 'en', url: 'https://example.invalid/en-manual', isAuto: false),
    const CaptionTrack(languageCode: 'en', url: 'https://example.invalid/en-auto', isAuto: true),
    const CaptionTrack(languageCode: 'ko', url: 'https://example.invalid/ko-auto', isAuto: true),
    const CaptionTrack(languageCode: 'en-GB', url: 'https://example.invalid/en-gb', isAuto: false),
  ];
  const translatable = ['ko', 'ja', 'de'];

  group('CaptionDownloader.selectPlans', () {
    test('SubtitleOption.none returns no plans', () {
      expect(CaptionDownloader.selectPlans(tracks, translatable, SubtitleOption.none), isEmpty);
    });

    test('an exact match prefers the manual track over the auto one', () {
      final plans = CaptionDownloader.selectPlans(tracks, translatable, SubtitleOption.english);
      expect(plans, hasLength(1));
      expect(plans.single.sourceTrack.isAuto, isFalse);
      expect(plans.single.translateTo, isNull);
    });

    test('an exact match with only an auto track still returns it', () {
      final plans = CaptionDownloader.selectPlans(tracks, translatable, SubtitleOption.korean);
      expect(plans, hasLength(1));
      expect(plans.single.sourceTrack.isAuto, isTrue);
      expect(plans.single.translateTo, isNull);
    });

    test('a prefix match (en-GB) is used when no exact "en" track exists', () {
      final noExactEnglish = [
        const CaptionTrack(languageCode: 'en-GB', url: 'https://example.invalid/en-gb', isAuto: false),
      ];
      final plans = CaptionDownloader.selectPlans(noExactEnglish, translatable, SubtitleOption.english);
      expect(plans, hasLength(1));
      expect(plans.single.sourceTrack.languageCode, 'en-GB');
      expect(plans.single.translateTo, isNull);
    });

    test('an exact match is preferred over a prefix match when both exist', () {
      final plans = CaptionDownloader.selectPlans(tracks, translatable, SubtitleOption.english);
      expect(plans.single.sourceTrack.languageCode, 'en');
    });

    test('no native or prefix track falls back to auto-translation from the asr track', () {
      final noKorean = [
        const CaptionTrack(languageCode: 'en', url: 'https://example.invalid/en-manual', isAuto: false),
        const CaptionTrack(languageCode: 'en', url: 'https://example.invalid/en-auto', isAuto: true),
      ];
      final plans = CaptionDownloader.selectPlans(noKorean, translatable, SubtitleOption.korean);
      expect(plans, hasLength(1));
      expect(plans.single.translateTo, 'ko');
      expect(plans.single.sourceTrack.isAuto, isTrue);
      expect(plans.single.outputLanguageCode, 'ko');
    });

    test('a language YouTube does not offer as a translation target is skipped, not guessed at', () {
      final noKorean = [
        const CaptionTrack(languageCode: 'en', url: 'https://example.invalid/en-auto', isAuto: true),
      ];
      final plans = CaptionDownloader.selectPlans(noKorean, const ['ja', 'de'], SubtitleOption.korean);
      expect(plans, isEmpty);
    });

    test('ko,en requests both, one plan per language', () {
      final plans = CaptionDownloader.selectPlans(tracks, translatable, SubtitleOption.koreanEnglish);
      expect(plans.map((p) => p.outputLanguageCode).toSet(), {'ko', 'en'});
    });

    test('no tracks at all yields no plans, not a crash', () {
      final plans = CaptionDownloader.selectPlans(const [], translatable, SubtitleOption.english);
      expect(plans, isEmpty);
    });
  });

  group('CaptionDownloader.download against a local HttpServer', () {
    late HttpServer server;
    late Directory tempDir;
    Map<String, String>? capturedHeaders;
    int responseStatus = 200;
    String responseBody = 'WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nhello';

    setUp(() async {
      capturedHeaders = null;
      responseStatus = 200;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        capturedHeaders = {
          for (final name in request.headers.value('x-test-header') != null ? ['x-test-header'] : <String>[])
            name: request.headers.value(name)!,
        };
        request.response.statusCode = responseStatus;
        request.response.write(responseStatus == 200 ? responseBody : 'not found');
        await request.response.close();
      });
      tempDir = await Directory.systemTemp.createTemp('mida_caption_dl_');
    });

    tearDown(() async {
      await server.close(force: true);
      await tempDir.delete(recursive: true);
    });

    test('a 200 response is written to the output file', () async {
      final track = CaptionTrack(languageCode: 'en', url: 'http://127.0.0.1:${server.port}/caps');
      final downloader = CaptionDownloader();
      final outputPath = '${tempDir.path}/out.vtt';

      await downloader.download(track, outputPath);

      final content = await File(outputPath).readAsString();
      expect(content, contains('WEBVTT'));
    });

    test('a 404 response throws instead of writing an empty/garbage file', () async {
      responseStatus = 404;
      final track = CaptionTrack(languageCode: 'en', url: 'http://127.0.0.1:${server.port}/caps');
      final downloader = CaptionDownloader();
      final outputPath = '${tempDir.path}/out.vtt';

      await expectLater(
        downloader.download(track, outputPath),
        throwsA(isA<CaptionDownloadException>()),
      );
      expect(await File(outputPath).exists(), isFalse);
    });

    test('custom headers passed to download() reach the server', () async {
      final track = CaptionTrack(languageCode: 'en', url: 'http://127.0.0.1:${server.port}/caps');
      final downloader = CaptionDownloader();
      final outputPath = '${tempDir.path}/out.vtt';

      await downloader.download(track, outputPath, headers: const {'X-Test-Header': 'mida-caption'});

      expect(capturedHeaders?['x-test-header'], 'mida-caption');
    });

    test('translateTo appends &tlang= to the fetched URL', () async {
      String? capturedPath;
      final translateServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      translateServer.listen((request) async {
        capturedPath = request.uri.toString();
        request.response.write('WEBVTT');
        await request.response.close();
      });

      try {
        final track = CaptionTrack(languageCode: 'en', url: 'http://127.0.0.1:${translateServer.port}/caps?lang=en');
        final downloader = CaptionDownloader();
        final outputPath = '${tempDir.path}/out.vtt';
        await downloader.download(track, outputPath, translateTo: 'ko');

        expect(capturedPath, contains('tlang=ko'));
        expect(capturedPath, contains('fmt=vtt'));
      } finally {
        await translateServer.close(force: true);
      }
    });
  });

  group('CaptionDownloader https-only guard', () {
    test('refuses a non-https, non-loopback URL', () async {
      final downloader = CaptionDownloader();
      const track = CaptionTrack(languageCode: 'en', url: 'http://example.invalid/caps');
      await expectLater(
        downloader.download(track, '${Directory.systemTemp.path}/should_not_be_created.vtt'),
        throwsA(isA<CaptionDownloadException>()),
      );
    });
  });
}
