import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/generic/hls_playlist_parser.dart';

void main() {
  group('HlsPlaylistParser.parseMasterVariants', () {
    late String masterPlaylist;

    setUpAll(() {
      masterPlaylist = File('test/fixtures/hls_master.m3u8').readAsStringSync();
    });

    test('expands a master playlist into one variant per #EXT-X-STREAM-INF, resolving relative URIs', () {
      final variants = HlsPlaylistParser.parseMasterVariants(
        masterPlaylist,
        Uri.parse('https://example.com/streams/x36xhzz/x36xhzz.m3u8'),
      );

      expect(variants, hasLength(5));

      final first = variants.first;
      expect(first.width, 422);
      expect(first.height, 180);
      expect(first.bandwidth, 246440);
      expect(first.url, 'https://example.com/streams/x36xhzz/url_0/193039199_mp4_h264_aac_ld_7.m3u8');

      final last = variants.last;
      expect(last.width, 1280);
      expect(last.height, 544);
      expect(last.bandwidth, 6221600);
    });

    test('a media playlist (no #EXT-X-STREAM-INF) yields no variants', () {
      const mediaPlaylist = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:10
#EXTINF:10.0,
segment0.ts
#EXTINF:10.0,
segment1.ts
#EXT-X-ENDLIST
''';
      final variants = HlsPlaylistParser.parseMasterVariants(mediaPlaylist, Uri.parse('https://example.com/a.m3u8'));
      expect(variants, isEmpty);
    });

    test('a variant line without a following URI is skipped, not crashed on', () {
      const trailing = '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000,RESOLUTION=640x360';
      final variants = HlsPlaylistParser.parseMasterVariants(trailing, Uri.parse('https://example.com/a.m3u8'));
      expect(variants, isEmpty);
    });

    // Phase 6 (docs/plan-phase6-av-pairing.md, Lane P, P1): CODECS and
    // AUDIO="..." are now captured on HlsVariant itself.
    test('captures CODECS and AUDIO group id from a variant referencing an alternate-audio group', () {
      const playlist = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=1280x720,CODECS="avc1.4d401f,mp4a.40.2",AUDIO="aud1"
video.m3u8
''';
      final variants = HlsPlaylistParser.parseMasterVariants(playlist, Uri.parse('https://example.com/master.m3u8'));
      expect(variants, hasLength(1));
      expect(variants.single.codecs, 'avc1.4d401f,mp4a.40.2');
      expect(variants.single.audioGroupId, 'aud1');
    });

    test('a variant with no AUDIO attribute leaves audioGroupId null (guard: without capturing this attribute, '
        'HlsMasterFormatMapper could never distinguish a split-audio master from a plain muxed one)', () {
      const playlist = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=1280x720,CODECS="avc1.4d401f,mp4a.40.2"
video.m3u8
''';
      final variants = HlsPlaylistParser.parseMasterVariants(playlist, Uri.parse('https://example.com/master.m3u8'));
      expect(variants.single.audioGroupId, isNull);
    });
  });

  group('HlsPlaylistParser.parseAudioRenditions', () {
    test('a URI-carrying #EXT-X-MEDIA:TYPE=AUDIO rendition resolves to an absolute HlsAudioRendition', () {
      const playlist = '''
#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud1",NAME="English",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,CHANNELS="2",URI="audio/en.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=1280x720,CODECS="avc1.4d401f,mp4a.40.2",AUDIO="aud1"
video.m3u8
''';
      final renditions = HlsPlaylistParser.parseAudioRenditions(playlist, Uri.parse('https://example.com/streams/master.m3u8'));
      expect(renditions, hasLength(1));
      final r = renditions.single;
      expect(r.groupId, 'aud1');
      expect(r.uri, 'https://example.com/streams/audio/en.m3u8');
      expect(r.name, 'English');
      expect(r.language, 'en');
      expect(r.isDefault, isTrue);
      expect(r.isAutoSelect, isTrue);
      expect(r.channels, 2);
    });

    test('an EXT-X-MEDIA rendition with no URI (muxed into the variant) is excluded, not returned with a null uri '
        '(guard: including it would make HlsMasterFormatMapper try to fetch a non-existent audio-only stream)', () {
      const playlist = '''
#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud1",NAME="English",LANGUAGE="en"
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=1280x720,AUDIO="aud1"
video.m3u8
''';
      final renditions = HlsPlaylistParser.parseAudioRenditions(playlist, Uri.parse('https://example.com/master.m3u8'));
      expect(renditions, isEmpty);
    });

    test('a non-audio #EXT-X-MEDIA (e.g. TYPE=SUBTITLES) is ignored', () {
      const playlist = '''
#EXTM3U
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",URI="subs/en.m3u8"
''';
      final renditions = HlsPlaylistParser.parseAudioRenditions(playlist, Uri.parse('https://example.com/master.m3u8'));
      expect(renditions, isEmpty);
    });

    test('DEFAULT absent defaults isDefault to false, and CHANNELS with a trailing /JOC (Atmos) still parses '
        'the leading digit', () {
      const playlist = '''
#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud1",URI="a.m3u8",CHANNELS="16/JOC"
''';
      final renditions = HlsPlaylistParser.parseAudioRenditions(playlist, Uri.parse('https://example.com/master.m3u8'));
      expect(renditions.single.isDefault, isFalse);
      expect(renditions.single.isAutoSelect, isFalse);
      expect(renditions.single.channels, 16);
    });

    test('a non-master (media) playlist yields no audio renditions', () {
      const mediaPlaylist = '#EXTM3U\n#EXTINF:10.0,\nsegment0.ts\n';
      expect(HlsPlaylistParser.parseAudioRenditions(mediaPlaylist, Uri.parse('https://example.com/a.m3u8')), isEmpty);
    });

    test('round 3 P-R3-3: CHARACTERISTICS, FORCED and LANGUAGE are parsed, and isAccessibility only matches a '
        'real public.accessibility.* identifier', () {
      const playlist = '''
#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud1",NAME="described",LANGUAGE="en",FORCED=NO,CHARACTERISTICS="public.accessibility.describes-video,public.easy-to-read",URI="ad.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud1",NAME="forced",LANGUAGE="fr",FORCED=YES,URI="forced.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud1",NAME="main",LANGUAGE="en",CHARACTERISTICS="com.example.public.accessibility.not-really",URI="main.m3u8"
''';
      final renditions = HlsPlaylistParser.parseAudioRenditions(playlist, Uri.parse('https://example.com/master.m3u8'));
      expect(renditions, hasLength(3));

      expect(renditions[0].language, 'en');
      expect(renditions[0].characteristics, 'public.accessibility.describes-video,public.easy-to-read');
      expect(renditions[0].isAccessibility, isTrue);
      expect(renditions[0].isForced, isFalse);

      expect(renditions[1].isForced, isTrue);
      expect(renditions[1].isAccessibility, isFalse, reason: 'no CHARACTERISTICS at all');

      expect(renditions[2].isAccessibility, isFalse,
          reason: 'guard can fail: a substring match would flag this vendor identifier and demote the main track');
    });
  });
}
