import '../../features/download/services/download_service_io.dart';
import 'media_models.dart';

/// Result of running [FormatSelector.select] against a [MediaInfo]. Either
/// [video] + [audio] are both set (adaptive pair to be merged), or [muxed]
/// is set alone (single file, already has both streams), or everything is
/// null (nothing matched, caller should surface an error).
///
/// [videoNeedsTranscode]/[audioNeedsTranscode] are only ever true together
/// with an adaptive pair: they mean the selector could not find a pair
/// whose codecs natively fit the target container (and no muxed fallback
/// existed either), so it picked the best it could and the merger must
/// transcode that half instead of blindly `-c copy`-ing an incompatible
/// codec into the container.
class SelectedFormats {
  final MediaFormat? video;
  final MediaFormat? audio;
  final MediaFormat? muxed;
  final bool videoNeedsTranscode;
  final bool audioNeedsTranscode;

  /// True only for an audio download whose [audio] format is not actually
  /// audio-only: X, TikTok, Instagram and most generic sites never offer a
  /// dedicated audio-only stream, so [FormatSelector] falls back to the
  /// best muxed (or HLS/DASH) format instead. The pipeline downloads that
  /// format the same way it would for a video request, then runs ffmpeg
  /// `-vn` on it to pull just the audio track out - this flag exists so
  /// callers/tests can tell that fallback happened, not to change how the
  /// pipeline downloads (it already always runs `-vn` for an audio
  /// request, muxed source or not).
  final bool needsAudioExtraction;

  const SelectedFormats({
    this.video,
    this.audio,
    this.muxed,
    this.videoNeedsTranscode = false,
    this.audioNeedsTranscode = false,
    this.needsAudioExtraction = false,
  });

  bool get isEmpty => video == null && audio == null && muxed == null;
  bool get isAdaptivePair => video != null && audio != null;

  /// True when a successful download of this candidate is expected to
  /// contain both a video and an audio stream - used by
  /// `MediaDownloadPipeline`'s post-download sanity probe to decide
  /// whether a missing stream type means the source was mislabeled (e.g.
  /// a video-only DASH rendition that reported itself as muxed) versus
  /// "the source genuinely has no audio" (a muted/silent video, where
  /// [muxed] itself is a video-only [MediaFormat] - see
  /// [FormatSelector._rankVideo]'s silent-source fallback - and there was
  /// never an audio track to be missing). A pure audio candidate
  /// (`needsAudioExtraction` or a real audio-only stream) deliberately
  /// ends up audio-only after ffmpeg's `-vn`, so it is not held to this
  /// expectation either.
  bool get expectsVideoAndAudio {
    if (muxed != null) return muxed!.hasVideo && muxed!.hasAudio;
    return isAdaptivePair;
  }
}

/// Pure selection logic: given the formats a [MediaInfo] offers and the
/// user's [DownloadOptions], ranks every viable candidate best-first. No
/// I/O. [select] (kept for callers that only want the top pick) is just
/// `rank(...).firstOrElse(const SelectedFormats())`.
///
/// Ranking (not just picking one) exists so `MediaDownloadPipeline` can
/// retry with the next candidate when the top pick's actual bytes turn out
/// to be broken (a mislabeled/DRM playlist, a codec ffmpeg cannot merge,
/// ...) instead of failing the whole download outright even though other
/// viable renditions existed.
class FormatSelector {
  const FormatSelector();

  static const _mp4VideoCodecs = ['avc1', 'av01'];
  static const _webmVideoCodecs = ['vp9', 'vp09', 'av01'];

  SelectedFormats select(MediaInfo info, DownloadType type, DownloadOptions options) {
    final ranked = rank(info, type, options);
    return ranked.isEmpty ? const SelectedFormats() : ranked.first;
  }

  /// Best-first candidate list. Tiers are flattened into one list (rather
  /// than gating on "did the previous tier find nothing") so a lower tier
  /// is still available as a retry fallback even when a higher tier's top
  /// pick exists but turns out to be unusable: `.first` always equals what
  /// the old tier-gated `select()` returned, so this is a strict
  /// generalization, not a behavior change for the success path.
  List<SelectedFormats> rank(MediaInfo info, DownloadType type, DownloadOptions options) {
    if (type == DownloadType.audio) {
      return _rankAudio(info.formats, options);
    }
    return _rankVideo(info.formats, options);
  }

  /// Tier 1: a dedicated audio-only stream (YouTube always has one).
  /// Tier 2: every muxed `https` format, smallest first (video is
  /// discarded, so there is no reason to download more of it than
  /// necessary). Tier 3: every muxed HLS/DASH format, smallest first
  /// (also muxed by construction: `GenericExtractor`/
  /// `BrowserCaptureExtractor` never split an HLS/DASH stream into
  /// separate video-only/audio-only formats). Tiers 2 and 3 both flag
  /// [SelectedFormats.needsAudioExtraction].
  List<SelectedFormats> _rankAudio(List<MediaFormat> formats, DownloadOptions options) {
    final candidates = <SelectedFormats>[];

    final audioOnly = _bestAudioOnly(formats, container: options.videoFormat, strict: false);
    if (audioOnly != null) {
      candidates.add(SelectedFormats(audio: audioOnly));
    }

    for (final muxed in _rankSmallestMuxed(formats.where((f) => f.protocol == 'https'))) {
      candidates.add(SelectedFormats(audio: muxed, needsAudioExtraction: true));
    }
    for (final muxed in _rankSmallestMuxed(formats.where((f) => f.protocol != 'https'))) {
      candidates.add(SelectedFormats(audio: muxed, needsAudioExtraction: true));
    }

    return candidates;
  }

  /// Ascending ranking (smallest first) among muxed [formats] - the
  /// opposite ordering from [_rankByHeightThenBitrate], which prefers the
  /// tallest/highest-bitrate for video requests, where quality is the
  /// point; here every extra pixel is bytes wasted on a stream that gets
  /// thrown away.
  List<MediaFormat> _rankSmallestMuxed(Iterable<MediaFormat> formats) {
    final candidates = formats.where((f) => f.isMuxed).toList();
    if (candidates.isEmpty) return const [];

    final withHeight = candidates.where((f) => f.height != null).toList()
      ..sort((a, b) {
        final byHeight = a.height!.compareTo(b.height!);
        return byHeight != 0 ? byHeight : a.bitrate.compareTo(b.bitrate);
      });
    final withoutHeight = candidates.where((f) => f.height == null).toList()
      ..sort((a, b) => a.bitrate.compareTo(b.bitrate));

    return [...withHeight, ...withoutHeight];
  }

  /// Tier 1: a strict adaptive pair (codecs natively fit the target
  /// container). Tier 2: every muxed format, tallest/best-bitrate first
  /// (a pre-muxed file, which the source itself packaged, is a safer
  /// retry than a codec-mismatched merge). Tier 3: a loose adaptive pair
  /// (flagged for transcode), only offered when tiers 1-2 found nothing at
  /// all - unlike the muxed tier, there is only ever one loose pair to
  /// offer, so it is not worth ranking on its own. Tier 4 (silent
  /// source): when nothing above matched *and* the source has no audio
  /// anywhere (a muted video, e.g. a silent Instagram reel - extractors
  /// report `hasAudio: false` honestly rather than lying about it), the
  /// best video-only rendition is offered directly as [SelectedFormats
  /// .muxed]: there is no audio to pair it with, but that does not make
  /// the video undownloadable.
  List<SelectedFormats> _rankVideo(List<MediaFormat> formats, DownloadOptions options) {
    final maxHeight = _heightCap(options.videoQuality);
    final container = options.videoFormat;
    final candidates = <SelectedFormats>[];

    final strictVideo = _bestVideoOnly(formats, maxHeight: maxHeight, container: container, strict: true);
    final strictAudio = _bestAudioOnly(formats, container: container, strict: true);
    if (strictVideo != null && strictAudio != null) {
      candidates.add(SelectedFormats(video: strictVideo, audio: strictAudio));
    }

    for (final muxed in _rankMuxed(formats, maxHeight: maxHeight)) {
      candidates.add(SelectedFormats(muxed: muxed));
    }

    if (candidates.isEmpty) {
      final looseVideo = _bestVideoOnly(formats, maxHeight: maxHeight, container: container, strict: false);
      final looseAudio = _bestAudioOnly(formats, container: container, strict: false);
      if (looseVideo != null && looseAudio != null) {
        candidates.add(SelectedFormats(
          video: looseVideo,
          audio: looseAudio,
          videoNeedsTranscode: !_isVideoCompatible(looseVideo.videoCodec, container),
          audioNeedsTranscode: !_isAudioCompatible(looseAudio.audioCodec, container),
        ));
      }
    }

    if (candidates.isEmpty && !formats.any((f) => f.hasAudio)) {
      final videoOnly = _bestVideoOnly(formats, maxHeight: maxHeight, container: container, strict: false);
      if (videoOnly != null) {
        candidates.add(SelectedFormats(muxed: videoOnly));
      }
    }

    return candidates;
  }

  int? _heightCap(VideoQuality quality) {
    if (quality == VideoQuality.best) return null;
    return int.tryParse(quality.value);
  }

  bool _isVideoCompatible(String? codec, VideoFormat container) {
    if (container == VideoFormat.mkv) return true;
    if (codec == null) return false;
    final list = container == VideoFormat.webm ? _webmVideoCodecs : _mp4VideoCodecs;
    return list.any((c) => codec.startsWith(c));
  }

  bool _isAudioCompatible(String? codec, VideoFormat container) {
    if (container == VideoFormat.mkv) return true;
    if (codec == null) return false;
    return container == VideoFormat.webm ? codec.startsWith('opus') : codec.startsWith('mp4a');
  }

  MediaFormat? _bestVideoOnly(
    List<MediaFormat> formats, {
    required int? maxHeight,
    required VideoFormat container,
    required bool strict,
  }) {
    final candidates = formats.where((f) => f.isVideoOnly).toList();
    if (candidates.isEmpty) return null;

    var pool = candidates;
    if (strict && container != VideoFormat.mkv) {
      pool = candidates.where((f) => _isVideoCompatible(f.videoCodec, container)).toList();
      if (pool.isEmpty) return null;
    }

    return _pickByHeightThenBitrate(pool, maxHeight);
  }

  List<MediaFormat> _rankMuxed(List<MediaFormat> formats, {required int? maxHeight}) {
    final candidates = formats.where((f) => f.isMuxed).toList();
    if (candidates.isEmpty) return const [];
    return _rankByHeightThenBitrate(candidates, maxHeight);
  }

  MediaFormat? _pickByHeightThenBitrate(List<MediaFormat> candidates, int? maxHeight) {
    if (candidates.isEmpty) return null;
    final ranked = _rankByHeightThenBitrate(candidates, maxHeight);
    return ranked.isEmpty ? null : ranked.first;
  }

  /// Ranks [candidates] best-first: (1) known height, at/under [maxHeight]
  /// (or no cap), tallest-then-highest-bitrate first; (2) known height,
  /// over the cap (only relevant when 1 has entries too - offered as lower
  /// -priority retry candidates, closest fit first); (3) unknown height,
  /// by bitrate - so a format missing `height` never outranks one that
  /// reports it, but is still selectable. `.first` always matches the old
  /// single-pick `_pickByHeightThenBitrate` in every case.
  List<MediaFormat> _rankByHeightThenBitrate(List<MediaFormat> candidates, int? maxHeight) {
    final withHeight = candidates.where((f) => f.height != null).toList();
    final withoutHeight = candidates.where((f) => f.height == null).toList();

    final underCap = maxHeight == null ? withHeight : withHeight.where((f) => f.height! <= maxHeight).toList();
    final overCap = maxHeight == null ? const <MediaFormat>[] : withHeight.where((f) => f.height! > maxHeight).toList();

    underCap.sort((a, b) {
      final byHeight = b.height!.compareTo(a.height!);
      return byHeight != 0 ? byHeight : b.bitrate.compareTo(a.bitrate);
    });
    final sortedOverCap = List<MediaFormat>.from(overCap)
      ..sort((a, b) {
        final byHeight = a.height!.compareTo(b.height!);
        return byHeight != 0 ? byHeight : b.bitrate.compareTo(a.bitrate);
      });
    final sortedWithoutHeight = List<MediaFormat>.from(withoutHeight)
      ..sort((a, b) => b.bitrate.compareTo(a.bitrate));

    return [...underCap, ...sortedOverCap, ...sortedWithoutHeight];
  }

  MediaFormat? _bestAudioOnly(
    List<MediaFormat> formats, {
    required VideoFormat container,
    required bool strict,
  }) {
    final candidates = formats.where((f) => f.isAudioOnly).toList();
    if (candidates.isEmpty) return null;

    var pool = candidates;
    if (strict && container != VideoFormat.mkv) {
      pool = candidates.where((f) => _isAudioCompatible(f.audioCodec, container)).toList();
      if (pool.isEmpty) return null;
    }

    final sorted = List<MediaFormat>.from(pool)..sort((a, b) => b.bitrate.compareTo(a.bitrate));
    return sorted.first;
  }
}
