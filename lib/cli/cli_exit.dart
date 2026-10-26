import 'dart:async';
import 'dart:io';

import '../core/download/caption_downloader.dart' show CaptionDownloadException;
import '../core/download/hls_ffmpeg_args.dart' show HeaderInjectionException;
import '../core/download/media_merger.dart';
import '../core/download/stream_downloader.dart';
import '../core/extractors/media_models.dart';
import '../core/services/cdp_client.dart' show CdpCommandException;
import '../core/utils/url_parser.dart';
import '../features/download/services/all_format_candidates_failed_exception.dart';

/// Process exit codes of the agent CLI (docs/plan-phase7-coverage-agent.md,
/// "Track A contract"). Stable interface: agents and the mida-download skill key off
/// these, so changing a value is a breaking change.
abstract final class CliExit {
  static const ok = 0;
  static const usage = 2;
  static const extraction = 3;
  static const download = 4;
  static const policy = 5;
  static const environment = 6;
  static const rateLimited = 7;

  /// stdout was closed by the reader (for example `mida-cli sites | head
  /// -c0`). Nothing more can be reported on stdout, so the CLI stops
  /// writing and exits with this code.
  static const outputClosed = 8;
}

/// Which phase of a command a failure came from. Decides the default exit
/// code for an error the table below does not name explicitly.
enum CliStage { resolve, download }

/// One classified failure: the machine-readable [code] for the JSON `error`
/// event, the already redacted human [message], and the process [exitCode].
class CliFailure {
  final String code;
  final String message;
  final int exitCode;

  const CliFailure(this.code, this.message, this.exitCode);
}

/// `MediaExtractionException.status` values with an explicit exit code.
/// Statuses absent here (NOT_FOUND, UNSUPPORTED_MEDIA, CHALLENGE_FAILED,
/// YouTube's UNPLAYABLE/ERROR, ...) fall back to the stage default: 3 while
/// resolving, 4 when they surface from a format candidate during the
/// download. Beyond the contract's list, the statuses that mean "the source
/// refuses without a person (sign-in, age gate, bot check)" are policy too.
const Map<String, int> statusExitCodes = {
  'NO_MEDIA_FOUND': CliExit.extraction,
  'UNSUPPORTED_URL': CliExit.extraction,
  'PARSE_ERROR': CliExit.extraction,
  'DRM_PROTECTED': CliExit.policy,
  'DRM': CliExit.policy,
  'LOGIN_REQUIRED': CliExit.policy,
  'HEADLESS_BLOCKED': CliExit.policy,
  'BOT_CHECK_REQUIRED': CliExit.policy,
  'PRIVATE': CliExit.policy,
  'AGE_VERIFICATION_REQUIRED': CliExit.policy,
  'CONTENT_CHECK_REQUIRED': CliExit.policy,
  'BROWSER_MISSING': CliExit.environment,
  'FFMPEG_MISSING': CliExit.environment,
  'NETWORK': CliExit.environment,
  'RATE_LIMITED': CliExit.rateLimited,
};

/// Exit codes whose meaning is the same no matter which stage raised them
/// (policy / environment / rate limit). When a download's last candidate
/// failed with one of these, that is the real reason, not a generic 4.
const _stageIndependent = {CliExit.policy, CliExit.environment, CliExit.rateLimited};

String _redact(String text) => UrlParser.redactUrlsInText(text);

const _ffmpegNames = {'ffmpeg', 'ffprobe'};
const _browserNames = {
  'msedge',
  'chrome',
  'chromium',
  'chromium-browser',
  'google-chrome',
  'google-chrome-stable',
  'brave',
  'microsoft-edge',
  'microsoft-edge-stable',
};

/// The error code for a [ProcessException] on [executable] (a bare name or
/// a full path, any case, with or without `.exe`): `FFMPEG_MISSING` for
/// ffmpeg/ffprobe, `BROWSER_MISSING` for a capture browser, else
/// `PROCESS_START_FAILED`.
String processFailureCode(String executable) {
  final base = executable.replaceAll('\\', '/').split('/').last.toLowerCase();
  final name = base.endsWith('.exe') ? base.substring(0, base.length - 4) : base;
  if (_ffmpegNames.contains(name)) return 'FFMPEG_MISSING';
  if (_browserNames.contains(name)) return 'BROWSER_MISSING';
  return 'PROCESS_START_FAILED';
}

/// Maps any exception the resolve/download chain can raise to a
/// [CliFailure]. Every message goes through [UrlParser.redactUrlsInText]
/// (signed query strings must never reach an agent's log), and messages
/// that could carry request headers or DevTools payloads are replaced by a
/// fixed sentence instead of being echoed.
CliFailure classifyError(Object error, {required CliStage stage}) {
  if (error is MediaExtractionException) {
    final exit = statusExitCodes[error.status] ??
        (stage == CliStage.resolve ? CliExit.extraction : CliExit.download);
    return CliFailure(error.status, _redact(error.reason ?? error.toString()), exit);
  }
  if (error is AllFormatCandidatesFailedException) {
    final inner = classifyError(error.lastError, stage: CliStage.download);
    final message = 'Could not download this video: tried ${error.attempted} format(s) and all failed '
        '(last error: ${inner.message}). Try again, or pick a different --quality or --format-id.';
    // Zero attempts: nothing was ever downloaded, so the inner reason (for
    // example "no downloadable formats") is the whole story.
    if (error.attempted == 0 || _stageIndependent.contains(inner.exitCode)) {
      return CliFailure(inner.code, message, inner.exitCode);
    }
    return CliFailure('DOWNLOAD_FAILED', message, CliExit.download);
  }
  if (error is NoDownloadableFormatsException) {
    // Extraction worked but yielded nothing this app can save: not retryable.
    return CliFailure('NO_DOWNLOADABLE_FORMATS', _redact(error.message), CliExit.extraction);
  }
  if (error is MediaMergeException) {
    return CliFailure('MERGE_FAILED', _redact(error.message), CliExit.download);
  }
  if (error is StreamDownloadException) {
    return CliFailure('DOWNLOAD_FAILED', _redact(error.message), CliExit.download);
  }
  if (error is CaptionDownloadException) {
    return CliFailure('CAPTION_FAILED', _redact(error.message), CliExit.download);
  }
  if (error is HeaderInjectionException) {
    // The message names a page-supplied header; never echo it.
    return const CliFailure(
      'UNSAFE_HEADER',
      'The source supplied a request header that cannot be passed on safely, so the download was refused.',
      CliExit.download,
    );
  }
  if (error is CdpCommandException) {
    // The DevTools error payload may quote page data; report the method only.
    return CliFailure(
      'BROWSER_CAPTURE_FAILED',
      'The browser capture failed (DevTools command ${error.method} returned an error).',
      stage == CliStage.resolve ? CliExit.extraction : CliExit.download,
    );
  }
  if (error is ProcessException) {
    // A helper program could not even be started (missing or not
    // executable). Which one decides the code; all are environment (6).
    // ProcessException.message is the OS's (localized) text: fixed English
    // sentence plus the error number instead, and only the file name.
    final name = _baseName(error.executable);
    final message = 'Could not start $name${_osCode(error.errorCode)}. Check that it is installed.';
    return CliFailure(processFailureCode(error.executable), _redact(message), CliExit.environment);
  }
  if (error is SocketException) {
    return CliFailure(
      'NETWORK',
      'A network connection failed${_osCode(error.osError?.errorCode)}. Check the connection and try again.',
      CliExit.environment,
    );
  }
  if (error is TlsException) {
    return CliFailure(
      'NETWORK',
      'A secure (TLS) connection failed${_osCode(error.osError?.errorCode)}.',
      CliExit.environment,
    );
  }
  if (error is TimeoutException) {
    return const CliFailure('NETWORK', 'A network request timed out. Try again later.', CliExit.environment);
  }
  if (error is HttpException) {
    // Dart's own English message (plus a URL, redacted); no OS text.
    return CliFailure('NETWORK', _redact('HTTP error: ${error.message}'), CliExit.environment);
  }
  final fallbackCode = stage == CliStage.resolve ? 'EXTRACTION_FAILED' : 'DOWNLOAD_FAILED';
  final fallbackExit = stage == CliStage.resolve ? CliExit.extraction : CliExit.download;
  if (error is FileSystemException) {
    final message = 'A file operation failed: ${error.message}${_osCode(error.osError?.errorCode)}.';
    return CliFailure(fallbackCode, _redact(message), fallbackExit);
  }
  return CliFailure(fallbackCode, _redact(error.toString()), fallbackExit);
}

String _baseName(String executable) => executable.replaceAll('\\', '/').split('/').last;

/// ` (OS error N)`, or nothing when there is no usable number. The OS's
/// own message is never included: it is localized (for example Korean on
/// a Korean Windows), and agents key off English text and codes.
String _osCode(int? code) => code == null || code == 0 ? '' : ' (OS error $code)';
