import '../generic/format_expander.dart';
import '../media_extractor.dart';
import '../media_models.dart';
import '../native_http/native_host_list.dart';
import '../native_http/native_http_client.dart';
import 'soop_url_matcher.dart';
import 'soop_view_parser.dart';

/// Native SOOP (formerly AfreecaTV) VOD extractor for
/// `vod.sooplive.co.kr/player/<nTitleNo>` and the legacy
/// `vod.afreecatv.com/player/<nTitleNo>`; see [SoopUrlMatcher].
///
/// Technique, per `docs/supported-sites.md` Policy: the one anonymous call
/// the VOD player page makes, `POST https://api.m.sooplive.co.kr/station/
/// video/a/view` with the form `nTitleNo=<n>&nApiLevel=10&nPlaylistIdx=0`,
/// a normal desktop User-Agent and the player page as Referer, no cookies.
///
/// API host: [apiUrl] uses `api.m.sooplive.co.kr`, the host the Korean
/// `sooplive.co.kr` site itself calls (the order for this lane named it; the
/// landscape research listed `api.m.sooplive.com`, the global-site twin).
/// The legacy `afreecatv.com` player URLs are served by the same API after
/// the rebrand. If the live gate shows the other host is the one answering,
/// changing [apiUrl] is the only edit.
///
/// Formats: the first part's per-quality `quality_info[].file` HLS URLs (each
/// expanded by `FormatExpander`: DRM-scanned, master variants split), else
/// the part's own `file`. A VOD with several parts returns the first part
/// only and says so in the title ("... (part 1 of N)"); parts are never
/// stitched.
///
/// Outcomes: adult/password/members-only -> `LOGIN_REQUIRED`; deleted ->
/// `NOT_FOUND`; HTTP 429 -> `RATE_LIMITED`; 401/403 -> `CHALLENGE_FAILED`;
/// unrecognized answer -> `PARSE_ERROR`; DRM -> `DRM_PROTECTED`. Live
/// streams are out of scope.
class SoopExtractor implements MediaExtractor {
  static const String _referer = 'https://vod.sooplive.co.kr/';

  static const Map<String, String> _downloadHeaders = {
    'User-Agent': NativeHttpClient.userAgent,
    'Referer': _referer,
  };

  /// The VOD view endpoint (see the class doc on the host).
  static final Uri apiUrl = Uri.https('api.m.sooplive.co.kr', '/station/video/a/view');

  final NativeHttpClient _http;
  final SoopViewParser _parser;
  final FormatExpander _expander;

  /// Hosts SOOP media may live on (VOD archive CDNs and the legacy
  /// AfreecaTV domain). A stream URL, or an HLS redirect, outside it is
  /// never requested or offered. Widen only from an observed gate result.
  static const NativeHostList mediaHosts = NativeHostList(['sooplive.co.kr', 'sooplive.com', 'afreecatv.com']);

  SoopExtractor({NativeHttpClient? httpClient, SoopViewParser? parser})
      : this._(
          (httpClient ?? NativeHttpClient(service: 'SOOP')).withMediaHosts(mediaHosts),
          parser ?? const SoopViewParser(),
        );

  SoopExtractor._(this._http, this._parser) : _expander = FormatExpander(fetchText: _http.fetchText);

  @override
  bool canHandle(Uri url) => SoopUrlMatcher.titleNo(url) != null;

  @override
  Future<MediaInfo> extract(Uri url) async {
    final titleNo = SoopUrlMatcher.titleNo(url);
    if (titleNo == null) {
      throw const MediaExtractionException('UNSUPPORTED_URL', 'Not a recognizable SOOP VOD URL.');
    }

    final response = await _http.postForm(
      apiUrl,
      {'nTitleNo': titleNo, 'nApiLevel': '10', 'nPlaylistIdx': '0'},
      headers: {
        'Accept': 'application/json, text/plain, */*',
        'Origin': 'https://vod.sooplive.co.kr',
        'Referer': 'https://vod.sooplive.co.kr/player/$titleNo',
      },
    );
    NativeHttpClient.throwForStatus(response.statusCode, 'SOOP');
    if (response.truncated) {
      throw const MediaExtractionException('PARSE_ERROR', 'SOOP answered with more data than expected; trying another method.');
    }

    final vod = _parser.parse(response.body, titleNo: titleNo);
    final formats = <MediaFormat>[];
    var drmDetected = false;
    for (final stream in vod.streams.where((s) => _http.mediaUrlAllowed(s.url))) {
      if (stream.container == 'mp4') {
        formats.add(MediaFormat(
          id: 'mp4-${stream.height ?? formats.length}',
          url: stream.url,
          container: 'mp4',
          width: stream.width,
          height: stream.height,
          bitrate: stream.bitrate ?? 0,
          hasVideo: true,
          hasAudio: true,
          capabilitiesUnknown: true,
        ));
        continue;
      }
      final expanded = await _expander.expandFormats(
        stream.url,
        'm3u8',
        extraHeaders: _downloadHeaders,
        width: stream.width,
        height: stream.height,
        bitrate: stream.bitrate,
      );
      drmDetected = drmDetected || expanded.drmDetected;
      formats.addAll(_http.filterAllowedFormats(expanded.formats));
    }

    final seen = <String>{};
    final unique = [for (final f in formats) if (seen.add(f.url)) f];
    if (unique.isEmpty) {
      throw drmDetected
          ? const MediaExtractionException('DRM_PROTECTED', 'This SOOP VOD is DRM protected. MiDa does not bypass DRM.')
          : const MediaExtractionException('NO_MEDIA_FOUND', 'None of the SOOP streams for this VOD could be read.');
    }

    return MediaInfo(
      id: vod.id,
      title: vod.title,
      author: vod.author,
      thumbnailUrl: vod.thumbnailUrl,
      duration: vod.duration,
      formats: unique,
      sourceUrl: url,
      requestHeaders: _downloadHeaders,
    );
  }
}
