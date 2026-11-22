import '../../../core/extractors/media_models.dart';
import '../../../core/utils/display_text.dart';
import '../../../core/utils/url_parser.dart';
import 'download_error_mapping.dart';

/// Explains why a channel or playlist could not be listed, in the same shape
/// the queue uses ([ActionableError]). Network and rate-limit failures reuse
/// the queue wording; every other status code (a policy refusal such as
/// LOGIN_REQUIRED, NOT_FOUND, a page YouTube changed) shows the extractor's
/// own message, so the user sees what the site actually said.
///
/// Listing never uses the browser login session, so the queue's advice to
/// turn it on is left out ([describeFailure] gets `browserLoginEnabled: true`
/// only to drop that advice) and no action other than Retry is offered.
ActionableError describeListError(Object error) {
  if (error is MediaExtractionException) {
    final kind = classifyFailure('(status: ${error.status})');
    if (kind == FailureKind.network || kind == FailureKind.rateLimited) {
      return describeFailure('(status: ${error.status}) ${error.reason ?? ''}', browserLoginEnabled: true);
    }
    return ActionableError(
      kind: kind,
      headline: _oneLine(error.reason ?? 'The list could not be loaded (${error.status}).'),
      nextStep: 'Check that the channel or playlist is public and opens in your browser, then retry.',
      action: FailureAction.retry,
      details: _oneLine('${error.status}: ${error.reason ?? ''}'),
    );
  }
  return ActionableError(
    kind: FailureKind.unknown,
    headline: 'The list could not be loaded.',
    nextStep: 'Retry once. If it fails again, check that the page opens in your browser.',
    action: FailureAction.retry,
    details: _oneLine(error.toString()),
  );
}

String _oneLine(String s) => UrlParser.redactUrlsInText(displayText(s));
