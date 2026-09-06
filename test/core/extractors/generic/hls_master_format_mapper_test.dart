import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/browser_capture/format_capabilities.dart';
import 'package:mida/core/extractors/format_selector.dart';
import 'package:mida/core/extractors/generic/hls_master_format_mapper.dart';
import 'package:mida/core/extractors/generic/hls_playlist_parser.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/features/download/services/download_service_io.dart';

/// Phase 6 (`docs/plan-phase6-av-pairing.md`, Lane P, P2). Reproduces the
/// pinterest/ted shape: an HLS master whose variants reference a
/// `#EXT-X-MEDIA:TYPE=AUDIO` group carrying its own `URI` (a real,
/// separately-fetchable alternate-audio rendition) - the pre-phase-6
/// mapping treated every such variant as a single muxed format, which
/// ffmpeg then remuxed into a video-only file that failed the post-download
/// probe with "Output is missing its audio track".
void main() {
  group('HlsMasterFormatMapper.formatsFor - split-audio master (pinterest/ted shape)', () {
    const masterUrl = 'https://cdn.example.com/streams/master.m3u8';
    const playlist = '''
#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud1",NAME="main",DEFAULT=YES,URI="audio/en.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,CODECS="avc1.42c01e,mp4a.40.2",AUDIO="aud1"
video_360p.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720,CODECS="avc1.4d401f,mp4a.40.2",AUDIO="aud1"
video_720p.m3u8
''';

    test('emits one video-only format per sibling variant, plus exactly one audio-only format for the shared group',
        () {
      final formats = HlsMasterFormatMapper.formatsFor(masterUrl, playlist);

      final videoOnly = formats.where((f) => f.isVideoOnly).toList();
      final audioOnly = formats.where((f) => f.isAudioOnly).toList();
      expect(videoOnly, hasLength(2), reason: 'both sibling variants, video-only');
      expect(audioOnly, hasLength(1), reason: 'the shared audio group is only fetched/emitted once, not once per '
          'variant that references it');

      expect(videoOnly[0].height, 360);
      expect(videoOnly[0].videoCodec, 'avc1.42c01e');
      expect(videoOnly[1].height, 720);
      expect(videoOnly[1].videoCodec, 'avc1.4d401f');
      expect(audioOnly.single.url, 'https://cdn.example.com/streams/audio/en.m3u8');
      expect(audioOnly.single.audioCodec, 'mp4a.40.2');
      expect(audioOnly.single.id, '$masterUrl#audio:aud1:0');

      // No format is left as an unresolved "muxed" guess: every one of them
      // came from a decisive signal (CODECS + the audio-group split), not
      // the safe-default fallback.
      expect(formats.every((f) => !f.capabilitiesUnknown), isTrue);

      // Round 2 P-R2 (Codex#17, Gadfly#5): both halves of the pairing carry
      // the shared group id, and the audio-only rendition carries a
      // preference FormatSelector can sort on.
      for (final video in videoOnly) {
        expect(video.audioGroupId, 'aud1');
      }
      expect(audioOnly.single.audioGroupId, 'aud1');
      expect(audioOnly.single.audioPreference, 0, reason: 'DEFAULT=YES rendition');
    });

    test('FormatSelector picks a strict adaptive pair from the mapped formats (not a broken "muxed" candidate)', () {
      final formats = HlsMasterFormatMapper.formatsFor(masterUrl, playlist);
      final info = MediaInfo(id: 'v', title: 'x', sourceUrl: Uri.parse('https://example.com'), formats: formats);

      const selector = FormatSelector();
      final selected = selector.select(
        info,
        DownloadType.video,
        const DownloadOptions(videoQuality: VideoQuality.best, videoFormat: VideoFormat.mp4),
      );

      expect(selected.isAdaptivePair, isTrue);
      expect(selected.video!.height, 720, reason: 'best (tallest) video-only rendition');
      expect(selected.audio!.isAudioOnly, isTrue);
      expect(selected.videoNeedsTranscode, isFalse, reason: 'avc1 + mp4a natively fit mp4 - a strict pair, not a '
          'transcode-flagged loose one');
      expect(selected.audioNeedsTranscode, isFalse);
    });

    test('guard-can-fail: with the audio group ignored (pre-phase-6 shape - every variant treated as its own muxed '
        'format via FormatCapabilities.fromHlsCodecs alone, no rendition-group awareness), the same variants would '
        'have come back muxed (hasVideo && hasAudio) instead of video-only + a separate audio-only format', () {
      // Simulates the pre-phase-6 code path directly (no HlsMasterFormatMapper
      // involved at all): the only capability signal it had access to was
      // FormatCapabilities.fromHlsCodecs on that one variant's own CODECS
      // string, which lists BOTH an avc1 and an mp4a entry - so it always
      // resolved to muxed, never noticing the AUDIO="aud1" group reference.
      const codecs = 'avc1.4d401f,mp4a.40.2';
      final preFix = FormatCapabilities.fromHlsCodecs(codecs);
      expect(preFix.hasVideo, isTrue);
      expect(preFix.hasAudio, isTrue, reason: 'pre-fix: this variant reads as muxed, which is exactly the bug - '
          'ffmpeg then remuxed the video-only stream this URL actually is, and the post-download probe rejected it '
          'as "missing its audio track"');

      // The fixed mapper, given the identical variant, does not make that
      // mistake - the difference IS the fix.
      final formats = HlsMasterFormatMapper.formatsFor(masterUrl, playlist);
      final video720 = formats.singleWhere((f) => f.height == 720);
      expect(video720.isMuxed, isFalse);
      expect(video720.isVideoOnly, isTrue);
    });
  });

  group('HlsMasterFormatMapper.formatsFor - no audio group (unchanged pre-phase-6 behavior)', () {
    test('a variant with CODECS but no AUDIO attribute keeps its CODECS-derived capabilities', () {
      const masterUrl = 'https://example.com/master.m3u8';
      const playlist = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=1280x720,CODECS="avc1.4d401f,mp4a.40.2"
video.m3u8
''';
      final formats = HlsMasterFormatMapper.formatsFor(masterUrl, playlist);
      expect(formats, hasLength(1));
      expect(formats.single.isMuxed, isTrue);
      expect(formats.single.capabilitiesUnknown, isFalse);
    });

    test('a variant with no CODECS at all falls back to defaultCaps when given, else muxed, and is flagged '
        'capabilitiesUnknown', () {
      const masterUrl = 'https://example.com/master.m3u8';
      const playlist = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=1280x720
video.m3u8
''';
      final withoutDefault = HlsMasterFormatMapper.formatsFor(masterUrl, playlist);
      expect(withoutDefault.single.isMuxed, isTrue);
      expect(withoutDefault.single.capabilitiesUnknown, isTrue);

      final withDefault = HlsMasterFormatMapper.formatsFor(
        masterUrl,
        playlist,
        defaultCaps: FormatCapabilities.audioOnly,
      );
      expect(withDefault.single.isAudioOnly, isTrue);
      expect(withDefault.single.capabilitiesUnknown, isTrue);
    });

    test('a non-master playlist (no #EXT-X-STREAM-INF) returns an empty list', () {
      final formats = HlsMasterFormatMapper.formatsFor(
        'https://example.com/media.m3u8',
        '#EXTM3U\n#EXTINF:10.0,\nseg0.ts\n',
      );
      expect(formats, isEmpty);
    });
  });

  group('HlsMasterFormatMapper.formatsFor - orders a group\'s renditions by DEFAULT/AUTOSELECT preference', () {
    const masterUrl = 'https://example.com/master.m3u8';

    test('DEFAULT=YES rendition is emitted first (n=0) even when listed last in the playlist', () {
      const playlist = '''
#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud1",NAME="commentary",LANGUAGE="en",URI="audio/commentary.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud1",NAME="main",LANGUAGE="en",DEFAULT=YES,URI="audio/main.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=1280x720,CODECS="avc1.4d401f,mp4a.40.2",AUDIO="aud1"
video.m3u8
''';
      final formats = HlsMasterFormatMapper.formatsFor(masterUrl, playlist);
      final audioOnly = formats.where((f) => f.isAudioOnly).toList();
      expect(audioOnly, hasLength(2));
      expect(audioOnly[0].id, '$masterUrl#audio:aud1:0');
      expect(audioOnly[0].url, endsWith('audio/main.m3u8'), reason: 'DEFAULT=YES outranks playlist order');
      expect(audioOnly[1].url, endsWith('audio/commentary.m3u8'));
      expect(audioOnly[0].audioPreference, 0);
      expect(audioOnly[1].audioPreference, 2);
    });

    test('with no DEFAULT, an AUTOSELECT=YES rendition is emitted first', () {
      const playlist = '''
#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud1",NAME="commentary",LANGUAGE="en",URI="audio/commentary.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud1",NAME="main",LANGUAGE="en",AUTOSELECT=YES,URI="audio/main.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=1280x720,CODECS="avc1.4d401f,mp4a.40.2",AUDIO="aud1"
video.m3u8
''';
      final formats = HlsMasterFormatMapper.formatsFor(masterUrl, playlist);
      final audioOnly = formats.where((f) => f.isAudioOnly).toList();
      expect(audioOnly[0].url, endsWith('audio/main.m3u8'), reason: 'AUTOSELECT=YES outranks plain playlist order '
          'once no rendition claims DEFAULT');
      expect(audioOnly[0].audioPreference, 1);
    });

    test('guard-can-fail: with no DEFAULT/AUTOSELECT preference at all, playlist order is kept unchanged', () {
      const playlist = '''
#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud1",NAME="first",LANGUAGE="en",URI="audio/first.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud1",NAME="second",LANGUAGE="fr",URI="audio/second.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=1280x720,CODECS="avc1.4d401f,mp4a.40.2",AUDIO="aud1"
video.m3u8
''';
      final formats = HlsMasterFormatMapper.formatsFor(masterUrl, playlist);
      final audioOnly = formats.where((f) => f.isAudioOnly).toList();
      expect(audioOnly[0].url, endsWith('audio/first.m3u8'));
      expect(audioOnly[1].url, endsWith('audio/second.m3u8'));
    });
  });

  group('HlsMasterFormatMapper.formatsForVariants - dedupes a group\'s renditions by URI', () {
    test('two renditions in the same group sharing one URI only ever produce one audio-only format', () {
      const masterUrl = 'https://example.com/master.m3u8';
      const playlist = '''
#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud1",NAME="stereo",URI="audio.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud1",NAME="stereo (described)",URI="audio.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=1280x720,CODECS="avc1.4d401f,mp4a.40.2",AUDIO="aud1"
video.m3u8
''';
      final formats = HlsMasterFormatMapper.formatsFor(masterUrl, playlist);
      expect(formats.where((f) => f.isAudioOnly), hasLength(1));
    });
  });

  group('HlsMasterFormatMapper.formatsForVariants - round 3 P-R3-1a (Gadfly C1/C2, blocker): an audio group left '
      'with zero usable renditions marks the variant audioWasStripped, neither muxed nor plainly video-only', () {
    const masterUrl = 'https://example.com/master.m3u8';
    const playlist = '''
#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud1",NAME="main",DEFAULT=YES,URI="audio/en.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=1280x720,CODECS="avc1.4d401f,mp4a.40.2",AUDIO="aud1"
video.m3u8
''';

    test('guard-can-fail: with the group\'s only rendition excluded (DRM), the variant is video-only AND flagged '
        'audioWasStripped - its CODECS claims audio, and reading that claim (round 2) is exactly what let a '
        'silent file ship as success', () {
      final variants = HlsPlaylistParser.parseMasterVariants(playlist, Uri.parse(masterUrl));
      final audioRenditions = HlsPlaylistParser.parseAudioRenditions(playlist, Uri.parse(masterUrl));

      final formats = HlsMasterFormatMapper.formatsForVariants(
        masterUrl,
        variants,
        audioRenditions,
        excludedAudioUris: {'https://example.com/audio/en.m3u8'},
      );

      expect(formats, hasLength(1), reason: 'no audio-only format is emitted for a group with nothing usable left');
      expect(formats.single.isVideoOnly, isTrue);
      expect(formats.single.isMuxed, isFalse, reason: 'guard can fail: round 2 read this variant\'s '
          'CODECS="avc1.4d401f,mp4a.40.2" as muxed here, and this expectation goes red the moment that fallback '
          'comes back - see report for the flip');
      expect(formats.single.audioWasStripped, isTrue, reason: 'guard can fail: dropping the flag makes this format '
          'indistinguishable from an honestly silent source, which FormatSelector would then happily serve');
      expect(formats.single.audioGroupId, 'aud1', reason: 'the group it could not get audio from is kept for '
          'diagnostics and to keep it from pairing with an unrelated group');
    });

    test('a variant whose AUDIO group has no URI-carrying rendition at all is still plain muxed, not stripped '
        '(per the HLS spec that means the audio is muxed into the variant itself)', () {
      const muxedGroupPlaylist = '''
#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud1",NAME="main",DEFAULT=YES
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=1280x720,CODECS="avc1.4d401f,mp4a.40.2",AUDIO="aud1"
video.m3u8
''';
      final variants = HlsPlaylistParser.parseMasterVariants(muxedGroupPlaylist, Uri.parse(masterUrl));
      final audioRenditions = HlsPlaylistParser.parseAudioRenditions(muxedGroupPlaylist, Uri.parse(masterUrl));

      final formats = HlsMasterFormatMapper.formatsForVariants(masterUrl, variants, audioRenditions);

      expect(audioRenditions, isEmpty, reason: 'a rendition with no URI is never returned by the parser');
      expect(formats.single.isMuxed, isTrue);
      expect(formats.single.audioWasStripped, isFalse, reason: 'nothing was stripped: this variant carries its own '
          'audio, and refusing to download it would be a regression for every muxed-group master');
    });

    test('a group with at least one non-excluded rendition still classifies video-only as before', () {
      const twoRenditionPlaylist = '''
#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud1",NAME="drm",URI="audio/drm.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud1",NAME="clean",URI="audio/clean.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=1280x720,CODECS="avc1.4d401f,mp4a.40.2",AUDIO="aud1"
video.m3u8
''';
      final variants = HlsPlaylistParser.parseMasterVariants(twoRenditionPlaylist, Uri.parse(masterUrl));
      final audioRenditions = HlsPlaylistParser.parseAudioRenditions(twoRenditionPlaylist, Uri.parse(masterUrl));

      final formats = HlsMasterFormatMapper.formatsForVariants(
        masterUrl,
        variants,
        audioRenditions,
        excludedAudioUris: {'https://example.com/audio/drm.m3u8'},
      );

      expect(formats.where((f) => f.isVideoOnly), hasLength(1));
      expect(formats.where((f) => f.isAudioOnly), hasLength(1));
      expect(formats.singleWhere((f) => f.isAudioOnly).url, endsWith('audio/clean.m3u8'));
    });
  });

  group('HlsMasterFormatMapper - round 3 P-R3-3 (Gadfly C4): descriptive renditions and ambiguous CODECS', () {
    const masterUrl = 'https://example.com/master.m3u8';

    test('an accessibility (audio-description) rendition ranks last and is emitted with audioPreference 3, even '
        'when it is the group\'s DEFAULT', () {
      const playlist = '''
#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud1",NAME="described",DEFAULT=YES,CHARACTERISTICS="public.accessibility.describes-video",URI="audio/ad.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud1",NAME="main",URI="audio/main.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=1280x720,CODECS="avc1.4d401f,mp4a.40.2",AUDIO="aud1"
video.m3u8
''';
      final formats = HlsMasterFormatMapper.formatsFor(masterUrl, playlist);
      final audioOnly = formats.where((f) => f.isAudioOnly).toList();

      expect(audioOnly.map((f) => f.url).toList(), [
        'https://example.com/audio/main.m3u8',
        'https://example.com/audio/ad.m3u8',
      ], reason: 'guard can fail: without the CHARACTERISTICS check the DEFAULT=YES description track leads, and a '
          'viewer asking for this video gets narration over it');
      expect(audioOnly.map((f) => f.audioPreference).toList(), [2, 3]);
    });

    test('a FORCED rendition is deprioritized the same way (partial track by construction)', () {
      const playlist = '''
#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud1",NAME="forced",DEFAULT=YES,FORCED=YES,URI="audio/forced.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud1",NAME="main",AUTOSELECT=YES,URI="audio/main.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=1280x720,CODECS="avc1.4d401f,mp4a.40.2",AUDIO="aud1"
video.m3u8
''';
      final audioOnly = HlsMasterFormatMapper.formatsFor(masterUrl, playlist).where((f) => f.isAudioOnly).toList();
      expect(audioOnly.map((f) => f.audioPreference).toList(), [1, 3]);
      expect(audioOnly.first.url, endsWith('audio/main.m3u8'));
    });

    test('audioCodec is only inferred from a variant naming exactly one audio fourcc; two groups worth of codecs '
        'leaves it null rather than stamping the wrong one on', () {
      const twoGroupPlaylist = '''
#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac",NAME="stereo",URI="audio/aac.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="atmos",NAME="atmos",URI="audio/ec3.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=1280x720,CODECS="avc1.4d401f,mp4a.40.2,ec-3",AUDIO="atmos"
video.m3u8
''';
      final audioOnly =
          HlsMasterFormatMapper.formatsFor(masterUrl, twoGroupPlaylist).where((f) => f.isAudioOnly).toList();
      expect(audioOnly, hasLength(1));
      expect(audioOnly.single.audioCodec, isNull, reason: 'guard can fail: taking the FIRST audio fourcc (round 2) '
          'labels this ec-3 rendition mp4a, and the downloader then applies an AAC-only bitstream filter to it');
    });

    test('a variant naming exactly one audio fourcc still labels its group\'s rendition', () {
      const playlist = '''
#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud1",NAME="main",URI="audio/main.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=1280x720,CODECS="avc1.4d401f,mp4a.40.2",AUDIO="aud1"
video.m3u8
''';
      final audioOnly = HlsMasterFormatMapper.formatsFor(masterUrl, playlist).where((f) => f.isAudioOnly).toList();
      expect(audioOnly.single.audioCodec, 'mp4a.40.2');
    });
  });
}
