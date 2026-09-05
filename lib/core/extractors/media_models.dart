/// Data model for a single downloadable/streamable rendition of a media
/// item (one itag in YouTube terms, but written platform-neutral so other
/// extractors can reuse it in Phase 2).
class MediaFormat {
  final String id;
  final String url;

  /// Container derived from the mime type subtype, e.g. `mp4`, `webm`.
  final String container;
  final String? videoCodec;
  final String? audioCodec;
  final int? width;
  final int? height;
  final double? fps;

  /// Bitrate in bits per second. Falls back to 0 when the source did not
  /// report one (should not normally happen, but formats are attacker
  /// controlled input from the network so we do not assume presence).
  final int bitrate;
  final int? contentLength;
  final bool hasVideo;
  final bool hasAudio;

  /// How this format's [url] must be fetched: `'https'` (the default) means
  /// a plain ranged GET (`StreamDownloader`); `'hls'`/`'dash'` mean [url]
  /// is a manifest (m3u8/mpd) that only ffmpeg can read
  /// (`HlsFfmpegDownloader`). Extractors do not set this themselves -
  /// `ExtractorRegistry.resolveInfo` derives it from [container] in one
  /// place (`m3u8` -> `hls`, `mpd` -> `dash`), so no per-extractor
  /// duplication of that mapping.
  final String protocol;

  const MediaFormat({
    required this.id,
    required this.url,
    required this.container,
    this.videoCodec,
    this.audioCodec,
    this.width,
    this.height,
    this.fps,
    this.bitrate = 0,
    this.contentLength,
    required this.hasVideo,
    required this.hasAudio,
    this.protocol = 'https',
  });

  bool get isMuxed => hasVideo && hasAudio;
  bool get isVideoOnly => hasVideo && !hasAudio;
  bool get isAudioOnly => hasAudio && !hasVideo;

  /// Returns a copy with [protocol] replaced, everything else unchanged.
  /// Used by [ExtractorRegistry.resolveInfo] to stamp the derived protocol
  /// onto formats an extractor built with the default `'https'`.
  MediaFormat withProtocol(String protocol) => MediaFormat(
        id: id,
        url: url,
        container: container,
        videoCodec: videoCodec,
        audioCodec: audioCodec,
        width: width,
        height: height,
        fps: fps,
        bitrate: bitrate,
        contentLength: contentLength,
        hasVideo: hasVideo,
        hasAudio: hasAudio,
        protocol: protocol,
      );

  @override
  String toString() =>
      'MediaFormat(id: $id, container: $container, video: $videoCodec, '
      'audio: $audioCodec, ${width}x$height, bitrate: $bitrate, protocol: $protocol)';
}

/// A single caption/subtitle track offered by the source.
class CaptionTrack {
  final String languageCode;
  final String url;

  /// True when the track is machine generated (YouTube's `kind: asr`).
  final bool isAuto;

  const CaptionTrack({
    required this.languageCode,
    required this.url,
    this.isAuto = false,
  });
}

/// Extracted metadata + playable renditions for one media item, produced by
/// a [MediaExtractor].
class MediaInfo {
  final String id;
  final String title;
  final String? author;
  final String? thumbnailUrl;
  final Duration? duration;
  final List<MediaFormat> formats;
  final List<CaptionTrack> captions;

  /// Language codes YouTube can auto-translate an existing caption track
  /// into on the fly (its `&tlang=` feature), separate from [captions]
  /// (the tracks that actually exist natively).
  final List<String> translatableLanguageCodes;
  final Uri sourceUrl;

  /// Headers that must be sent alongside every request to a format's [url]
  /// (e.g. the User-Agent that was used to obtain the URL; YouTube ties
  /// signed stream URLs to the requesting client).
  final Map<String, String> requestHeaders;

  const MediaInfo({
    required this.id,
    required this.title,
    this.author,
    this.thumbnailUrl,
    this.duration,
    this.formats = const [],
    this.captions = const [],
    this.translatableLanguageCodes = const [],
    required this.sourceUrl,
    this.requestHeaders = const {},
  });
}

/// Raised when the source explicitly refused to return playable formats
/// (bot check, region lock, private video, etc). Callers should show
/// [reason] to the user rather than a generic failure.
class MediaExtractionException implements Exception {
  final String status;
  final String? reason;

  const MediaExtractionException(this.status, [this.reason]);

  @override
  String toString() => reason == null
      ? 'MediaExtractionException($status)'
      : 'MediaExtractionException($status: $reason)';
}

/// Raised when [FormatSelector] cannot find anything downloadable at all
/// (no adaptive pair, no muxed fallback). Kept distinct from
/// [MediaExtractionException] since the extraction itself succeeded; the
/// video simply has nothing playable for this app to use.
class NoDownloadableFormatsException implements Exception {
  final String message;

  const NoDownloadableFormatsException([
    this.message = 'No downloadable formats were found for this video.',
  ]);

  @override
  String toString() => message;
}
