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
  });
}
