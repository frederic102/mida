import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/extractors/twitter/twitter_response_parser.dart';

Map<String, dynamic> _loadFixture(String name) {
  final raw = File('test/fixtures/$name').readAsStringSync();
  return jsonDecode(raw) as Map<String, dynamic>;
}

void main() {
  const parser = TwitterResponseParser();
  final sourceUrl = Uri.parse('https://x.com/CaptainAmerica/status/719944021058060289');
  const headers = <String, String>{};

  group('TwitterResponseParser against a real syndication response', () {
    final json = _loadFixture('twitter_syndication.json');

    test('parses id, title and author', () {
      final info = parser.parse(json, sourceUrl: sourceUrl, requestHeaders: headers);
      expect(info.id, '719944021058060289');
      expect(info.title, contains('Are you sure you made the right choice'));
      expect(info.author, 'CaptainAmerica');
    });

    test('parses duration from video_info.duration_millis', () {
      final info = parser.parse(json, sourceUrl: sourceUrl, requestHeaders: headers);
      expect(info.duration, const Duration(milliseconds: 3170));
    });

    test('parses thumbnail from media_url_https', () {
      final info = parser.parse(json, sourceUrl: sourceUrl, requestHeaders: headers);
      expect(info.thumbnailUrl, contains('ext_tw_video_thumb'));
    });

    test('parses only the mp4 variants, skipping the m3u8 playlist', () {
      final info = parser.parse(json, sourceUrl: sourceUrl, requestHeaders: headers);
      expect(info.formats.length, 3);
      expect(info.formats.every((f) => f.container == 'mp4'), isTrue);
      expect(info.formats.every((f) => f.isMuxed), isTrue);
    });

    test('reports the highest bitrate variant as 1280x720', () {
      final info = parser.parse(json, sourceUrl: sourceUrl, requestHeaders: headers);
      final best = info.formats.reduce((a, b) => a.bitrate > b.bitrate ? a : b);
      expect(best.width, 1280);
      expect(best.height, 720);
      expect(best.bitrate, 2176000);
    });
  });

  group('TwitterResponseParser against a card tweet (no attached video)', () {
    // Shape of the real syndication response for a card/external-player
    // tweet (verified live against
    // https://twitter.com/starwars/status/665052190608723968): HTTP 200,
    // valid JSON, but no `mediaDetails` key at all.
    final json = jsonDecode(
      '{"id_str":"665052190608723968","text":"card tweet, no attached video",'
      '"user":{"screen_name":"starwars"}}',
    ) as Map<String, dynamic>;

    test('throws UNSUPPORTED_MEDIA instead of silently returning zero formats', () {
      expect(
        () => parser.parse(json, sourceUrl: sourceUrl, requestHeaders: headers),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'UNSUPPORTED_MEDIA')),
      );
    });
  });

  group('TwitterResponseParser against mediaDetails with only an m3u8 playlist', () {
    final json = jsonDecode(
      '{"id_str":"1","text":"only a playlist, no progressive mp4","user":{"screen_name":"x"},'
      '"mediaDetails":[{"media_url_https":"https://pbs.twimg.com/t.jpg",'
      '"video_info":{"duration_millis":1000,"variants":'
      '[{"content_type":"application/x-mpegURL","url":"https://video.twimg.com/pl/x.m3u8"}]}}]}',
    ) as Map<String, dynamic>;

    test('also throws UNSUPPORTED_MEDIA (no mp4 rendition to offer)', () {
      expect(
        () => parser.parse(json, sourceUrl: sourceUrl, requestHeaders: headers),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'UNSUPPORTED_MEDIA')),
      );
    });
  });
}
