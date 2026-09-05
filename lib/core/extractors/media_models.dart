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

  /// True when [hasVideo]/[hasAudio] are the safe default guess (muxed),
  /// not a positive reading from the source itself (a URL-embedded
  /// encode-tag, a sibling `mimeType`/`codecs`, a manifest's own per-variant
  /// metadata, ...). Existing behavior is unchanged either way - the
  /// download pipeline's post-download ffprobe check already retries the
  /// next ranked candidate whenever a format that claimed `hasAudio: true`
  /// turns out not to have one (see `DownloadOutcomeVerifier`) - this flag
  /// only documents *why* a given format was assumed muxed, for
  /// diagnostics/future use, without changing that retry behavior.
  final bool capabilitiesUnknown;

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
    this.capabilitiesUnknown = false,
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
        capabilitiesUnknown: capabilitiesUnknown,
        protocol: protocol,
      );

  @override
  String toString() =>
      'MediaFormat(id: $id, container: $container, video: $videoCodec, '
      'audio: $audioCodec, ${width}x$height, bitrate: $bitrate, protocol: $protocol)';
}

/// One cookie captured from a live browser session, scoped precisely
/// enough (domain + path + secure) that a downloader can decide per
/// request whether it actually applies - see `CookieScope`. Always sourced
/// from CDP's own `Network.getCookies` (which reports all three), never
/// built by hand from a raw `document.cookie` string (that loses
/// domain/path/secure entirely).
class CookieEntry {
  final String domain;
  final String path;
  final bool secure;
  final String name;
  final String value;

  const CookieEntry({
    required this.domain,
    required this.path,
    required this.secure,
    required this.name,
    required this.value,
  });
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

  /// Cookies scoped to the exact domain they were captured for, keyed by
  /// that domain - lets a downloader send only the cookies that actually
  /// apply to a given format's own host (see `CookieScope`), rather than
  /// every cookie the page's own session carried flattened into one
  /// [requestHeaders] `Cookie` entry (sending format B's cookies to format
  /// A's host leaks them to whichever CDN happens to be involved). Empty
  /// for every extractor except `BrowserCaptureExtractor`; a downloader
  /// falls back to [requestHeaders]'s own `Cookie` entry, if any, when
  /// this has no match for a given request's host.
  final Map<String, List<CookieEntry>> cookiesByDomain;

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
    this.cookiesByDomain = const {},
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
