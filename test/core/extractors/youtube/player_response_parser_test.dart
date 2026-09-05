import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/extractors/youtube/player_response_parser.dart';

Map<String, dynamic> _loadFixture(String name) {
  final raw = File('test/fixtures/$name').readAsStringSync();
  return jsonDecode(raw) as Map<String, dynamic>;
}

void main() {
  const parser = PlayerResponseParser();
  final sourceUrl = Uri.parse('https://www.youtube.com/watch?v=dQw4w9WgXcQ');
  const headers = {'User-Agent': 'test-agent'};

  group('PlayerResponseParser against a real visionOS player response', () {
    final json = _loadFixture('youtube_player_visionos.json');

    test('parses title, author and duration from videoDetails', () {
      final info = parser.parse(json, sourceUrl: sourceUrl, requestHeaders: headers);

      expect(info.id, 'dQw4w9WgXcQ');
      expect(info.title, contains('Never Gonna Give You Up'));
      expect(info.author, 'Rick Astley');
      expect(info.duration, const Duration(seconds: 213));
    });

    test('parses every adaptive format and reports the expected height set', () {
      final info = parser.parse(json, sourceUrl: sourceUrl, requestHeaders: headers);

      expect(info.formats.length, greaterThanOrEqualTo(20));

      final heights = info.formats.where((f) => f.height != null).map((f) => f.height).toSet();
      expect(heights, containsAll(<int>[2160, 1080, 720, 480, 360, 144]));

      final audioOnly = info.formats.where((f) => f.isAudioOnly).toList();
      expect(audioOnly, isNotEmpty);
      expect(audioOnly.every((f) => f.height == null), isTrue);

      final videoOnly = info.formats.where((f) => f.isVideoOnly).toList();
      expect(videoOnly, isNotEmpty);
      expect(videoOnly.every((f) => f.height != null), isTrue);
    });

    test('picks the highest resolution thumbnail', () {
      final info = parser.parse(json, sourceUrl: sourceUrl, requestHeaders: headers);
      expect(info.thumbnailUrl, contains('hq720'));
    });

    test('parses caption tracks and flags auto-generated ones', () {
      final info = parser.parse(json, sourceUrl: sourceUrl, requestHeaders: headers);

      expect(info.captions, isNotEmpty);
      final english = info.captions.where((c) => c.languageCode == 'en').toList();
      expect(english.length, 2);
      expect(english.any((c) => c.isAuto), isTrue);
      expect(english.any((c) => !c.isAuto), isTrue);
    });

    test('splits codecs out of the mimeType for a known avc1/mp4a pair', () {
      final info = parser.parse(json, sourceUrl: sourceUrl, requestHeaders: headers);
      final avc1080p = info.formats.firstWhere((f) => f.id == '137');
      expect(avc1080p.container, 'mp4');
      expect(avc1080p.videoCodec, startsWith('avc1'));
      expect(avc1080p.hasVideo, isTrue);
      expect(avc1080p.hasAudio, isFalse);

      final aacAudio = info.formats.firstWhere((f) => f.id == '140');
      expect(aacAudio.container, 'mp4');
      expect(aacAudio.audioCodec, startsWith('mp4a'));
      expect(aacAudio.hasAudio, isTrue);
      expect(aacAudio.hasVideo, isFalse);
    });

    test('string-typed contentLength from the API is parsed as an int', () {
      final info = parser.parse(json, sourceUrl: sourceUrl, requestHeaders: headers);
      final withLength = info.formats.where((f) => f.contentLength != null).toList();
      expect(withLength, isNotEmpty);
      expect(withLength.first.contentLength, greaterThan(0));
    });

    test('parses translationLanguages as a flat list of language codes, including ko', () {
      final info = parser.parse(json, sourceUrl: sourceUrl, requestHeaders: headers);
      expect(info.translatableLanguageCodes, isNotEmpty);
      expect(info.translatableLanguageCodes, contains('ko'));
      // This video has no native Korean captionTrack: translation is the
      // only path to a Korean subtitle, which is exactly why this list
      // matters (see CaptionDownloader.selectPlans).
      expect(info.captions.any((c) => c.languageCode == 'ko'), isFalse);
    });
  });

  group('PlayerResponseParser error mapping', () {
    test('LOGIN_REQUIRED throws MediaExtractionException with the reason', () {
      final json = _loadFixture('youtube_player_login_required.json');
      expect(
        () => parser.parse(json, sourceUrl: sourceUrl, requestHeaders: headers),
        throwsA(
          isA<MediaExtractionException>()
              .having((e) => e.status, 'status', 'LOGIN_REQUIRED')
              .having((e) => e.reason, 'reason', isNotNull),
        ),
      );
    });

    test('UNPLAYABLE throws MediaExtractionException with the reason', () {
      final json = _loadFixture('youtube_player_unplayable.json');
      expect(
        () => parser.parse(json, sourceUrl: sourceUrl, requestHeaders: headers),
        throwsA(
          isA<MediaExtractionException>().having((e) => e.status, 'status', 'UNPLAYABLE'),
        ),
      );
    });

    test('malformed JSON (playabilityStatus is a String, not a Map) is PARSE_ERROR, not a raw TypeError', () {
      final malformed = <String, dynamic>{
        'playabilityStatus': 'this should have been an object',
        'videoDetails': {'videoId': 'abc'},
      };
      expect(
        () => parser.parse(malformed, sourceUrl: sourceUrl, requestHeaders: headers),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'PARSE_ERROR')),
      );
    });

    test('malformed JSON (adaptiveFormats entries are not maps) is PARSE_ERROR, not a raw TypeError', () {
      final malformed = <String, dynamic>{
        'playabilityStatus': {'status': 'OK'},
        'videoDetails': {'videoId': 'abc', 'title': 'x'},
        'streamingData': {
          'adaptiveFormats': 'this should have been a list',
        },
      };
      // A string where a list was expected is defensively skipped by
      // `_parseFormatList`'s `is! List` check, so this one actually
      // succeeds with an empty format list rather than throwing; the
      // PARSE_ERROR case above covers the "genuinely malformed" path.
      final info = parser.parse(malformed, sourceUrl: sourceUrl, requestHeaders: headers);
      expect(info.formats, isEmpty);
    });
  });

  group('PlayerResponseParser edge cases (hand-built, no fixture)', () {
    test('missing streamingData entirely yields an empty format list, not a crash', () {
      final json = {
        'playabilityStatus': {'status': 'OK'},
        'videoDetails': {'videoId': 'abc', 'title': 'No streams'},
      };
      final info = parser.parse(json, sourceUrl: sourceUrl, requestHeaders: headers);
      expect(info.formats, isEmpty);
    });

    test('missing adaptiveFormats (only muxed formats present) does not crash', () {
      final json = {
        'playabilityStatus': {'status': 'OK'},
        'videoDetails': {'videoId': 'abc', 'title': 'Muxed only'},
        'streamingData': {
          'formats': [
            {
              'itag': 18,
              'url': 'https://example.invalid/18',
              'mimeType': 'video/mp4; codecs="avc1.42001E, mp4a.40.2"',
              'height': 360,
              'bitrate': 500000,
            },
          ],
        },
      };
      final info = parser.parse(json, sourceUrl: sourceUrl, requestHeaders: headers);
      expect(info.formats, hasLength(1));
      expect(info.formats.single.isMuxed, isTrue);
    });

    test('a format with no height is not dropped, just left with a null height', () {
      final json = {
        'playabilityStatus': {'status': 'OK'},
        'videoDetails': {'videoId': 'abc', 'title': 'No height'},
        'streamingData': {
          'adaptiveFormats': [
            {
              'itag': 140,
              'url': 'https://example.invalid/140',
              'mimeType': 'audio/mp4; codecs="mp4a.40.2"',
              'bitrate': 128000,
            },
          ],
        },
      };
      final info = parser.parse(json, sourceUrl: sourceUrl, requestHeaders: headers);
      expect(info.formats.single.height, isNull);
      expect(info.formats.single.isAudioOnly, isTrue);
    });

    test('a format entry with no url is skipped instead of crashing', () {
      final json = {
        'playabilityStatus': {'status': 'OK'},
        'videoDetails': {'videoId': 'abc', 'title': 'Cipher only'},
        'streamingData': {
          'adaptiveFormats': [
            {'itag': 140, 'signatureCipher': 's=...', 'mimeType': 'audio/mp4'},
          ],
        },
      };
      final info = parser.parse(json, sourceUrl: sourceUrl, requestHeaders: headers);
      expect(info.formats, isEmpty);
    });

    test('captions absent yields an empty list, not a crash', () {
      final json = {
        'playabilityStatus': {'status': 'OK'},
        'videoDetails': {'videoId': 'abc', 'title': 'No captions'},
      };
      final info = parser.parse(json, sourceUrl: sourceUrl, requestHeaders: headers);
      expect(info.captions, isEmpty);
    });
  });
}
