import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/extractors/twitch/twitch_playlist_parser.dart';

void main() {
  group('TwitchPlaylistParser.parse against a real captured usher master playlist', () {
    test('parses every EXT-X-STREAM-INF rendition into its own m3u8 MediaFormat', () async {
      final playlist = await File('test/fixtures/twitch_usher_master.m3u8').readAsString();
      final formats = const TwitchPlaylistParser().parse(playlist);

      expect(formats, hasLength(5));
      expect(formats.every((f) => f.container == 'm3u8'), isTrue);
      expect(formats.every((f) => f.isMuxed), isTrue);

      final source = formats.firstWhere((f) => f.height == 1080);
      expect(source.width, 1920);
      expect(source.videoCodec, 'avc1.64002A');
      expect(source.audioCodec, 'mp4a.40.2');
      expect(source.bitrate, 8640622);
      expect(source.url, contains('/chunked/index-dvr.m3u8'));

      final lowest = formats.firstWhere((f) => f.height == 160);
      expect(lowest.width, 284);
    });

    test('throws UNSUPPORTED_MEDIA for a playlist with no renditions', () {
      expect(
        () => const TwitchPlaylistParser().parse('#EXTM3U\n#EXT-X-TWITCH-INFO:ORIGIN="s3"\n'),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'UNSUPPORTED_MEDIA')),
      );
    });
  });
}
