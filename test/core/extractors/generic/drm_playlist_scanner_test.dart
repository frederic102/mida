import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/generic/drm_playlist_scanner.dart';

void main() {
  group('DrmPlaylistScanner.isHlsDrmProtected', () {
    test('METHOD=SAMPLE-AES is DRM', () {
      const playlist = '''
#EXTM3U
#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://key",KEYFORMAT="com.apple.streamingkeydelivery"
#EXTINF:6.0,
seg0.ts
''';
      expect(DrmPlaylistScanner.isHlsDrmProtected(playlist), isTrue);
    });

    test('METHOD=SAMPLE-AES-CTR is DRM', () {
      const playlist = '#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES-CTR,URI="https://lic.example.com/key"\nseg0.ts\n';
      expect(DrmPlaylistScanner.isHlsDrmProtected(playlist), isTrue);
    });

    test('KEYFORMAT naming Widevine (urn:uuid:edef8ba9) is DRM regardless of METHOD casing', () {
      const playlist = '''
#EXTM3U
#EXT-X-KEY:METHOD=AES-128,URI="https://lic.example.com/key",KEYFORMAT="urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed"
seg0.ts
''';
      expect(DrmPlaylistScanner.isHlsDrmProtected(playlist), isTrue);
    });

    test('#EXT-X-SESSION-KEY (not just #EXT-X-KEY) is also scanned', () {
      const playlist = '''
#EXTM3U
#EXT-X-SESSION-KEY:METHOD=SAMPLE-AES,KEYFORMAT="com.apple.streamingkeydelivery"
#EXT-X-STREAM-INF:BANDWIDTH=100000
variant.m3u8
''';
      expect(DrmPlaylistScanner.isHlsDrmProtected(playlist), isTrue);
    });

    test(
      'a plain METHOD=AES-128 with an https key URI is NOT DRM (ffmpeg decrypts this natively)',
      () {
        const playlist = '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="https://cdn.example.com/key.bin"\nseg0.ts\n';
        expect(DrmPlaylistScanner.isHlsDrmProtected(playlist), isFalse);
      },
    );

    test('no #EXT-X-KEY tag at all is not DRM', () {
      const playlist = '#EXTM3U\n#EXTINF:6.0,\nseg0.ts\n#EXT-X-ENDLIST\n';
      expect(DrmPlaylistScanner.isHlsDrmProtected(playlist), isFalse);
    });

    // Guard-can-fail evidence (verified, see report): temporarily removing
    // `'sample-aes-ctr'` from `_drmMethods` made the SAMPLE-AES-CTR test
    // above fail (came back `false` instead of `true`), proving the
    // METHOD check - not some other path - is what flags it.
  });

  group('DrmPlaylistScanner.isMpdDrmProtected', () {
    test('a <ContentProtection> element is DRM', () {
      const manifest = '''
<MPD><Period><AdaptationSet>
  <ContentProtection schemeIdUri="urn:mpeg:dash:mp4protection:2011" cenc:default_KID="1234"/>
</AdaptationSet></Period></MPD>
''';
      expect(DrmPlaylistScanner.isMpdDrmProtected(manifest), isTrue);
    });

    test('a bare cenc:pssh box is DRM', () {
      const manifest = '<MPD><Period><AdaptationSet><cenc:pssh>base64data</cenc:pssh></AdaptationSet></Period></MPD>';
      expect(DrmPlaylistScanner.isMpdDrmProtected(manifest), isTrue);
    });

    test('a default_KID attribute is DRM', () {
      const manifest = '<MPD><Period><AdaptationSet default_KID="abcd1234"></AdaptationSet></Period></MPD>';
      expect(DrmPlaylistScanner.isMpdDrmProtected(manifest), isTrue);
    });

    test('a KEYFORMAT value is DRM', () {
      const manifest = '<MPD><Period><AdaptationSet keyformat="com.widevine.alpha"></AdaptationSet></Period></MPD>';
      expect(DrmPlaylistScanner.isMpdDrmProtected(manifest), isTrue);
    });

    test('a clean manifest with none of the markers is not DRM', () {
      const manifest = '<MPD><Period><AdaptationSet><Representation bandwidth="500000"/></AdaptationSet></Period></MPD>';
      expect(DrmPlaylistScanner.isMpdDrmProtected(manifest), isFalse);
    });

    // Guard-can-fail evidence (verified, see report): temporarily removing
    // the `lower.contains('cenc:pssh')` check made the "bare cenc:pssh
    // box" test above fail (came back `false` instead of `true`).
  });
}
