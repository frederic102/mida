import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/bilibili/bilibili_playurl_parser.dart';
import 'package:mida/core/extractors/media_models.dart';

void main() {
  group('BilibiliPlayurlParser.parse against a fixture matching the documented DASH playurl shape', () {
    test('splits dash.video[] and dash.audio[] into video-only/audio-only MediaFormats', () async {
      final raw = await File('test/fixtures/bilibili_playurl.json').readAsString();
      final json = jsonDecode(raw) as Map<String, dynamic>;

      final formats = const BilibiliPlayurlParser().parse(json);
      expect(formats, hasLength(3));
      final videoOnly = formats.where((f) => f.isVideoOnly).toList();
      final audioOnly = formats.where((f) => f.isAudioOnly).toList();
      expect(videoOnly, hasLength(2));
      expect(audioOnly, hasLength(1));

      final source = videoOnly.firstWhere((f) => f.height == 1080);
      expect(source.width, 1920);
      expect(source.videoCodec, 'avc1.640032');
      expect(source.container, 'mp4');

      expect(audioOnly.single.audioCodec, 'mp4a.40.2');
    });

    test('maps code -403 to LOGIN_REQUIRED', () {
      expect(
        () => const BilibiliPlayurlParser().parse({'code': -403, 'message': 'need login'}),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'LOGIN_REQUIRED')),
      );
    });

    test('falls back to durl[] progressive mp4 when dash is absent', () {
      final formats = const BilibiliPlayurlParser().parse({
        'code': 0,
        'data': {
          'durl': [
            {'order': 1, 'url': 'https://upos.bilivideo.com/legacy.mp4', 'bandwidth': 500000, 'size': 12345},
          ],
        },
      });
      expect(formats.single.isMuxed, isTrue);
      expect(formats.single.url, 'https://upos.bilivideo.com/legacy.mp4');
    });

    test('throws UNSUPPORTED_MEDIA when there is no dash and no durl', () {
      expect(
        () => const BilibiliPlayurlParser().parse({'code': 0, 'data': {}}),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'UNSUPPORTED_MEDIA')),
      );
    });
  });
}
