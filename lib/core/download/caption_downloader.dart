import 'dart:async';
import 'dart:io';

import '../extractors/generic/bounded_body.dart';
import '../extractors/media_models.dart';
import '../net/host_policy.dart';
import '../net/per_hop_credentials.dart';
import '../utils/url_parser.dart';
import '../../features/download/models/download_models.dart';

class CaptionDownloadException implements Exception {
  final String message;
  const CaptionDownloadException(this.message);

  @override
  String toString() => 'CaptionDownloadException: $message';
}

/// One resolved caption request: download [sourceTrack]'s vtt, optionally
/// asking YouTube to translate it into [translateTo] on the fly, and label
/// the output with [outputLanguageCode].
class CaptionDownloadPlan {
  final CaptionTrack sourceTrack;
  final String outputLanguageCode;

  /// Non-null when the requested language has no native track and we are
  /// riding YouTube's `&tlang=` auto-translation off of [sourceTrack].
  final String? translateTo;

  const CaptionDownloadPlan({
    required this.sourceTrack,
    required this.outputLanguageCode,
    this.translateTo,
  });
}

/// Fetches caption tracks as `.vtt` files. SRT conversion is left to
/// ffmpeg (via `MediaMerger`-style `Process.run`), performed by the
/// pipeline that owns the ffmpeg path.
class CaptionDownloader {
  final HttpClient _httpClient;

  /// Exempts only the caption URL's own host (hop 0) from the https-only
  /// and private-host checks - lets tests point this at a local
  /// `http://127.0.0.1` fixture server. Every hop reached via a redirect
  /// is always checked regardless (see [HostPolicy.guardedRequest]), so a
  /// caption URL that redirects to a private/loopback address is still
  /// refused even in a test that sets this. Production code must never
  /// set this to true.
  final bool allowPrivateHosts;

  /// DNS lookup used by the per-hop public-host check; tests inject a fake.
  final Future<List<InternetAddress>> Function(String host) _resolveHost;

  /// Caption files are small text; anything bigger is refused (Bulwark r3 M1).
  static const int maxCaptionBytes = 2 * 1024 * 1024;
  static const Duration readTimeout = Duration(seconds: 30);

  CaptionDownloader({
    HttpClient? httpClient,
    this.allowPrivateHosts = false,
    Future<List<InternetAddress>> Function(String host)? resolveHost,
  })  : _httpClient = httpClient ?? HttpClient(),
        _resolveHost = resolveHost ?? InternetAddress.lookup;

  /// Decides which caption track(s) to fetch for the requested
  /// [SubtitleOption] (equivalent to write-subs + write-auto-subs for the
  /// requested language):
  ///
  /// 1. An exact `languageCode` match, preferring a manually authored track
  ///    over an auto-generated (`asr`) one.
  /// 2. A prefix match (`en` matches `en-US`, `en-GB`) when no exact match
  ///    exists.
  /// 3. Otherwise, if [translatableLanguageCodes] says YouTube can
  ///    translate into that language, fall back to auto-translation from
  ///    the `asr` track (or the first available track).
  ///
  /// A requested language with none of the above is skipped quietly (not
  /// an error): matches [SubtitleOption.none]'s existing "no-op" contract.
  static List<CaptionDownloadPlan> selectPlans(
    List<CaptionTrack> tracks,
    List<String> translatableLanguageCodes,
    SubtitleOption option,
  ) {
    if (option == SubtitleOption.none || option.value.isEmpty) return const [];
    final wanted = option.value.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty);

    final plans = <CaptionDownloadPlan>[];
    for (final lang in wanted) {
      final langLower = lang.toLowerCase();

      final exact = tracks.where((t) => t.languageCode.toLowerCase() == langLower).toList();
      if (exact.isNotEmpty) {
        plans.add(CaptionDownloadPlan(sourceTrack: _preferManual(exact), outputLanguageCode: lang));
        continue;
      }

      final prefixed = tracks.where((t) => t.languageCode.toLowerCase().startsWith('$langLower-')).toList();
      if (prefixed.isNotEmpty) {
        plans.add(CaptionDownloadPlan(sourceTrack: _preferManual(prefixed), outputLanguageCode: lang));
        continue;
      }

      if (tracks.isEmpty || !translatableLanguageCodes.contains(lang)) continue;
      final source = tracks.firstWhere((t) => t.isAuto, orElse: () => tracks.first);
      plans.add(CaptionDownloadPlan(sourceTrack: source, outputLanguageCode: lang, translateTo: lang));
    }
    return plans;
  }

  static CaptionTrack _preferManual(List<CaptionTrack> matches) {
    final manual = matches.where((t) => !t.isAuto);
    return manual.isNotEmpty ? manual.first : matches.first;
  }

  /// Downloads [track]'s captions as VTT text to [outputPath], optionally
  /// requesting an on-the-fly translation into [translateTo]. Routed
  /// through [HostPolicy.guardedRequest] (rather than trusting
  /// `HttpClientRequest.followRedirects`, which this used to do
  /// unconditionally) so every redirect hop - not just the URL [track]
  /// itself carries - is host-checked before being fetched; a caption
  /// host that redirects to a private/loopback address would otherwise
  /// let it turn this app into an SSRF proxy against its own host/LAN,
  /// same as the risk `StreamDownloader`'s own redirect handling guards
  /// against.
  Future<void> download(
    CaptionTrack track,
    String outputPath, {
    String? translateTo,
    Map<String, String> headers = const {},
  }) async {
    final uri = Uri.parse(track.url);
    _requireAllowedUrl(uri);
    final params = {...uri.queryParameters, 'fmt': 'vtt'};
    if (translateTo != null) params['tlang'] = translateTo;
    final vttUri = uri.replace(queryParameters: params);

    var hopIndex = 0;
    final response = await HostPolicy.guardedRequest(
      _httpClient,
      vttUri,
      useHead: false,
      // Cookie/Authorization only on hops with the caption URL's own origin (Bulwark r3 M1).
      configureRequest: (request) => PerHopCredentials.apply(request, origin: vttUri, headers: headers),
      allowPrivateHosts: allowPrivateHosts,
      resolveHost: _resolveHost,
      onHop: (hop) {
        // HTTPS on every redirect hop; hop 0 was checked by _requireAllowedUrl.
        if (hopIndex++ > 0 && hop.scheme != 'https') {
          throw CaptionDownloadException('Refusing a non-https redirect: ${UrlParser.redactUrlsInText('$hop')}');
        }
      },
    );
    if (response.statusCode != 200) {
      await discardBody(response);
      throw CaptionDownloadException(
        'HTTP ${response.statusCode} fetching captions from ${UrlParser.redactUrlsInText('$uri')}',
      );
    }
    final BoundedBody body;
    try {
      body = await readBoundedBytes(response, maxCaptionBytes).timeout(readTimeout);
    } on TimeoutException {
      throw const CaptionDownloadException('The caption server stopped sending the file.');
    }
    if (body.truncated) {
      throw const CaptionDownloadException('The caption file is larger than 2 MiB; refusing it.');
    }
    await File(outputPath).writeAsString(body.text);
  }

  /// Same https-only policy as [StreamDownloader] ([allowPrivateHosts]
  /// exempts only this entry URL, same convention): caption URLs are
  /// signed too. Private-host/DNS-rebinding checks for this hop and every
  /// redirect hop after it are [HostPolicy.guardedRequest]'s own job, not
  /// this method's.
  void _requireAllowedUrl(Uri uri) {
    if (allowPrivateHosts) return;
    if (uri.scheme != 'https') {
      throw CaptionDownloadException('Refusing a non-https URL: ${UrlParser.redactUrlsInText('$uri')}');
    }
  }
}
