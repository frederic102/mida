import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/generic/format_expander.dart';

/// Phase 6 (`docs/plan-phase6-av-pairing.md`, Lane P): `FormatExpander`
/// now runs the HLS master-expansion path through `HlsMasterFormatMapper`
/// (video-only + a paired audio-only format when the master splits audio
/// into its own `#EXT-X-MEDIA` rendition group), and extends its own
/// per-variant DRM scan to that audio rendition's playlist too - not just
/// `#EXT-X-STREAM-INF` variant URLs (independent pre-review item 5).
void main() {
  const masterUrl = 'https://cdn.example.com/master.m3u8';
  const masterBodyTemplate = '''
#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud1",NAME="main",DEFAULT=YES,URI="audio/en.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,CODECS="avc1.42c01e,mp4a.40.2",AUDIO="aud1"
video_360p.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720,CODECS="avc1.4d401f,mp4a.40.2",AUDIO="aud1"
video_720p.m3u8
''';
  const cleanMediaPlaylist = '#EXTM3U\n#EXTINF:6.0,\nseg0.ts\n#EXT-X-ENDLIST\n';
  const drmMediaPlaylist =
      '#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,KEYFORMAT="com.apple.streamingkeydelivery"\n#EXTINF:6.0,\nseg0.ts\n#EXT-X-ENDLIST\n';

  FormatExpander expanderWith(Map<String, String> bodies) {
    return FormatExpander(
      fetchText: (url, {extraHeaders, maxBytes}) async {
        final body = bodies[url.toString()];
        if (body == null) return const FetchedBody(statusCode: 404, body: '');
        return FetchedBody(statusCode: 200, body: body);
      },
    );
  }

  test('a clean split-audio master maps to video-only x2 + one audio-only format via HlsMasterFormatMapper',
      () async {
    final expander = expanderWith({
      masterUrl: masterBodyTemplate,
      'https://cdn.example.com/video_360p.m3u8': cleanMediaPlaylist,
      'https://cdn.example.com/video_720p.m3u8': cleanMediaPlaylist,
      'https://cdn.example.com/audio/en.m3u8': cleanMediaPlaylist,
    });

    final result = await expander.expandFormats(masterUrl, 'm3u8');

    expect(result.drmDetected, isFalse);
    expect(result.formats.where((f) => f.isVideoOnly), hasLength(2));
    expect(result.formats.where((f) => f.isAudioOnly), hasLength(1));
    expect(result.formats.any((f) => f.isMuxed), isFalse, reason: 'the pre-phase-6 bug: this master used to come '
        'back as 2 muxed formats instead of video-only + audio-only');
  });

  test('guard-can-fail: a DRM-protected audio rendition is dropped (no audio-only format emitted), while the clean '
      'video-only variants still come through - proving the DRM scan now actually reaches the audio rendition '
      'playlist, not just #EXT-X-STREAM-INF variant URLs', () async {
    final expander = expanderWith({
      masterUrl: masterBodyTemplate,
      'https://cdn.example.com/video_360p.m3u8': cleanMediaPlaylist,
      'https://cdn.example.com/video_720p.m3u8': cleanMediaPlaylist,
      'https://cdn.example.com/audio/en.m3u8': drmMediaPlaylist,
    });

    final result = await expander.expandFormats(masterUrl, 'm3u8');

    expect(result.drmDetected, isFalse, reason: 'the video variants are clean, so this is not a whole-candidate '
        'DRM rejection');
    expect(result.formats.where((f) => f.isAudioOnly), isEmpty, reason: 'guard can fail: before this fix, the '
        'audio rendition URI was never DRM-checked at all and would have been exposed as a normal downloadable '
        'audio-only format pointing at DRM-protected content');
    // Round 3 P-R3-1(a) (Gadfly round-2 counter 1, Codex #9): this
    // master's ONLY audio rendition for group "aud1" was just DRM-excluded,
    // leaving the group with zero usable audio. Round 2 re-labeled the
    // variants muxed, but a muxed label is only a claim: the pipeline's
    // mismatch correction stripped it back to video-only one attempt
    // later and the selector's silent-source tier then accepted the
    // silent file. The round-3 contract is explicit instead: the variants
    // stay video-only AND carry `audioWasStripped: true`, which the
    // selector's silent-source tier refuses, so every candidate is
    // exhausted and the download fails loudly
    // (`AllFormatCandidatesFailedException`) instead of shipping a silent
    // file marked success (see media_download_pipeline_silent_guard_test).
    final stripped = result.formats.where((f) => f.isVideoOnly).toList();
    expect(stripped, hasLength(2), reason: 'both clean variants are still exposed, as video-only');
    expect(stripped.every((f) => f.audioWasStripped), isTrue, reason: 'guard can fail (round 2 regression): '
        'without the audioWasStripped marker the silent-source tier would accept one of these as a silent '
        '"success"');
    expect(result.formats.any((f) => f.isMuxed), isFalse, reason: 'the round-2 muxed fallback is gone: a muxed '
        'label here was a claim the pipeline later disproved and quietly downgraded');
  });
}
