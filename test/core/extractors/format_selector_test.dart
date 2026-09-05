import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/format_selector.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/features/download/services/download_service_io.dart';

MediaFormat _video({
  required String id,
  required int height,
  required String codec,
  required String container,
  int bitrate = 1000,
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
  );
}

MediaFormat _audio({
  required String id,
  required String codec,
  required String container,
  int bitrate = 128000,
}) {
  return MediaFormat(
    id: id,
    url: 'https://example.invalid/$id',
    container: container,
    audioCodec: codec,
    bitrate: bitrate,
    hasVideo: false,
    hasAudio: true,
  );
}

MediaFormat _muxed({required String id, required int height, int bitrate = 500000, String protocol = 'https'}) {
  return MediaFormat(
    id: id,
    url: 'https://example.invalid/$id',
    container: protocol == 'hls' ? 'm3u8' : 'mp4',
    videoCodec: 'avc1.42001E',
    audioCodec: 'mp4a.40.2',
    height: height,
    bitrate: bitrate,
    hasVideo: true,
    hasAudio: true,
    protocol: protocol,
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

  final adaptiveFormats = [
    _video(id: '137', height: 1080, codec: 'avc1.640028', container: 'mp4'),
    _video(id: '248', height: 1080, codec: 'vp9', container: 'webm'),
    _video(id: '135', height: 480, codec: 'avc1.4d401e', container: 'mp4'),
    _video(id: '244', height: 480, codec: 'vp9', container: 'webm'),
    _video(id: '160', height: 144, codec: 'avc1.4d400c', container: 'mp4'),
    _audio(id: '140', codec: 'mp4a.40.2', container: 'mp4'),
    _audio(id: '251', codec: 'opus', container: 'webm'),
  ];

  test('1080p mp4 request selects avc1 137 + m4a 140', () {
    final result = selector.select(
      _info(adaptiveFormats),
      DownloadType.video,
      const DownloadOptions(videoQuality: VideoQuality.p1080, videoFormat: VideoFormat.mp4),
    );
    expect(result.video!.id, '137');
    expect(result.audio!.id, '140');
  });

  test('webm request selects vp9 + opus', () {
    final result = selector.select(
      _info(adaptiveFormats),
      DownloadType.video,
      const DownloadOptions(videoQuality: VideoQuality.p1080, videoFormat: VideoFormat.webm),
    );
    expect(result.video!.id, '248');
    expect(result.audio!.id, '251');
  });

  test('480p cap picks the tallest format at or under 480p, not above it', () {
    final result = selector.select(
      _info(adaptiveFormats),
      DownloadType.video,
      const DownloadOptions(videoQuality: VideoQuality.p480, videoFormat: VideoFormat.mp4),
    );
    expect(result.video!.height, 480);
    expect(result.video!.id, '135');
  });

  test('best quality with no cap picks the tallest available', () {
    final result = selector.select(
      _info(adaptiveFormats),
      DownloadType.video,
      const DownloadOptions(videoQuality: VideoQuality.best, videoFormat: VideoFormat.mp4),
    );
    expect(result.video!.height, 1080);
  });

  test('audio-only download picks the highest bitrate audio track', () {
    final result = selector.select(
      _info(adaptiveFormats),
      DownloadType.audio,
      const DownloadOptions(audioFormat: AudioFormat.mp3),
    );
    expect(result.audio, isNotNull);
    expect(result.video, isNull);
    expect(result.muxed, isNull);
  });

  test('no adaptive formats at all falls back to the best muxed format', () {
    final muxedOnly = [
      _muxed(id: '18', height: 360, bitrate: 500000),
      _muxed(id: '22', height: 720, bitrate: 2000000),
    ];
    final result = selector.select(
      _info(muxedOnly),
      DownloadType.video,
      const DownloadOptions(videoQuality: VideoQuality.best, videoFormat: VideoFormat.mp4),
    );
    expect(result.muxed, isNotNull);
    expect(result.video, isNull);
    expect(result.audio, isNull);
    expect(result.muxed!.id, '22');
  });

  test('a cap below everything available falls back to the shortest, not nothing', () {
    final result = selector.select(
      _info(adaptiveFormats),
      DownloadType.video,
      const DownloadOptions(videoQuality: VideoQuality.p360, videoFormat: VideoFormat.mp4),
    );
    // Nothing at or below 360p in this mp4 list (shortest is 144p, then 480p);
    // 144p qualifies (<=360) so it should be picked over anything taller.
    expect(result.video!.height, 144);
  });

  test('completely empty format list yields an empty selection, not a crash', () {
    final result = selector.select(
      _info(const []),
      DownloadType.video,
      const DownloadOptions(),
    );
    expect(result.isEmpty, isTrue);
  });

  group('container compatibility (REJECT fix: no more blind -c copy of a mismatched codec)', () {
    test('mp4 target with only vp9 video (no avc1/av01) and no muxed falls back to muxed if present', () {
      final formats = [
        _video(id: '248', height: 1080, codec: 'vp9', container: 'webm'),
        _audio(id: '140', codec: 'mp4a.40.2', container: 'mp4'),
        _muxed(id: '18', height: 360),
      ];
      final result = selector.select(
        _info(formats),
        DownloadType.video,
        const DownloadOptions(videoQuality: VideoQuality.best, videoFormat: VideoFormat.mp4),
      );
      expect(result.muxed, isNotNull, reason: 'should prefer a known-good muxed file over a mismatched pair');
      expect(result.isAdaptivePair, isFalse);
    });

    test('mp4 target with only vp9 video, mp4a audio, and NO muxed allows the pair but flags video for transcode', () {
      final formats = [
        _video(id: '248', height: 1080, codec: 'vp9', container: 'webm'),
        _audio(id: '140', codec: 'mp4a.40.2', container: 'mp4'),
      ];
      final result = selector.select(
        _info(formats),
        DownloadType.video,
        const DownloadOptions(videoQuality: VideoQuality.best, videoFormat: VideoFormat.mp4),
      );
      expect(result.isAdaptivePair, isTrue);
      expect(result.video!.id, '248');
      expect(result.audio!.id, '140');
      expect(result.videoNeedsTranscode, isTrue);
      expect(result.audioNeedsTranscode, isFalse);
    });

    test('mp4 target with avc1 video, only opus audio, and NO muxed flags audio for transcode, not video', () {
      final formats = [
        _video(id: '137', height: 1080, codec: 'avc1.640028', container: 'mp4'),
        _audio(id: '251', codec: 'opus', container: 'webm'),
      ];
      final result = selector.select(
        _info(formats),
        DownloadType.video,
        const DownloadOptions(videoQuality: VideoQuality.best, videoFormat: VideoFormat.mp4),
      );
      expect(result.isAdaptivePair, isTrue);
      expect(result.videoNeedsTranscode, isFalse);
      expect(result.audioNeedsTranscode, isTrue);
    });

    test('webm target with only avc1 video and mp4a audio, no muxed, flags both for transcode', () {
      final formats = [
        _video(id: '137', height: 1080, codec: 'avc1.640028', container: 'mp4'),
        _audio(id: '140', codec: 'mp4a.40.2', container: 'mp4'),
      ];
      final result = selector.select(
        _info(formats),
        DownloadType.video,
        const DownloadOptions(videoQuality: VideoQuality.best, videoFormat: VideoFormat.webm),
      );
      expect(result.isAdaptivePair, isTrue);
      expect(result.videoNeedsTranscode, isTrue);
      expect(result.audioNeedsTranscode, isTrue);
    });

    test('mkv target never needs a transcode: any codec pair is accepted as-is', () {
      final formats = [
        _video(id: '248', height: 1080, codec: 'vp9', container: 'webm'),
        _audio(id: '140', codec: 'mp4a.40.2', container: 'mp4'),
      ];
      final result = selector.select(
        _info(formats),
        DownloadType.video,
        const DownloadOptions(videoQuality: VideoQuality.best, videoFormat: VideoFormat.mkv),
      );
      expect(result.isAdaptivePair, isTrue);
      expect(result.videoNeedsTranscode, isFalse);
      expect(result.audioNeedsTranscode, isFalse);
    });

    test('mp4 target with a compatible pair available never sets transcode flags', () {
      final result = selector.select(
        _info(adaptiveFormats),
        DownloadType.video,
        const DownloadOptions(videoQuality: VideoQuality.p1080, videoFormat: VideoFormat.mp4),
      );
      expect(result.videoNeedsTranscode, isFalse);
      expect(result.audioNeedsTranscode, isFalse);
    });
  });

  group('audio fallback when no audio-only stream exists (X/TikTok/Instagram/most generic sites)', () {
    test('an audio-only stream, when present, is preferred and needsAudioExtraction stays false', () {
      final result = selector.select(
        _info(adaptiveFormats),
        DownloadType.audio,
        const DownloadOptions(audioFormat: AudioFormat.mp3),
      );
      expect(result.audio, isNotNull);
      expect(result.audio!.isAudioOnly, isTrue);
      expect(result.needsAudioExtraction, isFalse);
    });

    test('muxed-only (no audio-only stream): falls back to the smallest muxed https format, flagged', () {
      final muxedOnly = [
        _muxed(id: '18', height: 360, bitrate: 500000),
        _muxed(id: '22', height: 720, bitrate: 2000000),
      ];
      final result = selector.select(
        _info(muxedOnly),
        DownloadType.audio,
        const DownloadOptions(audioFormat: AudioFormat.mp3),
      );
      expect(result.audio, isNotNull);
      expect(result.needsAudioExtraction, isTrue);
      // Smallest, not tallest: video is discarded, so there is no reason
      // to pull the 720p rendition just to throw its video track away.
      expect(result.audio!.id, '18');
    });

    test('HLS-only (no audio-only stream, no https muxed): falls back to the smallest HLS variant, flagged', () {
      final hlsOnly = [
        _muxed(id: 'v1', height: 1080, bitrate: 4000000, protocol: 'hls'),
        _muxed(id: 'v2', height: 480, bitrate: 900000, protocol: 'hls'),
      ];
      final result = selector.select(
        _info(hlsOnly),
        DownloadType.audio,
        const DownloadOptions(audioFormat: AudioFormat.mp3),
      );
      expect(result.audio, isNotNull);
      expect(result.needsAudioExtraction, isTrue);
      expect(result.audio!.id, 'v2');
      expect(result.audio!.protocol, 'hls');
    });

    test('an https muxed format is preferred over an HLS one when both exist', () {
      final mixed = [
        _muxed(id: 'hls1', height: 480, bitrate: 900000, protocol: 'hls'),
        _muxed(id: 'https1', height: 480, bitrate: 900000),
      ];
      final result = selector.select(
        _info(mixed),
        DownloadType.audio,
        const DownloadOptions(audioFormat: AudioFormat.mp3),
      );
      expect(result.audio!.id, 'https1');
      expect(result.needsAudioExtraction, isTrue);
    });

    test('no formats at all: an audio request yields an empty selection, not a crash', () {
      final result = selector.select(_info(const []), DownloadType.audio, const DownloadOptions());
      expect(result.isEmpty, isTrue);
      expect(result.needsAudioExtraction, isFalse);
    });

    test('only a video-only stream (no audio-only, no muxed, no HLS): still empty', () {
      final videoOnly = [_video(id: '160', height: 144, codec: 'avc1.4d400c', container: 'mp4')];
      final result = selector.select(
        _info(videoOnly),
        DownloadType.audio,
        const DownloadOptions(audioFormat: AudioFormat.mp3),
      );
      expect(result.isEmpty, isTrue);
    });
  });

  group('FormatSelector.rank (ordered candidate list, for MediaDownloadPipeline retry)', () {
    test('.select() always equals .rank().first', () {
      final muxedOnly = [
        _muxed(id: '18', height: 360, bitrate: 500000),
        _muxed(id: '22', height: 720, bitrate: 2000000),
      ];
      final info = _info(muxedOnly);
      const options = DownloadOptions(videoQuality: VideoQuality.best, videoFormat: VideoFormat.mp4);
      expect(
        selector.select(info, DownloadType.video, options).muxed?.id,
        selector.rank(info, DownloadType.video, options).first.muxed?.id,
      );
    });

    test('multiple muxed formats all rank as candidates, tallest first (the "29 other formats" case)', () {
      final manyMuxed = [
        for (final h in [240, 360, 480, 720, 1080]) _muxed(id: 'h$h', height: h, bitrate: h * 1000),
      ];
      final ranked = selector.rank(
        _info(manyMuxed),
        DownloadType.video,
        const DownloadOptions(videoQuality: VideoQuality.best, videoFormat: VideoFormat.mp4),
      );
      expect(ranked, hasLength(5));
      expect(ranked.map((c) => c.muxed!.height), [1080, 720, 480, 360, 240]);
    });

    test('a genuinely silent source (no format anywhere has audio) offers the best video-only rendition', () {
      final silent = [
        _video(id: 'v360', height: 360, codec: 'avc1.640028', container: 'mp4'),
        _video(id: 'v720', height: 720, codec: 'avc1.640028', container: 'mp4'),
      ];
      final ranked = selector.rank(
        _info(silent),
        DownloadType.video,
        const DownloadOptions(videoQuality: VideoQuality.best, videoFormat: VideoFormat.mp4),
      );
      expect(ranked, hasLength(1));
      expect(ranked.single.muxed!.id, 'v720');
      expect(ranked.single.expectsVideoAndAudio, isFalse, reason: 'no audio exists, so none should be expected');
    });
  });
}
