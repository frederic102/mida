import 'dart:convert';
import 'dart:io';

import '../extractors/media_models.dart';
import '../utils/url_parser.dart';
import '../../features/download/services/download_service_io.dart';

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

  CaptionDownloader({HttpClient? httpClient}) : _httpClient = httpClient ?? HttpClient();

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
  /// requesting an on-the-fly translation into [translateTo].
  Future<void> download(
    CaptionTrack track,
    String outputPath, {
    String? translateTo,
    Map<String, String> headers = const {},
  }) async {
    final uri = Uri.parse(track.url);
    _requireSecureUrl(uri);
    final params = {...uri.queryParameters, 'fmt': 'vtt'};
    if (translateTo != null) params['tlang'] = translateTo;
    final vttUri = uri.replace(queryParameters: params);

    final request = await _httpClient.getUrl(vttUri);
    headers.forEach(request.headers.set);
    final response = await request.close();
    if (response.statusCode != 200) {
      throw CaptionDownloadException(
        'HTTP ${response.statusCode} fetching captions from ${UrlParser.stripQuery(uri)}',
      );
    }
    final body = await response.transform(utf8.decoder).join();
    await File(outputPath).writeAsString(body);
  }

  /// Same https-only policy as [StreamDownloader] (loopback excepted for
  /// this project's local-server tests): caption URLs are signed too.
  void _requireSecureUrl(Uri uri) {
    final isLoopback = uri.host == '127.0.0.1' || uri.host == 'localhost' || uri.host == '::1';
    if (uri.scheme != 'https' && !isLoopback) {
      throw CaptionDownloadException('Refusing a non-https URL: ${UrlParser.stripQuery(uri)}');
    }
  }
}
