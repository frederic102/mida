import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/browser_capture/format_capabilities.dart';

void main() {
  group('FormatCapabilities.fromMimeType', () {
    test('audio/* is audio-only', () {
      final caps = FormatCapabilities.fromMimeType('audio/mp4');
      expect(caps.hasVideo, isFalse);
      expect(caps.hasAudio, isTrue);
    });

    test('video/* assumes muxed', () {
      final caps = FormatCapabilities.fromMimeType('video/mp4');
      expect(caps.hasVideo, isTrue);
      expect(caps.hasAudio, isTrue);
    });

    test('null mimeType assumes muxed', () {
      final caps = FormatCapabilities.fromMimeType(null);
      expect(caps.hasVideo, isTrue);
      expect(caps.hasAudio, isTrue);
    });
  });

  group('FormatCapabilities.fromHlsCodecs', () {
    test('video + audio codecs both present', () {
      final caps = FormatCapabilities.fromHlsCodecs('avc1.4d401f,mp4a.40.2');
      expect(caps.hasVideo, isTrue);
      expect(caps.hasAudio, isTrue);
    });

    test('video-only codecs (no audio codec listed) is video-only', () {
      final caps = FormatCapabilities.fromHlsCodecs('avc1.64001f');
      expect(caps.hasVideo, isTrue);
      expect(caps.hasAudio, isFalse);
    });

    test('audio-only codecs (no video codec listed) is audio-only', () {
      final caps = FormatCapabilities.fromHlsCodecs('mp4a.40.2');
      expect(caps.hasVideo, isFalse);
      expect(caps.hasAudio, isTrue);
    });

    test('hevc/opus is recognized', () {
      final caps = FormatCapabilities.fromHlsCodecs('hvc1.1.6.L93.90,opus');
      expect(caps.hasVideo, isTrue);
      expect(caps.hasAudio, isTrue);
    });

    test('null/empty attribute assumes muxed', () {
      expect(FormatCapabilities.fromHlsCodecs(null).hasAudio, isTrue);
      expect(FormatCapabilities.fromHlsCodecs('').hasVideo, isTrue);
    });

    test('an unrecognized codec fourcc falls back to muxed rather than "neither"', () {
      final caps = FormatCapabilities.fromHlsCodecs('stpp.ttml.im1t'); // a subtitle codec, e.g.
      expect(caps.hasVideo, isTrue);
      expect(caps.hasAudio, isTrue);
    });

    test('guard can fail: video-only and audio-only must not both come back muxed', () {
      // Proves the two "single codec family" tests above are actually
      // distinguishing, not both silently hitting the muxed fallback.
      final videoOnly = FormatCapabilities.fromHlsCodecs('avc1.64001f');
      final audioOnly = FormatCapabilities.fromHlsCodecs('mp4a.40.2');
      expect(videoOnly.hasAudio, isNot(equals(audioOnly.hasAudio)));
    });
  });
}
