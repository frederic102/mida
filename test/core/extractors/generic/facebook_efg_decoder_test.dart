import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/generic/facebook_efg_decoder.dart';

/// Builds a Facebook-style `?efg=<base64 JSON>` query string the way a real
/// DASH rendition URL carries it: base64url-encoded, padding stripped (the
/// shape actually seen live - Facebook's own URLs never carry the trailing
/// `=`).
String _efgUrl(String vencodeTag) {
  final json = jsonEncode({'vencode_tag': vencodeTag});
  final encoded = base64Url.encode(utf8.encode(json)).replaceAll('=', '');
  return 'https://video.xx.fbcdn.net/v/clip.mp4?efg=$encoded&oh=abc&oe=def';
}

void main() {
  group('FacebookEfgDecoder.capabilitiesFromUrl', () {
    test('an audio-only vencode_tag (dash_ln_heaac_vbr3_audio) is audio-only', () {
      final capabilities = FacebookEfgDecoder.capabilitiesFromUrl(_efgUrl('dash_ln_heaac_vbr3_audio'));

      expect(capabilities, isNotNull);
      expect(capabilities!.hasVideo, isFalse);
      expect(capabilities.hasAudio, isTrue);
    });

    test('a video-only vencode_tag (dash_lat_LR_gen2_720p) is video-only', () {
      final capabilities = FacebookEfgDecoder.capabilitiesFromUrl(_efgUrl('dash_lat_LR_gen2_720p'));

      expect(capabilities, isNotNull);
      expect(capabilities!.hasVideo, isTrue);
      expect(capabilities.hasAudio, isFalse);
    });

    test('a vencode_tag naming neither audio nor a gen/video/resolution marker yields null (unknown, not guessed)',
        () {
      final capabilities = FacebookEfgDecoder.capabilitiesFromUrl(_efgUrl('dash_something_unrecognized'));

      expect(capabilities, isNull);
    });

    test('a URL with no efg param at all returns null', () {
      expect(FacebookEfgDecoder.capabilitiesFromUrl('https://video.xx.fbcdn.net/v/clip.mp4?oh=abc'), isNull);
    });

    test('an efg param that is not valid base64/JSON returns null instead of throwing', () {
      expect(
        () => FacebookEfgDecoder.capabilitiesFromUrl('https://video.xx.fbcdn.net/v/clip.mp4?efg=not-valid-base64!!!'),
        returnsNormally,
      );
      expect(
        FacebookEfgDecoder.capabilitiesFromUrl('https://video.xx.fbcdn.net/v/clip.mp4?efg=not-valid-base64!!!'),
        isNull,
      );
    });

    test('standard (non-URL-safe) base64 with full padding also decodes', () {
      final json = jsonEncode({'vencode_tag': 'dash_ln_heaac_vbr3_audio'});
      final encoded = base64.encode(utf8.encode(json)); // keeps '=' padding and +/ alphabet
      final url = 'https://video.xx.fbcdn.net/v/clip.mp4?efg=${Uri.encodeQueryComponent(encoded)}';

      final capabilities = FacebookEfgDecoder.capabilitiesFromUrl(url);
      expect(capabilities, isNotNull);
      expect(capabilities!.hasAudio, isTrue);
      expect(capabilities.hasVideo, isFalse);
    });

    // Guard-can-fail evidence (verified, see report): temporarily
    // disabling the `_audioOnlyMarkers.any(tag.contains)` branch in
    // `capabilitiesFromUrl` made both audio-tagged tests above fail
    // (`capabilities` came back `null` instead of audio-only), since
    // "dash_ln_heaac_vbr3_audio" contains neither "gen" nor "video" nor a
    // resolution suffix and so falls through with no other branch to
    // catch it. Reverted immediately after confirming the failure.
  });
}
