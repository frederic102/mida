import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/extractors/soundcloud/soundcloud_track_parser.dart';

void main() {
  group('SoundCloudTrackParser.parse against a real captured resolve response', () {
    Future<Map<String, dynamic>> fixture() async =>
        jsonDecode(await File('test/fixtures/soundcloud_resolve_track.json').readAsString()) as Map<String, dynamic>;

    test('reads metadata and orders progressive before hls transcodings', () async {
      final track = await fixture();
      // The captured response is preview-only; lift the flag to exercise a full-length track.
      for (final t in (track['media'] as Map)['transcodings'] as List) {
        (t as Map).remove('snipped');
      }

      final info = const SoundCloudTrackParser().parse(track);
      expect(info.id, '253508261');
      expect(info.title, 'Never Gonna Give You Up');
      expect(info.author, 'Rick Astley');
      expect(info.duration, const Duration(milliseconds: 213603));
      expect(info.transcodings, hasLength(2));
      expect(info.transcodings.first.isHls, isFalse);
      expect(info.transcodings.last.isHls, isTrue);
    });

    test('throws LOGIN_REQUIRED when every rendition is a snipped 30s preview (live 2026-11-08)', () {
      // Guard-can-fail: without the snipped filter this parses fine and the
      // download later ends "Output is shorter than the source".
      expect(
        () => const SoundCloudTrackParser().parse(_trackWith(snippedFlags: [true, true])),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'LOGIN_REQUIRED')),
      );
    });

    test('the captured preview-only response is refused as LOGIN_REQUIRED', () async {
      final track = await fixture();
      expect(
        () => const SoundCloudTrackParser().parse(track),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'LOGIN_REQUIRED')),
      );
    });

    test('keeps full renditions and drops the snipped one when both are offered', () {
      final info = const SoundCloudTrackParser().parse(_trackWith(snippedFlags: [true, false]));
      expect(info.transcodings, hasLength(1));
      expect(info.transcodings.single.url, endsWith('/full'));
      expect(info.transcodings.single.snipped, isFalse);
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

/// A track whose renditions carry the given `snipped` flags; the unflagged ones end in `/full`.
Map<String, dynamic> _trackWith({required List<bool> snippedFlags}) => {
      'id': 1,
      'title': 't',
      'full_duration': 213603,
      'media': {
        'transcodings': [
          for (final snipped in snippedFlags)
            {
              'url': 'https://api-v2.soundcloud.com/media/x/${snipped ? 'preview' : 'full'}',
              'snipped': snipped,
              'format': {'protocol': 'progressive', 'mime_type': 'audio/mpeg'},
            },
        ],
      },
    };
