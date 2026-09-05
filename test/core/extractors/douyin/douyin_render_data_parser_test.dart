import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/douyin/douyin_render_data_parser.dart';
import 'package:mida/core/extractors/media_models.dart';

void main() {
  group('DouyinRenderDataParser.parse against a fixture matching the documented RENDER_DATA shape', () {
    test('finds aweme.detail under an opaque numeric wrapper key and prefers bit_rate renditions', () async {
      final raw = await File('test/fixtures/douyin_render_data.json').readAsString();
      final renderData = jsonDecode(raw) as Map<String, dynamic>;

      final info = const DouyinRenderDataParser().parse(
        renderData,
        sourceUrl: Uri.parse('https://www.douyin.com/video/7318947853764676900'),
        requestHeaders: const {},
      );

      expect(info.id, '7318947853764676900');
      expect(info.title, 'Example Douyin caption #fyp');
      expect(info.author, 'example_creator');
      expect(info.duration, const Duration(milliseconds: 15000));
      // bit_rate renditions are unwatermarked and preferred over the
      // single watermarked play_addr fallback.
      expect(info.formats, hasLength(2));
      expect(info.formats.every((f) => !f.url.contains('watermarked')), isTrue);
      final best = info.formats.firstWhere((f) => f.height == 1920);
      expect(best.url, 'https://aweme.snssdk.com/EXAMPLE/hq-1080.mp4');
    });

    test('falls back to play_addr when there is no bit_rate list', () {
      final info = const DouyinRenderDataParser().parse(
        {
          'x': {
            'aweme': {
              'detail': {
                'aweme_id': '1',
                'desc': 'no bit_rate',
                'video': {
                  'play_addr': {
                    'url_list': ['https://aweme.snssdk.com/only.mp4'],
                  },
                },
              },
            },
          },
        },
        sourceUrl: Uri.parse('https://www.douyin.com/video/1'),
        requestHeaders: const {},
      );
      expect(info.formats.single.url, 'https://aweme.snssdk.com/only.mp4');
    });

    test('throws PARSE_ERROR (fall-through eligible) when no aweme.detail node exists anywhere', () {
      expect(
        () => const DouyinRenderDataParser().parse(
          {'1': {}, '2': {'unrelated': true}},
          sourceUrl: Uri.parse('https://www.douyin.com/video/1'),
          requestHeaders: const {},
        ),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'PARSE_ERROR')),
      );
    });
  });
}
