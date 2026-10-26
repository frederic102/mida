import '../../../core/utils/url_parser.dart';

/// The failure families the queue knows how to explain. Mirrors the
/// `MediaExtractionException.status` values the extractors throw, plus
/// [ffmpeg] (merge/convert step) and [unknown].
enum FailureKind {
  loginRequired,
  drm,
  browserMissing,
  network,
  rateLimited,
  noMediaFound,
  headlessBlocked,
  unsupportedUrl,
  ffmpeg,
  unknown,
}

/// The one button an error panel may offer besides the always-present
/// retry/remove controls.
enum FailureAction { none, retry, enableBrowserLoginAndRetry }

/// One human sentence (what happened), one concrete next step, an optional
/// action, and the redacted original text for "Details".
class ActionableError {
  const ActionableError({
    required this.kind,
    required this.headline,
    required this.nextStep,
    required this.action,
    required this.details,
  });

  final FailureKind kind;
  final String headline;
  final String nextStep;
  final FailureAction action;
  final String details;
}

/// A keyword rule: the first rule (in list order) whose pattern matches the
/// error text decides the kind. Order matters, see [defaultFailureRules].
class FailureRule {
  const FailureRule(this.kind, this.pattern);
  final FailureKind kind;
  final RegExp pattern;
}

const _statusKinds = <String, FailureKind>{
  'LOGIN_REQUIRED': FailureKind.loginRequired,
  'DRM_PROTECTED': FailureKind.drm,
  'DRM': FailureKind.drm,
  'BROWSER_MISSING': FailureKind.browserMissing,
  'NETWORK': FailureKind.network,
  'NETWORK_ERROR': FailureKind.network,
  'RATE_LIMITED': FailureKind.rateLimited,
  'NO_MEDIA_FOUND': FailureKind.noMediaFound,
  'HEADLESS_BLOCKED': FailureKind.headlessBlocked,
  'UNSUPPORTED_URL': FailureKind.unsupportedUrl,
};

/// Matches an explicit status code inside the text, as `DownloadService`
/// writes it (`(status: NETWORK)`) or as `MediaExtractionException`
/// stringifies itself (`MediaExtractionException(NETWORK: ...)`).
final _statusToken = RegExp(r'(?:status: |MediaExtractionException\()([A-Z_]+)\b');

/// Keyword fallback for when the service shows the extractor's `reason`
/// sentence without its status code. Ordered from most to least specific:
/// rate-limit text carries a "Use browser login session" suggestion and
/// no-media text can mention "sign-in", so both must win over the login
/// rule, and "Timed out looking for video" must win over network.
final defaultFailureRules = <FailureRule>[
  FailureRule(
    FailureKind.browserMissing,
    RegExp(r'needs Microsoft Edge|Edge, Google Chrome|MIDA_BROWSER_PATH', caseSensitive: false),
  ),
  FailureRule(FailureKind.headlessBlocked, RegExp(r'headless browser|bot-check', caseSensitive: false)),
  FailureRule(FailureKind.drm, RegExp(r'\bDRM\b|Widevine|PlayReady|FairPlay')),
  FailureRule(
    FailureKind.rateLimited,
    RegExp(r'throttl|rate-limit|rate limit|HTTP 429|too many requests', caseSensitive: false),
  ),
  FailureRule(
    FailureKind.noMediaFound,
    RegExp(
      r'no video found|did not observe any media|no downloadable formats|'
      r'timed out looking for video|has no downloadable',
      caseSensitive: false,
    ),
  ),
  FailureRule(
    FailureKind.unsupportedUrl,
    RegExp(r'not a recognizable|unsupported url|loopback', caseSensitive: false),
  ),
  FailureRule(
    FailureKind.loginRequired,
    RegExp(
      r'sign in|signed-in|log in|logging in|login|age-restricted|password protected|private',
      caseSensitive: false,
    ),
  ),
  FailureRule(FailureKind.ffmpeg, RegExp(r'ffmpeg|merging the downloaded', caseSensitive: false)),
  FailureRule(
    FailureKind.network,
    RegExp(
      r'HTTP \d{3}|internet connection|SocketException|connection (refused|reset|closed)|'
      r'timed out|failed host lookup',
      caseSensitive: false,
    ),
  ),
];

/// Decides the [FailureKind] for [text]: an explicit status code wins,
/// otherwise the first matching rule in [rules].
FailureKind classifyFailure(String text, {List<FailureRule>? rules}) {
  for (final match in _statusToken.allMatches(text)) {
    final kind = _statusKinds[match.group(1)];
    if (kind != null) return kind;
  }
  for (final rule in rules ?? defaultFailureRules) {
    if (rule.pattern.hasMatch(text)) return rule.kind;
  }
  return FailureKind.unknown;
}

/// Turns raw failure text into what the queue row shows.
/// [browserLoginEnabled] changes the login advice: there is no point
/// offering to turn on a setting that is already on.
ActionableError describeFailure(String rawText, {required bool browserLoginEnabled}) {
  final details = UrlParser.redactUrlsInText(rawText.trim());
  final kind = classifyFailure(details);
  ActionableError make(String headline, String nextStep, FailureAction action) => ActionableError(
        kind: kind,
        headline: headline,
        nextStep: nextStep,
        action: action,
        details: details,
      );

  switch (kind) {
    case FailureKind.loginRequired:
      return browserLoginEnabled
          ? make(
              'This video is only available to signed-in viewers.',
              'Sign in to this site in Edge or Chrome, then retry.',
              FailureAction.retry,
            )
          : make(
              'This video is only available to signed-in viewers.',
              'Let MiDa use your Edge or Chrome sign-in, then retry.',
              FailureAction.enableBrowserLoginAndRetry,
            );
    case FailureKind.drm:
      return make(
        'This video is DRM-protected, so MiDa cannot save it.',
        "Use the site's own offline or download option if it has one.",
        FailureAction.none,
      );
    case FailureKind.browserMissing:
      return make(
        'Reading this site needs Microsoft Edge or Google Chrome, and neither was found.',
        'Install Edge or Chrome, or set the MIDA_BROWSER_PATH environment variable to the '
            'browser .exe path and restart MiDa.',
        FailureAction.retry,
      );
    case FailureKind.network:
      return make(
        'MiDa could not reach the site.',
        'Check your internet connection, then retry.',
        FailureAction.retry,
      );
    case FailureKind.rateLimited:
      return make(
        'The site is limiting requests from your network right now.',
        browserLoginEnabled
            ? 'Wait a few minutes, then retry.'
            : 'Wait a few minutes, then retry. Turning on browser login in Settings can also help.',
        FailureAction.retry,
      );
    case FailureKind.noMediaFound:
      return make(
        'MiDa opened the page but found no video on it.',
        'Check that the video plays in your browser, or paste the direct video link.',
        FailureAction.retry,
      );
    case FailureKind.headlessBlocked:
      return make(
        'The site would not show its video to the hidden browser MiDa used.',
        'Remove the MIDA_HEADLESS environment variable, restart MiDa from your desktop, then retry.',
        FailureAction.retry,
      );
    case FailureKind.unsupportedUrl:
      return make(
        'MiDa does not recognize this link as a video page.',
        'Copy the link from the video page itself (not a search or profile page) and add it again.',
        FailureAction.none,
      );
    case FailureKind.ffmpeg:
      return make(
        'The video downloaded, but converting or merging it failed.',
        'Reinstall MiDa to restore its bundled ffmpeg, or set MIDA_FFMPEG_PATH, then retry.',
        FailureAction.retry,
      );
    case FailureKind.unknown:
      return make(
        'The download did not finish.',
        'Retry once. If it fails again, check that the link still plays in your browser.',
        FailureAction.retry,
      );
  }
}
