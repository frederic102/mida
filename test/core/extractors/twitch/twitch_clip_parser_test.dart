import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/extractors/twitch/twitch_clip_parser.dart';

void main() {
  group('TwitchClipParser.parse against a fixture matching the documented public contract', () {
    test('signs each videoQualities.sourceURL with the playbackAccessToken', () async {
      final raw = await File('test/fixtures/twitch_clip_response.json').readAsString();
      final data = jsonDecode(raw) as Map<String, dynamic>;

      final info = const TwitchClipParser().parse(
        data,
        sourceUrl: Uri.parse('https://clips.twitch.tv/InsaneClip'),
        requestHeaders: const {},
      );

      expect(info.title, 'Insane clutch');
      expect(info.author, 'shroud');
      expect(info.duration, const Duration(seconds: 32));
      expect(info.formats, hasLength(3));
      final best = info.formats.firstWhere((f) => f.height == 1080);
      expect(best.url, contains('EXAMPLE-1080p60.mp4?sig=d2298f3b758c9cc844f24d6156e5181b1b4d81ac&token='));
      expect(best.isMuxed, isTrue);
    });

    test('throws CHALLENGE_FAILED (fall-through eligible) when clip is null', () {
      expect(
        () => const TwitchClipParser().parse(
          {'clip': null},
          sourceUrl: Uri.parse('https://clips.twitch.tv/gone'),
          requestHeaders: const {},
        ),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'CHALLENGE_FAILED')),
      );
    });

    test('throws UNSUPPORTED_MEDIA when videoQualities is empty', () {
      expect(
        () => const TwitchClipParser().parse(
          {'clip': {'title': 't', 'videoQualities': <dynamic>[]}},
          sourceUrl: Uri.parse('https://clips.twitch.tv/empty'),
          requestHeaders: const {},
        ),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'UNSUPPORTED_MEDIA')),
      );
    });
  });
}
