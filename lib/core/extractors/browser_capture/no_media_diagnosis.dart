import '../generic/html_media_sniffer.dart';
import '../media_models.dart';
import 'headless_block_detector.dart';
import 'page_meta_reader.dart';
import 'page_status_detector.dart';
import 'page_status_exceptions.dart';

/// One `Runtime.evaluate` returning a string, or null on any failure.
typedef StringEval = Future<String?> Function(String expression);

/// Why a browser capture found no media, as the exception
/// `BrowserCaptureExtractor` throws. Split out of that file (Plumbline P8,
/// 400-line cap) together with the page-status read both its early exit and
/// its late "nothing was ever found" path share.
class NoMediaDiagnosis {
  const NoMediaDiagnosis._();

  /// One page-status read, one classification, so the two call sites can
  /// never disagree about what a page's own title/URL/status code mean.
  static Future<PageStatusSignal?> pageStatusSignal(
    StringEval eval,
    Uri sourceUrl,
    int? mainDocumentStatus, {
    HtmlSniffResult? domFallback,
  }) async {
    final meta = await PageMetaReader.read(eval);
    final finalUrl = Uri.tryParse((meta?['href'] as String?) ?? '') ?? sourceUrl;
    final title = PageMetaReader.title(meta) ?? domFallback?.title;
    return PageStatusDetector.detect(finalUrl: finalUrl, title: title, mainDocumentStatusCode: mainDocumentStatus);
  }

  /// Order: a login wall / 404 keep their own, clearer errors. In
  /// forced-headless mode ([headlessBlockCheck]) a bot-check title or
  /// [HeadlessBlockDetector]'s challenge evidence is `HEADLESS_BLOCKED`,
  /// otherwise its 429/5xx verdict maps to `RATE_LIMITED`/`NETWORK`. Headed,
  /// a bot-check stays `BOT_CHECK_REQUIRED` and a 429/5xx main document maps
  /// the same way. Anything else is `NO_MEDIA_FOUND`.
  static Future<MediaExtractionException> exceptionFor(
    StringEval eval,
    Uri sourceUrl,
    HtmlSniffResult? domFallback,
    int? mainDocumentStatus, {
    bool headlessBlockCheck = false,
    String? html,
  }) async {
    final signal = await pageStatusSignal(eval, sourceUrl, mainDocumentStatus, domFallback: domFallback);
    if (signal == PageStatusSignal.loginRequired || signal == PageStatusSignal.notFound) {
      return PageStatusExceptions.forSignal(signal);
    }
    final statusFailure = PageStatusExceptions.forMainDocumentStatus(sourceUrl, mainDocumentStatus);
    if (headlessBlockCheck) {
      if (signal == PageStatusSignal.botCheckRequired) return HeadlessBlockDetector.exception(sourceUrl);
      final verdict = await HeadlessBlockDetector.verdictFor(eval, html: html, mainDocumentStatus: mainDocumentStatus);
      switch (verdict) {
        case HeadlessVerdict.blocked:
          return HeadlessBlockDetector.exception(sourceUrl);
        case HeadlessVerdict.rateLimited:
        case HeadlessVerdict.serverError:
          return statusFailure ?? PageStatusExceptions.forSignal(null);
        case HeadlessVerdict.notBlocked:
          return PageStatusExceptions.forSignal(null);
      }
    }
    if (signal != null) return PageStatusExceptions.forSignal(signal);
    return statusFailure ?? PageStatusExceptions.forSignal(null);
  }
}
