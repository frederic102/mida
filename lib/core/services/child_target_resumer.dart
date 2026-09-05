import 'cdp_client.dart';

/// Handles one auto-attached child target (`Target.attachedToTarget`,
/// itself paused by `waitForDebuggerOnStart: true` until this runs): attempts
/// `Fetch`/`Network` enabling for the target types listed in
/// [fetchInterceptedTargetTypes], then *always* resumes it
/// (`Runtime.runIfWaitingForDebugger`) regardless of what happened above -
/// split out of `browser_devtools_session.dart` to keep that file under
/// this project's 400-line cap.
///
/// Independent review round 3: a target of any type CDP rejects
/// `Fetch.enable`/`Network.enable` for (observed live: worker/
/// service_worker targets, which modern video SPAs - Douyin/VK/OK.ru -
/// lean on heavily) used to stay paused *forever* under a shape that only
/// resumed the target after those calls succeeded, hanging the whole page
/// (and the capture) for its full timeout budget. Resume now runs in a
/// `finally`, unconditionally.
///
/// Round 4 (coordinator security follow-up): once resume was made
/// unconditional, restricting `Fetch`/`Network` enabling to `page`/`iframe`
/// stopped being a deadlock-safety measure and became a plain coverage gap
/// instead - a `shared_worker`/`service_worker` target can itself issue
/// requests (e.g. a service worker proxying/caching fetches), and none of
/// those were ever adjudicated by `PrivateDestinationGuard` at all. Widened
/// [fetchInterceptedTargetTypes] to also attempt these worker types; each
/// `Fetch.enable`/`Network.enable` call is still individually wrapped in
/// its own `try`/`catch` (a target type CDP genuinely does not support the
/// domain on - if any - simply skips that one call and still resumes via
/// the outer `finally`, exactly as it always has for an unrecognized
/// type). No live CDP session was available to confirm which of these
/// worker types actually accept `Fetch.enable` in the Chromium build this
/// app launches; this comment (and the try/catch itself) is the
/// documentation for "else" per the coordinator's own ask.
class ChildTargetResumer {
  const ChildTargetResumer._();

  static const Set<String> fetchInterceptedTargetTypes = {
    'page',
    'iframe',
    'worker',
    'shared_worker',
    'service_worker',
  };

  static const Map<String, dynamic> fetchEnableParams = {
    'patterns': [
      {'urlPattern': '*'}
    ],
  };

  static Future<void> handle(
    CdpClient cdp,
    String childSessionId, {
    required String? targetType,
  }) async {
    try {
      if (fetchInterceptedTargetTypes.contains(targetType)) {
        try {
          await cdp.send('Fetch.enable', params: fetchEnableParams, sessionId: childSessionId);
        } catch (_) {
          // Not fatal to this target's own resume below.
        }
        try {
          await cdp.send('Network.enable', sessionId: childSessionId);
        } catch (_) {
          // Same.
        }
      }
    } finally {
      try {
        await cdp.send('Runtime.runIfWaitingForDebugger', sessionId: childSessionId);
      } catch (_) {
        // Target already closed/gone between attach and resume; that is
        // not a capture failure on its own.
      }
    }
  }
}
