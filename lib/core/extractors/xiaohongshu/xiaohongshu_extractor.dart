import '../media_extractor.dart';
import '../media_models.dart';
import '../native_http/native_host_list.dart';
import '../native_http/native_http_client.dart';
import 'xiaohongshu_note_parser.dart';
import 'xiaohongshu_state_reader.dart';
import 'xiaohongshu_url_matcher.dart';

/// Native Xiaohongshu (RedNote) extractor for video notes
/// (`xiaohongshu.com/explore/<id>`, `xiaohongshu.com/discovery/item/<id>`,
/// `xhslink.com/<code>`; see [XiaohongshuUrlMatcher]).
///
/// Technique, per `docs/supported-sites.md` Policy: one plain HTTPS GET of
/// the public note page with a normal desktop User-Agent and no cookies
/// (the share link's own `xsec_token` is forwarded when the URL has one),
/// then reading the `window.__INITIAL_STATE__` the page hands its front end
/// ([XiaohongshuStateReader], [XiaohongshuNoteParser]). A `xhslink.com`
/// short link is resolved through its `Location` header (HTTPS only, every
/// hop through `HostPolicy`, target must be a Xiaohongshu note URL). No
/// signature headers (`x-s`, `x-t`), no app API, no challenge solving.
///
/// Formats: every `h264`/`h265`/`av1` rendition is a progressive mp4 with
/// the width/height/bitrate/size the page gave; Xiaohongshu muxes audio into
/// them, which is a positive reading only when the entry names an
/// `audioCodec` (otherwise `capabilitiesUnknown`). The origin file
/// (`sns-video-bd.xhscdn.com/<originVideoKey>`) is offered as one more mp4
/// of unknown size and capabilities.
///
/// Outcomes: image note -> `NO_MEDIA_FOUND`; sign-in page redirect -> `LOGIN_REQUIRED`; an empty note shell
/// (missing `xsec_token`, anti-bot page) -> `CHALLENGE_FAILED`; HTTP
/// 404/410 or the site's `/404` page -> `NOT_FOUND`; 429 -> `RATE_LIMITED`;
/// 401/403 -> `CHALLENGE_FAILED`; unrecognized page -> `PARSE_ERROR`.
class XiaohongshuExtractor implements MediaExtractor {
  static const Map<String, String> _downloadHeaders = {
    'User-Agent': NativeHttpClient.userAgent,
    'Referer': 'https://www.xiaohongshu.com/',
  };

  static const Map<String, String> _codecNames = {'h264': 'h264', 'h265': 'hevc', 'av1': 'av1'};

  final NativeHttpClient _http;
  final XiaohongshuNoteParser _parser;

  /// Hosts Xiaohongshu media may live on (the `xhscdn.com` video CDNs). A
  /// stream or origin URL outside it is never offered.
  static const NativeHostList mediaHosts = NativeHostList(['xhscdn.com', 'xiaohongshu.com']);

  XiaohongshuExtractor({NativeHttpClient? httpClient, XiaohongshuNoteParser? parser})
      : _http = (httpClient ?? NativeHttpClient(service: 'Xiaohongshu')).withMediaHosts(mediaHosts),
        _parser = parser ?? const XiaohongshuNoteParser();

  @override
  bool canHandle(Uri url) => XiaohongshuUrlMatcher.match(url) != null;

  @override
  Future<MediaInfo> extract(Uri url) async {
    var ref = XiaohongshuUrlMatcher.match(url);
    if (ref == null) {
      throw const MediaExtractionException('UNSUPPORTED_URL', 'Not a recognizable Xiaohongshu note URL.');
    }
    if (ref.shortLink != null) {
      final landing = await _http.resolveShortLink(
        ref.shortLink!,
        accept: (hop) => XiaohongshuUrlMatcher.fromLanding(hop) != null,
      );
      ref = XiaohongshuUrlMatcher.fromLanding(landing)!;
    }
    final noteId = ref.noteId!;

    final page = await _http.get(
      ref.fetchUrl!,
      headers: const {'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'},
      kind: NativeBodyKind.page,
      acceptHop: (hop) => XiaohongshuUrlMatcher.isSiteHost(hop.host),
    );
    final landed = page.effectiveUrl;
    if (XiaohongshuUrlMatcher.isLoginPage(landed)) throw _loginRequired;
    if (XiaohongshuUrlMatcher.isNotFoundPage(landed)) throw _notFound;
    NativeHttpClient.throwForStatus(page.statusCode, 'Xiaohongshu');

    final state = XiaohongshuStateReader.extract(page.body);
    if (state == null) {
      throw MediaExtractionException(
        'PARSE_ERROR',
        'MiDa could not find note data in this Xiaohongshu page'
            '${page.truncated ? ' (page larger than the read limit)' : ''}; trying another method.',
      );
    }

    final note = _parser.parse(state, noteId: noteId);
    final formats = _formats(note);
    if (formats.isEmpty) {
      throw const MediaExtractionException('NO_MEDIA_FOUND', 'None of the Xiaohongshu streams for this note are on a known video host.');
    }
    return MediaInfo(
      id: note.id,
      title: note.title,
      author: note.author,
      thumbnailUrl: note.thumbnailUrl,
      duration: note.duration,
      formats: formats,
      sourceUrl: url,
      requestHeaders: _downloadHeaders,
    );
  }

  List<MediaFormat> _formats(XiaohongshuNote note) {
    final formats = <MediaFormat>[];
    for (final stream in note.streams.where((s) => _http.mediaUrlAllowed(s.url))) {
      formats.add(MediaFormat(
        id: '${stream.codecGroup}-${stream.height ?? 'x'}-${formats.length + 1}',
        url: stream.url,
        container: 'mp4',
        videoCodec: stream.videoCodec ?? _codecNames[stream.codecGroup],
        audioCodec: stream.audioCodec,
        width: stream.width,
        height: stream.height,
        bitrate: stream.bitrate ?? 0,
        contentLength: stream.contentLength,
        hasVideo: true,
        hasAudio: true,
        capabilitiesUnknown: stream.audioCodec == null,
      ));
    }
    final origin = note.originUrl;
    if (origin != null && _http.mediaUrlAllowed(origin) && !formats.any((f) => f.url == origin)) {
      formats.add(MediaFormat(
        id: 'origin',
        url: origin,
        container: 'mp4',
        hasVideo: true,
        hasAudio: true,
        capabilitiesUnknown: true,
      ));
    }
    return formats;
  }

  static const MediaExtractionException _loginRequired = MediaExtractionException(
    'LOGIN_REQUIRED',
    'Xiaohongshu asks to sign in to see this note. Turn on "Use browser login session" in Settings '
        'if your own browser is signed in to Xiaohongshu.',
  );

  static const MediaExtractionException _notFound = MediaExtractionException(
    'NOT_FOUND',
    'This Xiaohongshu note is not available. It may have been removed.',
  );
}
