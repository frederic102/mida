import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/extractors/reddit/reddit_dash_manifest_parser.dart';

void main() {
  group('RedditDashManifestParser.parse against a fixture matching v.redd.it\'s manifest shape', () {
    test('splits video and audio AdaptationSets into video-only/audio-only MediaFormats', () async {
      final xml = await File('test/fixtures/reddit_dash_playlist.mpd').readAsString();
      final formats = const RedditDashManifestParser().parse(
        xml,
        baseUrl: 'https://v.redd.it/abc123def456/',
      );

      expect(formats, hasLength(3));
      final videoOnly = formats.where((f) => f.isVideoOnly).toList();
      final audioOnly = formats.where((f) => f.isAudioOnly).toList();
      expect(videoOnly, hasLength(2));
      expect(audioOnly, hasLength(1));

      final source = videoOnly.firstWhere((f) => f.height == 720);
      expect(source.url, 'https://v.redd.it/abc123def456/DASH_720.mp4');
      expect(source.videoCodec, 'avc1.640028');
      expect(source.bitrate, 4500000);

      expect(audioOnly.single.url, 'https://v.redd.it/abc123def456/DASH_audio.mp4');
      expect(audioOnly.single.audioCodec, 'mp4a.40.2');
    });

    test('throws UNSUPPORTED_MEDIA for a manifest with no Representation/BaseURL', () {
      expect(
        () => const RedditDashManifestParser().parse(
          '<MPD><Period></Period></MPD>',
          baseUrl: 'https://v.redd.it/x/',
        ),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'UNSUPPORTED_MEDIA')),
      );
    });
  });
}
