import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/format_selector.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/features/download/services/download_service_io.dart';

/// Round 2 (`docs/plan-phase6-av-pairing.md`, Lane P): `FormatSelector`'s
/// pairing/ranking fixes that came out of the AEGIS + Codex review of round
/// 1 - split out of `format_selector_test.dart` purely to stay under this
/// project's 400-line cap, not because these tests exercise a different
/// class.
MediaFormat _video({
  required String id,
  required int height,
  required String codec,
  required String container,
  int bitrate = 1000,
  String? audioGroupId,
}) {
  return MediaFormat(
    id: id,
    url: 'https://example.invalid/$id',
    container: container,
    videoCodec: codec,
    height: height,
    width: height * 16 ~/ 9,
    bitrate: bitrate,
    hasVideo: true,
    hasAudio: false,
    audioGroupId: audioGroupId,
  );
}

MediaFormat _audio({
  required String id,
  required String codec,
  required String container,
  int bitrate = 128000,
  String? audioGroupId,
  int audioPreference = 2,
}) {
  return MediaFormat(
    id: id,
    url: 'https://example.invalid/$id',
    container: container,
    audioCodec: codec,
    bitrate: bitrate,
    hasVideo: false,
    hasAudio: true,
    audioGroupId: audioGroupId,
    audioPreference: audioPreference,
  );
}

MediaFormat _muxed({required String id, required int height, int bitrate = 3000000}) {
  return MediaFormat(
    id: id,
    url: 'https://example.invalid/$id',
    container: 'mp4',
    videoCodec: 'avc1.640028',
    audioCodec: 'mp4a.40.2',
    height: height,
    width: height * 16 ~/ 9,
    bitrate: bitrate,
    hasVideo: true,
    hasAudio: true,
  );
}

MediaInfo _info(List<MediaFormat> formats) {
  return MediaInfo(
    id: 'abc',
    title: 'test',
    sourceUrl: Uri.parse('https://www.youtube.com/watch?v=abc'),
    formats: formats,
  );
}

void main() {
  const selector = FormatSelector();

  group('round 2 P-R2 (Codex#17, Gadfly#5): pairing respects audioGroupId', () {
    test('guard-can-fail: a video-only and audio-only format in DIFFERENT groups never pair, even though the '
        'audio would otherwise be the best bitrate available', () {
      final formats = [
        _video(id: 'vA', height: 1080, codec: 'avc1.640028', container: 'mp4', audioGroupId: 'gA'),
        _audio(id: 'aA', codec: 'mp4a.40.2', container: 'mp4', bitrate: 64000, audioGroupId: 'gA'),
        // Group B's audio is higher bitrate than group A's - if the
        // selector ignored audioGroupId (round 1 behavior), this would win
        // the pairing for vA instead of aA.
        _audio(id: 'aB', codec: 'mp4a.40.2', container: 'mp4', bitrate: 256000, audioGroupId: 'gB'),
      ];
      final ranked = selector.rank(
        _info(formats),
        DownloadType.video,
        const DownloadOptions(videoQuality: VideoQuality.best, videoFormat: VideoFormat.mp4),
      );
      expect(ranked, hasLength(1), reason: 'only one real pair exists (vA+aA) - aB has no matching video at all');
      expect(ranked.single.video!.id, 'vA');
      expect(ranked.single.audio!.id, 'aA');
    });

    test('two independent groups each pair with their own audio, best video (by height) still wins overall', () {
      final formats = [
        _video(id: 'vA', height: 720, codec: 'avc1.640028', container: 'mp4', audioGroupId: 'gA'),
        _audio(id: 'aA', codec: 'mp4a.40.2', container: 'mp4', bitrate: 128000, audioGroupId: 'gA'),
        _video(id: 'vB', height: 1080, codec: 'avc1.640028', container: 'mp4', audioGroupId: 'gB'),
        _audio(id: 'aB', codec: 'mp4a.40.2', container: 'mp4', bitrate: 128000, audioGroupId: 'gB'),
      ];
      final ranked = selector.rank(
        _info(formats),
        DownloadType.video,
        const DownloadOptions(videoQuality: VideoQuality.best, videoFormat: VideoFormat.mp4),
      );
      expect(ranked, hasLength(2));
      expect(ranked.first.video!.id, 'vB', reason: 'tallest video (1080) ranks first');
      expect(ranked.first.audio!.id, 'aB', reason: "must pair with its OWN group's audio, not gA's");
      expect(ranked.last.video!.id, 'vA');
      expect(ranked.last.audio!.id, 'aA');
    });

    test('a plain (no group) video-only/audio-only pair still matches (both null counts as equal)', () {
      final formats = [
        _video(id: 'v1', height: 720, codec: 'avc1.640028', container: 'mp4'),
        _audio(id: 'a1', codec: 'mp4a.40.2', container: 'mp4'),
      ];
      final result = selector.select(
        _info(formats),
        DownloadType.video,
        const DownloadOptions(videoQuality: VideoQuality.best, videoFormat: VideoFormat.mp4),
      );
      expect(result.isAdaptivePair, isTrue);
      expect(result.video!.id, 'v1');
      expect(result.audio!.id, 'a1');
    });
  });

  group('round 2 P-R3 (Codex#1) + round 3 P-R3-2 (Codex#10): rank enumerates multiple pairs, capped at 6', () {
    test('3 video-only x 2 audio-only in one group yields all 6 combinations, audio-major (round-robin over the '
        'videos) order', () {
      final formats = [
        for (final h in [1080, 720, 480])
          _video(id: 'v$h', height: h, codec: 'avc1.640028', container: 'mp4', audioGroupId: 'g1'),
        _audio(id: 'a_best', codec: 'mp4a.40.2', container: 'mp4', bitrate: 128000, audioGroupId: 'g1', audioPreference: 0),
        _audio(id: 'a_worst', codec: 'mp4a.40.2', container: 'mp4', bitrate: 64000, audioGroupId: 'g1', audioPreference: 2),
      ];
      final ranked = selector.rank(
        _info(formats),
        DownloadType.video,
        const DownloadOptions(videoQuality: VideoQuality.best, videoFormat: VideoFormat.mp4),
      );
      expect(ranked, hasLength(6));
      expect(
        ranked.map((c) => '${c.video!.id}+${c.audio!.id}').toList(),
        [
          'v1080+a_best',
          'v720+a_best',
          'v480+a_best',
          'v1080+a_worst',
          'v720+a_worst',
          'v480+a_worst',
        ],
        reason: 'guard can fail: the round 2 video-major order put v1080+a_worst second, spending a retry on the '
            'same (possibly dead) video rendition before any other video was tried at all',
      );
      expect(ranked.first.video!.id, 'v1080', reason: 'the top pick is unchanged by the round-robin');
      expect(ranked.first.audio!.id, 'a_best');
    });

    test('guard-can-fail: more than 6 real combinations are capped at 6, not left unbounded', () {
      final formats = [
        for (final h in [1080, 720, 480, 360])
          _video(id: 'v$h', height: h, codec: 'avc1.640028', container: 'mp4', audioGroupId: 'g1'),
        for (final br in [128000, 64000]) _audio(id: 'a$br', codec: 'mp4a.40.2', container: 'mp4', bitrate: br, audioGroupId: 'g1'),
      ];
      // 4 videos x 2 audios = 8 real combinations available.
      final ranked = selector.rank(
        _info(formats),
        DownloadType.video,
        const DownloadOptions(videoQuality: VideoQuality.best, videoFormat: VideoFormat.mp4),
      );
      expect(ranked, hasLength(6), reason: 'guard can fail: removing the _maxPairsPerTier cap would return 8 here');
      expect(
        ranked.map((c) => '${c.video!.id}+${c.audio!.id}').toList(),
        ['v1080+a128000', 'v720+a128000', 'v480+a128000', 'v360+a128000', 'v1080+a64000', 'v720+a64000'],
        reason: 'round 3 P-R3-2: every video is tried with the best audio before any second-choice audio is, so '
            'the cap now cuts the SECOND audio round rather than cutting v360 out entirely',
      );
    });
  });

  group('round 3 P-R3-2 (Codex#10): muxed candidates are interleaved after 2 pairs (inside the 3-attempt budget), not queued behind all 6', () {
    test('a muxed rendition is reachable within the pipeline\'s 3-attempt budget even when 6 pairs exist', () {
      final formats = [
        for (final h in [1080, 720, 480, 360])
          _video(id: 'v$h', height: h, codec: 'avc1.640028', container: 'mp4', audioGroupId: 'g1'),
        for (final br in [128000, 64000]) _audio(id: 'a$br', codec: 'mp4a.40.2', container: 'mp4', bitrate: br, audioGroupId: 'g1'),
        _muxed(id: 'm720', height: 720),
      ];
      final ranked = selector.rank(
        _info(formats),
        DownloadType.video,
        const DownloadOptions(videoQuality: VideoQuality.best, videoFormat: VideoFormat.mp4),
      );

      expect(ranked.first.isAdaptivePair, isTrue, reason: 'pairs still lead: the top pick does not change');
      final muxedIndex = ranked.indexWhere((c) => c.muxed != null);
      expect(muxedIndex, 2, reason: 'guard can fail: with the round 2 ordering the only muxed rendition sat at '
          'index 6, past every retry the pipeline is willing to spend');
      expect(ranked.where((c) => c.isAdaptivePair), hasLength(6), reason: 'no pair is dropped by the interleave');
    });
  });

  group('round 3 P-R3-1c (Gadfly C1/C2, blocker): the silent-source tier refuses an audioWasStripped format', () {
    MediaFormat strippedVideo({bool audioWasStripped = true}) => MediaFormat(
          id: 'v_stripped',
          url: 'https://example.invalid/v_stripped',
          container: 'm3u8',
          protocol: 'hls',
          videoCodec: 'avc1.640028',
          height: 720,
          width: 1280,
          bitrate: 2000000,
          hasVideo: true,
          hasAudio: false,
          audioGroupId: 'aud1',
          audioWasStripped: audioWasStripped,
        );

    test('guard-can-fail: a video whose audio group was excluded ranks nothing at all, so the download fails '
        'loudly instead of returning a silent file', () {
      final ranked = selector.rank(
        _info([strippedVideo()]),
        DownloadType.video,
        const DownloadOptions(videoQuality: VideoQuality.best, videoFormat: VideoFormat.mp4),
      );
      expect(ranked, isEmpty);
    });

    test('the same format with the flag cleared IS offered - the flag, not the shape, is what this tier keys on', () {
      final ranked = selector.rank(
        _info([strippedVideo(audioWasStripped: false)]),
        DownloadType.video,
        const DownloadOptions(videoQuality: VideoQuality.best, videoFormat: VideoFormat.mp4),
      );
      expect(ranked, hasLength(1), reason: 'an honestly silent source is still downloadable, unchanged');
      expect(ranked.single.muxed!.id, 'v_stripped');
    });
  });

  group('round 3 P-R3-3 (Gadfly C4): audio ranking is index-stable', () {
    test('renditions tying on preference and bitrate keep the order the mapper emitted them in', () {
      final formats = [
        for (final name in ['first', 'second', 'third'])
          _audio(id: 'a_$name', codec: 'mp4a.40.2', container: 'mp4', bitrate: 0, audioGroupId: 'g1'),
      ];
      final ranked = selector.rank(_info(formats), DownloadType.audio, const DownloadOptions(audioFormat: AudioFormat.mp3));
      expect(ranked.map((c) => c.audio!.id).toList(), ['a_first', 'a_second', 'a_third'],
          reason: 'guard can fail: List.sort is not stable in Dart, so without the trailing index comparison the '
              'order of equal-ranked renditions (all bitrate 0, the normal case for an HLS audio group) is '
              'whatever the sort implementation happens to produce');
    });

    test('a forced/accessibility rendition (preference 3) ranks below every ordinary one', () {
      final formats = [
        _audio(id: 'a_described', codec: 'mp4a.40.2', container: 'mp4', bitrate: 256000, audioGroupId: 'g1', audioPreference: 3),
        _audio(id: 'a_main', codec: 'mp4a.40.2', container: 'mp4', bitrate: 64000, audioGroupId: 'g1', audioPreference: 2),
      ];
      final ranked = selector.rank(_info(formats), DownloadType.audio, const DownloadOptions(audioFormat: AudioFormat.mp3));
      expect(ranked.map((c) => c.audio!.id).toList(), ['a_main', 'a_described'],
          reason: 'bitrate must not promote a description track over the real one');
    });
  });

  group('round 2 P-R8 (Gadfly#6b): _rankAudio enumerates every audio-only candidate, not just the best one', () {
    test('3 audio-only candidates all rank as retry candidates, preference then bitrate order', () {
      final formats = [
        _audio(id: 'a_default', codec: 'mp4a.40.2', container: 'mp4', bitrate: 64000, audioPreference: 0),
        _audio(id: 'a_high_bitrate', codec: 'mp4a.40.2', container: 'mp4', bitrate: 256000, audioPreference: 2),
        _audio(id: 'a_low_bitrate', codec: 'mp4a.40.2', container: 'mp4', bitrate: 32000, audioPreference: 2),
      ];
      final ranked = selector.rank(_info(formats), DownloadType.audio, const DownloadOptions(audioFormat: AudioFormat.mp3));
      expect(ranked, hasLength(3), reason: 'guard can fail: picking only the single best audio-only format here '
          'would return length 1, leaving no fallback if the top pick is unreachable/broken');
      expect(ranked.map((c) => c.audio!.id).toList(), ['a_default', 'a_high_bitrate', 'a_low_bitrate']);
    });
  });
}
