import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/extractors/reddit/reddit_post_parser.dart';

void main() {
  group('RedditPostParser.parse against a fixture matching the documented .json contract', () {
    test('reads title/author/thumbnail/duration and the DASH/HLS/fallback URLs', () async {
      final raw = await File('test/fixtures/reddit_post_listing.json').readAsString();
      final json = jsonDecode(raw);

      final info = const RedditPostParser().parse(json);
      expect(info.id, '1c0xhqk');
      expect(info.title, 'My dog discovers snow for the first time');
      expect(info.author, 'example_user');
      expect(info.thumbnailUrl, 'https://b.thumbs.redditmedia.com/EXAMPLE.jpg');
      expect(info.duration, const Duration(seconds: 14));
      expect(info.dashUrl, 'https://v.redd.it/abc123def456/DASHPlaylist.mpd');
      expect(info.hlsUrl, 'https://v.redd.it/abc123def456/HLSPlaylist.m3u8');
    });

    test('throws NOT_FOUND for an empty listing', () {
      expect(
        () => const RedditPostParser().parse([
          {
            'data': {'children': []},
          },
        ]),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'NOT_FOUND')),
      );
    });

    test('throws UNSUPPORTED_MEDIA for a text/image post with no reddit_video', () {
      expect(
        () => const RedditPostParser().parse([
          {
            'data': {
              'children': [
                {
                  'data': {'id': '1', 'title': 'just text'},
                },
              ],
            },
          },
        ]),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'UNSUPPORTED_MEDIA')),
      );
    });

    test('ignores non-URL thumbnail sentinels like "self"', () {
      final info = const RedditPostParser().parse([
        {
          'data': {
            'children': [
              {
                'data': {
                  'id': '1',
                  'title': 't',
                  'thumbnail': 'self',
                  'secure_media': {
                    'reddit_video': {'dash_url': 'https://v.redd.it/x/DASHPlaylist.mpd'},
                  },
                },
              },
            ],
          },
        },
      ]);
      expect(info.thumbnailUrl, isNull);
    });

    test('follows crosspost_parent_list when the post itself has no media', () {
      final info = const RedditPostParser().parse([
        {
          'data': {
            'children': [
              {
                'data': {
                  'id': '1',
                  'title': 'crosspost',
                  'crosspost_parent_list': [
                    {
                      'media': {
                        'reddit_video': {'dash_url': 'https://v.redd.it/parent/DASHPlaylist.mpd'},
                      },
                    },
                  ],
                },
              },
            ],
          },
        },
      ]);
      expect(info.dashUrl, 'https://v.redd.it/parent/DASHPlaylist.mpd');
    });
  });
}
