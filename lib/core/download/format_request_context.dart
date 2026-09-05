import '../extractors/media_models.dart';

/// Bundles the two request-identity pieces `MediaDownloadPipeline` threads
/// through every private helper on the way to a downloader - `headers`
/// (UA/Referer, and any extractor's own not-yet-scoped `Cookie` fallback)
/// and [MediaInfo.cookiesByDomain] - as one value instead of two, so adding
/// the second did not mean adding a second parameter to every method
/// already threading the first.
class FormatRequestContext {
  final Map<String, String> headers;
  final Map<String, List<CookieEntry>> cookiesByDomain;

  const FormatRequestContext(this.headers, this.cookiesByDomain);

  factory FormatRequestContext.fromInfo(MediaInfo info) =>
      FormatRequestContext(info.requestHeaders, info.cookiesByDomain);
}
