import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/extractors/soundcloud/soundcloud_hydration_parser.dart';

void main() {
  group('SoundCloudHydrationParser.parse against a fixture matching the documented shape', () {
    test('reads track metadata and both transcodings', () async {
      final raw = await File('test/fixtures/soundcloud_hydration.json').readAsString();
      final hydration = jsonDecode(raw) as List<dynamic>;

      final info = const SoundCloudHydrationParser().parse(hydration);
      expect(info.id, '183978791');
      expect(info.title, 'Never Gonna Give You Up');
      expect(info.author, 'officialrickastley');
      expect(info.duration, const Duration(milliseconds: 213000));
      expect(info.transcodings, hasLength(2));
      expect(info.transcodings.where((t) => t.isHls), hasLength(1));
      expect(info.transcodings.where((t) => !t.isHls), hasLength(1));
    });

    test('throws PARSE_ERROR (fall-through eligible) when no "sound" hydratable entry is present', () {
      expect(
        () => const SoundCloudHydrationParser().parse([
          {'hydratable': 'anonymousId', 'data': 'x'},
        ]),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'PARSE_ERROR')),
      );
    });

    test('throws UNSUPPORTED_MEDIA when media.transcodings is empty', () {
      expect(
        () => const SoundCloudHydrationParser().parse([
          {
            'hydratable': 'sound',
            'data': {
              'id': 1,
              'title': 't',
              'media': {'transcodings': <dynamic>[]},
            },
          },
        ]),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'UNSUPPORTED_MEDIA')),
      );
    });
  });
}
