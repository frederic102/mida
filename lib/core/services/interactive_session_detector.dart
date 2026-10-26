import 'dart:io';

/// Best-effort check for whether this process has an interactive desktop
/// session to open a headed (visible, even if off-screen-positioned)
/// browser window in at all - see docs/plan-phase5-coverage.md Lane A
/// headed-mode robustness. A Windows service running as SYSTEM/with no
/// logged-in session has no `SESSIONNAME` environment variable at all (an
/// interactive logon - console or RDP - always sets one); without an
/// interactive session, attempting a headed launch would only waste the
/// time of watching it fail, so callers should go straight to headless.
///
/// macOS has no equivalent check wired here yet (returns true - assume
/// interactive - since this app targets Windows first); a future
/// LaunchDaemon/no-WindowServer check belongs here, not scattered into
/// `BrowserDevtoolsSession`.
class InteractiveSessionDetector {
  const InteractiveSessionDetector._();

  static bool hasInteractiveSession({Map<String, String>? environment}) {
    if (!Platform.isWindows) return true;
    final sessionName = (environment ?? Platform.environment)['SESSIONNAME'];
    return sessionName != null && sessionName.isNotEmpty;
  }

  /// Environment variable that forces every browser launch headless
  /// (docs/plan-phase7-coverage-agent.md Lane H): `1`, `true` or `yes`
  /// (case-insensitive) turn it on, anything else (including unset) leaves
  /// the default headed-first behavior untouched.
  static const String headlessEnvVar = 'MIDA_HEADLESS';

  static bool isHeadlessForced({Map<String, String>? environment}) {
    final raw = (environment ?? Platform.environment)[headlessEnvVar]?.trim().toLowerCase();
    return raw == '1' || raw == 'true' || raw == 'yes';
  }

  /// The one decision `BrowserDevtoolsSession.launch` makes about whether a
  /// headed attempt is even tried: only when the caller prefers it, the
  /// environment does not force headless, and a desktop session exists.
  static bool shouldTryHeaded({required bool preferHeaded, Map<String, String>? environment}) {
    return preferHeaded &&
        !isHeadlessForced(environment: environment) &&
        hasInteractiveSession(environment: environment);
  }
}
