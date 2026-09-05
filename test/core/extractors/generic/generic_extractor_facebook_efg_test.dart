import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/format_selector.dart';
import 'package:mida/core/extractors/generic/generic_extractor.dart';
import 'package:mida/features/download/services/download_service_io.dart';

import 'generic_test_support.dart';

/// Real-download gate regression: `https://www.facebook.com/NatGeoAnimals/
/// videos/reindeer-national-geographic/371360365972647/` resolved 6
/// formats and every single one failed post-download with "Output is
/// missing its audio track", because Facebook's DASH renditions are
/// separate video-only/audio-only flat `.mp4` URLs (distinguished only by
/// an `efg` query param) that this extractor previously assumed were all
/// ordinary muxed files. This fixture reproduces that shape with two
/// facebook-style URLs (one video-only, one audio-only tag) discovered
/// via an inline JSON blob (`__NEXT_DATA__`-style `<script
/// type="application/json">`), the same discovery path Facebook's own
/// page structure would go through.
String _efgQueryValue(String vencodeTag) {
  final json = jsonEncode({'vencode_tag': vencodeTag});
  return base64Url.encode(utf8.encode(json)).replaceAll('=', '');
}

void main() {
  group('GenericExtractor: Facebook-style efg-tagged DASH renditions', () {
    late FakePageServer server;

    setUp(() async {
      server = await FakePageServer.start();
    });

    tearDown(() async {
      await server.close();
    });

    test(
      'a video-only and an audio-only rendition (distinguished only by their efg query param) resolve '
      'with correct hasVideo/hasAudio, and FormatSelector pairs them into an adaptive video+audio download '
      '(not a broken "muxed" pick that fails ffprobe verification)',
      () async {
        final videoUrl = 'https://video.xx.fbcdn.net/v/clip.mp4'
            '?efg=${_efgQueryValue('dash_lat_LR_gen2_720p')}&oh=abc1&oe=def1';
        final audioUrl = 'https://video.xx.fbcdn.net/v/clip.mp4'
            '?efg=${_efgQueryValue('dash_ln_heaac_vbr3_audio')}&oh=abc2&oe=def2';

        server.body = '''
          <html><head><title>Reindeer | National Geographic</title></head>
          <body>
            <script type="application/json">
              {"sources": [
                {"url": "$videoUrl", "width": 1280, "height": 720},
                {"url": "$audioUrl", "bitrate": 128000}
              ]}
            </script>
          </body></html>
        ''';

        final extractor = GenericExtractor(allowPrivateHosts: true);
        final info = await extractor.extract(server.urlFor('/NatGeoAnimals/videos/reindeer/1'));

        expect(info.formats, hasLength(2));

        final video = info.formats.singleWhere((f) => f.url == videoUrl);
        expect(video.isVideoOnly, isTrue, reason: 'the gen2_720p rendition must not be assumed muxed');
        expect(video.hasAudio, isFalse);
        expect(video.capabilitiesUnknown, isFalse);

        final audio = info.formats.singleWhere((f) => f.url == audioUrl);
        expect(audio.isAudioOnly, isTrue, reason: 'the heaac_vbr3_audio rendition must not be assumed muxed');
        expect(audio.hasVideo, isFalse);
        expect(audio.capabilitiesUnknown, isFalse);

        // The real end-to-end proof: FormatSelector (unmodified) already
        // knows how to pair a video-only + audio-only format, but only
        // once each is labeled correctly - this is what "emit the pair so
        // FormatSelector merges" means in practice.
        const selector = FormatSelector();
        final selected = selector.select(
          info,
          DownloadType.video,
          const DownloadOptions(videoQuality: VideoQuality.best, videoFormat: VideoFormat.mp4),
        );
        expect(selected.isAdaptivePair, isTrue);
        expect(selected.video!.url, videoUrl);
        expect(selected.audio!.url, audioUrl);
      },
    );

    // Guard-can-fail evidence (verified, see report): temporarily
    // hardcoding `hasAudio: true` unconditionally in `FormatExpander
    // .formatFor` (the pre-fix behavior) made this test fail: both
    // renditions came back `isMuxed: true` instead of one video-only and
    // one audio-only, `capabilitiesUnknown` was never set, and
    // `FormatSelector.select` returned a single muxed pick (the
    // video-only rendition, since it ranks first by height) instead of
    // an adaptive pair - reproducing the live "Output is missing its
    // audio track" failure exactly. Reverted immediately after
    // confirming the failure.
  });
}
