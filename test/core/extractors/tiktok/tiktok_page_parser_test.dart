import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/extractors/tiktok/tiktok_page_parser.dart';

String _wrapAsUniversalDataPage(String json) =>
    '<html><body><script id="__UNIVERSAL_DATA_FOR_REHYDRATION__" type="application/json">$json</script></body></html>';

String _detailPage(Map<String, dynamic> detail) => _wrapAsUniversalDataPage(jsonEncode({
      '__DEFAULT_SCOPE__': {'webapp.video-detail': detail},
    }));

void main() {
  const parser = TikTokPageParser();
  final sourceUrl = Uri.parse('https://www.tiktok.com/@hankgreen1/video/7047596209028074758');
  const headers = <String, String>{'User-Agent': 'x'};

  group('TikTokPageParser against a real video-detail response', () {
    final html = _wrapAsUniversalDataPage(File('test/fixtures/tiktok_universal_data.json').readAsStringSync());

    test('hasUniversalData is true for this page', () {
      expect(TikTokPageParser.hasUniversalData(html), isTrue);
    });

    test('falls back to "@author - post id" for an empty desc, and reads the author', () {
      final info = parser.parse(html, sourceUrl: sourceUrl, requestHeaders: headers);
      expect(info.title, '@hankgreen1 - 7047596209028074758');
      expect(info.author, 'hankgreen1');
      expect(info.id, '7047596209028074758');
    });

    test('parses duration in seconds and the cover thumbnail', () {
      final info = parser.parse(html, sourceUrl: sourceUrl, requestHeaders: headers);
      expect(info.duration, const Duration(seconds: 21));
      expect(info.thumbnailUrl, contains('tiktokcdn.com'));
    });

    test('parses both bitrateInfo renditions as muxed mp4 (music present) with the highest bitrate first', () {
      final info = parser.parse(html, sourceUrl: sourceUrl, requestHeaders: headers);
      expect(info.formats.length, 2);
      expect(info.formats.every((f) => f.isMuxed && f.container == 'mp4'), isTrue);
      final best = info.formats.reduce((a, b) => a.bitrate > b.bitrate ? a : b);
      expect(best.bitrate, 1895168);
      expect(best.width, 576);
      expect(best.height, 1024);
      expect(best.videoCodec, 'h264');
      expect(best.contentLength, 5076682, reason: 'DataSize is a string in the real payload, must still parse as int');
    });

    test('carries requestHeaders through untouched', () {
      final info = parser.parse(html, sourceUrl: sourceUrl, requestHeaders: headers);
      expect(info.requestHeaders, headers);
    });
  });

  group('TikTokPageParser statusCode mapping', () {
    test('10216 maps to PRIVATE', () {
      final html = _detailPage({'statusCode': 10216, 'itemInfo': {}});
      expect(
        () => parser.parse(html, sourceUrl: sourceUrl, requestHeaders: headers),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'PRIVATE')),
      );
    });

    test('10222 also maps to PRIVATE', () {
      final html = _detailPage({'statusCode': 10222, 'itemInfo': {}});
      expect(
        () => parser.parse(html, sourceUrl: sourceUrl, requestHeaders: headers),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'PRIVATE')),
      );
    });

    test('10204 maps to RATE_LIMITED', () {
      final html = _detailPage({'statusCode': 10204, 'itemInfo': {}});
      expect(
        () => parser.parse(html, sourceUrl: sourceUrl, requestHeaders: headers),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'RATE_LIMITED')),
      );
    });

    test('an unrecognized non-zero statusCode maps to NOT_FOUND', () {
      final html = _detailPage({'statusCode': 10201, 'itemInfo': {}});
      expect(
        () => parser.parse(html, sourceUrl: sourceUrl, requestHeaders: headers),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'NOT_FOUND')),
      );
    });
  });

  group('TikTokPageParser photo-post / missing-data handling', () {
    test('a photo post (no bitrateInfo, no playAddr) surfaces as UNSUPPORTED_MEDIA', () {
      final html = _detailPage({
        'statusCode': 0,
        'itemInfo': {
          'itemStruct': {
            'id': '1',
            'desc': 'a photo carousel',
            'video': {'duration': 0, 'cover': null, 'bitrateInfo': []},
          },
        },
      });
      expect(
        () => parser.parse(html, sourceUrl: sourceUrl, requestHeaders: headers),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'UNSUPPORTED_MEDIA')),
      );
    });

    test('falls back to video.playAddr when bitrateInfo is absent entirely', () {
      final html = _detailPage({
        'statusCode': 0,
        'itemInfo': {
          'itemStruct': {
            'id': '1',
            'desc': 'legacy shape',
            'video': {'duration': 5, 'playAddr': 'https://example.com/v.mp4', 'width': 720, 'height': 1280},
          },
        },
      });
      final info = parser.parse(html, sourceUrl: sourceUrl, requestHeaders: headers);
      expect(info.formats.single.url, 'https://example.com/v.mp4');
      expect(info.formats.single.width, 720);
    });

    test('a missing itemStruct surfaces as NOT_FOUND', () {
      final html = _detailPage({'statusCode': 0, 'itemInfo': {}});
      expect(
        () => parser.parse(html, sourceUrl: sourceUrl, requestHeaders: headers),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'NOT_FOUND')),
      );
    });

    test('a page with no universal data script at all surfaces as PARSE_ERROR', () {
      expect(
        () => parser.parse('<html><body>plain page</body></html>', sourceUrl: sourceUrl, requestHeaders: headers),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'PARSE_ERROR')),
      );
      expect(TikTokPageParser.hasUniversalData('<html><body>plain page</body></html>'), isFalse);
    });

    test('a universal data script with invalid JSON surfaces as PARSE_ERROR', () {
      expect(
        () => parser.parse(
          _wrapAsUniversalDataPage('{not valid json'),
          sourceUrl: sourceUrl,
          requestHeaders: headers,
        ),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'PARSE_ERROR')),
      );
    });
  });

  group('TikTokPageParser.buildSocialTitle', () {
    test('truncates a long desc to 60 chars and prefixes the author', () {
      final title = TikTokPageParser.buildSocialTitle(
        author: 'someuser',
        caption: 'a' * 200,
        postId: '1',
      );
      expect(title, '@someuser - ${'a' * 60}');
    });

    test('falls back to the post id when the desc is empty', () {
      final title = TikTokPageParser.buildSocialTitle(author: 'someuser', caption: '', postId: '42');
      expect(title, '@someuser - 42');
    });

    test('strips URLs and line breaks before truncating', () {
      final title = TikTokPageParser.buildSocialTitle(
        author: 'someuser',
        caption: 'check this out\nhttps://example.com/very/long/link?x=1\nso cool',
        postId: '1',
      );
      expect(title, '@someuser - check this out so cool');
    });
  });

  group('TikTokPageParser audio signal (item.music presence)', () {
    // Guard-can-fail evidence: this and the "music present" test above use
    // the exact same parse() path with only the fixture's `music` field
    // changed, so a hardcoded `hasAudio: true` (the bug this replaced)
    // would make *this* test fail while the other one stays green -
    // proving the flag is actually read from data, not a literal.
    test('hasAudio is false on every rendition when item.music is absent', () {
      final html = _detailPage({
        'statusCode': 0,
        'itemInfo': {
          'itemStruct': {
            'id': '1',
            'desc': 'silent clip, no music object at all',
            'video': {
              'duration': 3,
              'bitrateInfo': [
                {
                  'Bitrate': 500000,
                  'CodecType': 'h264',
                  'PlayAddr': {
                    'UrlList': ['https://example.com/silent.mp4'],
                    'Width': 720,
                    'Height': 1280,
                  },
                },
              ],
            },
          },
        },
      });
      final info = parser.parse(html, sourceUrl: sourceUrl, requestHeaders: headers);
      expect(info.formats.every((f) => f.hasAudio == false), isTrue);
      expect(info.formats.single.isVideoOnly, isTrue);
    });
  });
}
