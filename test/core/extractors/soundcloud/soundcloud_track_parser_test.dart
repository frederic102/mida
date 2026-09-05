import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/extractors/soundcloud/soundcloud_track_parser.dart';

void main() {
  group('SoundCloudTrackParser.parse against a real captured resolve response', () {
    test('reads metadata and orders progressive before hls transcodings', () async {
      final raw = await File('test/fixtures/soundcloud_resolve_track.json').readAsString();
      final track = jsonDecode(raw) as Map<String, dynamic>;

      final info = const SoundCloudTrackParser().parse(track);
      expect(info.id, '253508261');
      expect(info.title, 'Never Gonna Give You Up');
      expect(info.author, 'Rick Astley');
      expect(info.duration, const Duration(milliseconds: 213603));
      expect(info.transcodings, hasLength(2));
      expect(info.transcodings.first.isHls, isFalse);
      expect(info.transcodings.last.isHls, isTrue);
    });

    test('throws UNSUPPORTED_MEDIA when media.transcodings is empty', () {
      expect(
        () => const SoundCloudTrackParser().parse({
          'id': 1,
          'title': 't',
          'media': {'transcodings': <dynamic>[]},
        }),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'UNSUPPORTED_MEDIA')),
      );
    });

    test('falls back to duration when full_duration is absent', () {
      final info = const SoundCloudTrackParser().parse({
        'id': 1,
        'title': 't',
        'duration': 5000,
        'media': {
          'transcodings': [
            {
              'url': 'https://api-v2.soundcloud.com/media/x/progressive',
              'format': {'protocol': 'progressive', 'mime_type': 'audio/mpeg'},
            },
          ],
        },
      });
      expect(info.duration, const Duration(milliseconds: 5000));
    });
  });
}
