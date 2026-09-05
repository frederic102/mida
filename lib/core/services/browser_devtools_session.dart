import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../extractors/media_models.dart';
import 'browser_executable_locator.dart';
import 'browser_launch_args.dart';
import 'browser_launch_resources.dart';
import 'browser_process_tree.dart';
import 'browser_profile.dart';
import 'browser_temp_cleanup.dart';
import 'cdp_client.dart';
import 'child_target_resumer.dart';
import 'interactive_session_detector.dart';

/// The surface `BrowserCaptureExtractor` needs from a live DevTools
/// session. Extracted as an interface so tests can substitute a fake
/// (in-memory event stream, canned command replies) instead of a real
/// browser process and WebSocket. [BrowserDevtoolsSession] is the only
/// production implementation.
abstract class DevtoolsSession {
  /// Every CDP event seen so far on this attached target's session
  /// (`Network.*`, `Page.*`, `Runtime.*`).
  Stream<CdpEvent> get events;

  /// Sends a command scoped to the attached target's session.
  Future<Map<String, dynamic>> send(String method, [Map<String, dynamic>? params]);

  /// Sends a browser-level command (`Target.*`, `Browser.*`, not scoped to
  /// any one attached target).
  Future<Map<String, dynamic>> sendBrowserLevel(String method, [Map<String, dynamic>? params]);

  /// Every child target's session id auto-attached so far (a cross-origin
  /// `<iframe>` running its own render process under Chrome's site
  /// isolation), excluding the top-level target's own session - see
  /// [PlaybackTrigger] for why a caller needs to reach these directly
  /// rather than only ever driving the top-level document.
  List<String> get childSessionIds;

  /// Sends [method] scoped to one specific attached session - [sessionId]
  /// may be the top-level target's own session or one of
  /// [childSessionIds] - so a playback trigger can run inside an iframe
  /// exactly as it would on the top-level page.
  Future<Map<String, dynamic>> sendToSession(String sessionId, String method, [Map<String, dynamic>? params]);

  Future<void> close();
}

/// Drives a system browser (Edge/Chrome) over the Chrome DevTools Protocol -
/// headed by default, off-screen (see [BrowserLaunchArgs]), headless only as
/// a fallback if a headed launch fails outright. Spec:
/// `docs/plan-browser-capture.md`. Launches its own
/// throwaway profile directory and picks a free debugging port per call so
/// concurrent captures never collide; both are always cleaned up, whether
/// launch succeeds, fails partway through, or a caller-driven capture later
/// throws (guaranteed by [close] and by the `catch` block in [launch]).
///
/// Executable search is `BrowserExecutableLocator.find` (council follow-up
/// F4): shared with `BrowserPageFetcher` instead of each keeping its own
/// candidate-path list.
class BrowserDevtoolsSession implements DevtoolsSession {
  final Process _process;
  final Directory _profileDir;
  final CdpClient _cdp;
  final String _sessionId;
  final String targetId;

  /// Every session id whose events should be visible on [events]: the
  /// top-level target's own [_sessionId] plus every child target CDP
  /// auto-attached us to (e.g. a cross-origin `<iframe>` running its own
  /// render process under Chrome's site isolation - Vimeo's actual player
  /// lives in exactly such an iframe, `player.vimeo.com`, so without this
  /// its `Network.responseReceived` events are invisible to a session
  /// only attached to the top-level `vimeo.com` target).
  final Set<String> _attachedSessionIds;

  /// [_attachedSessionIds] minus the top-level target's own [_sessionId] -
  /// see [childSessionIds].
  final Set<String> _childSessionIds = {};
  StreamSubscription<CdpEvent>? _autoAttachSubscription;

  BrowserDevtoolsSession._(this._process, this._profileDir, this._cdp, this._sessionId, this.targetId)
      : _attachedSessionIds = {_sessionId};


  /// Launches a fresh browser instance and attaches to a new `about:blank`
  /// target, with `Network`/`Page`/`Runtime` already enabled on it. Throws
  /// [MediaExtractionException] (`BROWSER_MISSING` when no candidate
  /// executable exists, message lists everything checked; `NETWORK` if the
  /// DevTools endpoint never comes up within [connectTimeout] or the CDP
  /// handshake fails), always killing the process and deleting the profile
  /// directory first.
  ///
  /// Tries a headed (visible, off-screen-positioned) launch first, falling
  /// back to `--headless=new` if that attempt itself fails to come up at
  /// all, or is skipped upfront when [preferHeaded] is false or this
  /// process has no interactive desktop session at all (see
  /// [InteractiveSessionDetector]) - see [BrowserLaunchArgs] for why headed
  /// is the default otherwise. This is strictly about whether the
  /// *browser process and CDP session* come up; it has nothing to do with
  /// whether a given page later turns out to have media (a caller
  /// noticing the page itself never loaded under a headed session is
  /// `BrowserCaptureExtractor`'s own whole-capture retry, one layer up).
  static Future<BrowserDevtoolsSession> launch({
    List<String> Function()? candidatePaths,
    Duration connectTimeout = const Duration(seconds: 10),
    bool useBrowserLoginSession = false,
    bool preferHeaded = true,
    Future<Directory?> Function(BrowserProfileKind kind)? stageProfileDir,
  }) async {
    // Fire-and-forget: a slow/locked temp dir must never add latency to
    // this capture's own launch.
    unawaited(BrowserTempCleanup.sweepStale());

    final lookup = await BrowserExecutableLocator.find(fixedCandidatePaths: candidatePaths);
    final executable = lookup.path;
    if (executable == null) {
      throw MediaExtractionException(
        'BROWSER_MISSING',
        'Browser network capture needs Microsoft Edge, Google Chrome, Brave, or Vivaldi installed. '
            'Checked: ${lookup.checkedPaths.join(', ')}.',
      );
    }

    if (!preferHeaded || !InteractiveSessionDetector.hasInteractiveSession()) {
      return _launchAttempt(
        executable,
        headed: false,
        connectTimeout: connectTimeout,
        useBrowserLoginSession: useBrowserLoginSession,
        stageProfileDir: stageProfileDir,
      );
    }

    try {
      return await _launchAttempt(
        executable,
        headed: true,
        connectTimeout: connectTimeout,
        useBrowserLoginSession: useBrowserLoginSession,
        stageProfileDir: stageProfileDir,
      );
    } catch (_) {
      return await _launchAttempt(
        executable,
        headed: false,
        connectTimeout: connectTimeout,
        useBrowserLoginSession: useBrowserLoginSession,
        stageProfileDir: stageProfileDir,
      );
    }
  }

  static Future<BrowserDevtoolsSession> _launchAttempt(
    String executable, {
    required bool headed,
    required Duration connectTimeout,
    required bool useBrowserLoginSession,
    required Future<Directory?> Function(BrowserProfileKind kind)? stageProfileDir,
  }) async {
    final port = await BrowserLaunchResources.reserveFreePort();
    final profileDir = await BrowserLaunchResources.resolveProfileDir(
      executable,
      useBrowserLoginSession: useBrowserLoginSession,
      stageProfileDir: stageProfileDir,
    );
    Process? process;
    try {
      process = await Process.start(
        executable,
        BrowserLaunchArgs.build(headed: headed, profileDirPath: profileDir.path, port: port),
      );
      // `drain<void>()`, not `drain<List<int>>()`: with no explicit
      // futureValue argument, `Stream.drain` casts `null` to its type
      // parameter, and `null as List<int>` throws synchronously (`void`
      // is the type this idiom is meant for). Matches
      // `BrowserPageFetcher`'s convention for the same reason.
      unawaited(process.stdout.drain<void>());
      unawaited(process.stderr.drain<void>());

      final webSocketUrl = await _pollForWebSocketUrl(port, connectTimeout);
      final cdp = await CdpClient.connect(Uri.parse(webSocketUrl));
      return await attachToConnectedClient(cdp, process, profileDir);
    } catch (e) {
      // Must await the process actually exiting before deleting its
      // profile dir: a fire-and-forget `process.kill()` followed
      // immediately by `deleteSync` races the OS tearing the process down
      // (observed leaking a `mida_cdp_*` dir on Windows roughly 1 run in
      // 4 without this).
      if (process != null) await killAndAwaitExit(process);
      final cleanedUp = await BrowserTempCleanup.deleteQuietly(profileDir);
      final cleanupNote =
          cleanedUp ? '' : ' A temporary browser profile folder could not be removed and may remain in your system temp directory.';
      if (e is MediaExtractionException) {
        throw MediaExtractionException(e.status, '${e.reason ?? ''}$cleanupNote');
      }
      throw MediaExtractionException('NETWORK', 'Failed to start a browser DevTools session: $e$cleanupNote');
    }
  }

  /// Sweeps [BrowserProcessTree] over [process]'s own pid *first* - while
  /// the parent is still alive - then kills [process] itself and waits
  /// for it to exit (escalating to `SIGKILL`, waiting again, if it does
  /// not within [timeout]). Exposed so tests can drive it directly against
  /// a fake `Process`; production reaches it via [launch]'s failure path
  /// and [close]. [processTreeKiller] test-overrides
  /// [BrowserProcessTree.kill]'s own `runner` (never set in production).
  ///
  /// Order matters (independent review round 2): `taskkill /T` walks the
  /// *live* tree rooted at a pid - once the parent has already exited (as
  /// calling this the other way around left it), Windows can no longer
  /// reliably attribute child renderer/GPU processes to it, orphaning them
  /// instead of killing them.
  static Future<void> killAndAwaitExit(
    Process process, {
    Duration timeout = const Duration(seconds: 5),
    Future<ProcessResult> Function(String executable, List<String> arguments)? processTreeKiller,
  }) async {
    await BrowserProcessTree.kill(process.pid, runner: processTreeKiller);
    try {
      process.kill();
      await process.exitCode.timeout(
        timeout,
        onTimeout: () async {
          process.kill(ProcessSignal.sigkill);
          try {
            return await process.exitCode.timeout(const Duration(seconds: 2), onTimeout: () => -1);
          } catch (_) {
            return -1;
          }
        },
      );
    } catch (_) {
      // Best-effort: if even querying exitCode throws, there is nothing
      // further to synchronize on before the caller attempts its delete.
    }
  }

  /// Does the target-attach + domain-enable + child-target auto-attach
  /// handshake against an already-connected [cdp]. Split out of [launch]
  /// so tests can drive it against a fake DevTools WebSocket endpoint with
  /// a fake [Process] stand-in, without spawning a real browser or polling
  /// a real port; production code should call [launch] instead.
  static Future<BrowserDevtoolsSession> attachToConnectedClient(
    CdpClient cdp,
    Process process,
    Directory profileDir,
  ) async {
    // Defeats the TOCTOU window between reserving a port and connecting to
    // it: something else could have bound that port in the meantime (a
    // stale leftover process, or - on a shared/compromised machine -
    // something deliberately listening there to be mistaken for our
    // browser). Verifying the endpoint actually identifies as a Chromium
    // build before sending it any further commands means we never attach
    // a target, enable Network, or navigate against an impostor.
    final version = await cdp.send('Browser.getVersion');
    final product = (version['product'] as String?) ?? '';
    final isRecognizedBrowser =
        product.startsWith('Chrome/') || product.startsWith('HeadlessChrome/') || product.contains('Edg');
    if (!isRecognizedBrowser) {
      await cdp.close();
      throw MediaExtractionException(
        'NETWORK',
        'Unexpected DevTools endpoint (reported product "$product"); refusing to drive it.',
      );
    }

    final created = await cdp.send('Target.createTarget', params: const {'url': 'about:blank'});
    final targetId = created['targetId'] as String;
    final attached = await cdp.send(
      'Target.attachToTarget',
      params: {'targetId': targetId, 'flatten': true},
    );
    final sessionId = attached['sessionId'] as String;

    final session = BrowserDevtoolsSession._(process, profileDir, cdp, sessionId, targetId);
    await session.send('Network.enable');
    await session.send('Page.enable');
    await session.send('Runtime.enable');
    // Lane A hardening: pauses every request this target makes so
    // PrivateDestinationGuard can fail one bound for a disallowed host
    // before it ever leaves the machine - see that file's own docstring.
    await session.send('Fetch.enable', ChildTargetResumer.fetchEnableParams);

    // Must be wired before `Target.setAutoAttach` is requested: Chrome can
    // fire `Target.attachedToTarget` for an already-loading child target
    // as soon as auto-attach is turned on, and a listener attached after
    // that call could lose the very first one.
    session._autoAttachSubscription = cdp.events.listen((event) => session._onCdpEvent(event));

    // `waitForDebuggerOnStart: true`: a child target (iframe) is paused
    // the instant it attaches, running nothing at all - no script, no
    // request - until we explicitly resume it in [_onCdpEvent], after
    // `Fetch`/`Network` are already enabled on its own session. Without
    // this, a child could fire its first request(s) in the window between
    // attach and our own async `Fetch.enable` landing, and
    // `PrivateDestinationGuard` would never even see them (independent
    // review round 2: a real gap in the guard, not just a theoretical
    // one).
    await session.send('Target.setAutoAttach', const {
      'autoAttach': true,
      'waitForDebuggerOnStart': true,
      'flatten': true,
    });

    return session;
  }

  void _onCdpEvent(CdpEvent event) {
    if (event.method != 'Target.attachedToTarget') return;
    final childSessionId = event.params['sessionId'] as String?;
    if (childSessionId == null || !_attachedSessionIds.add(childSessionId)) return;
    _childSessionIds.add(childSessionId);

    final targetInfo = event.params['targetInfo'];
    final targetType = targetInfo is Map ? targetInfo['type'] as String? : null;
    unawaited(ChildTargetResumer.handle(_cdp, childSessionId, targetType: targetType));
  }

  static Future<String> _pollForWebSocketUrl(int port, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse('http://127.0.0.1:$port/json/version'));
        final response = await request.close();
        final body = await response.transform(utf8.decoder).join();
        final json = jsonDecode(body) as Map<String, dynamic>;
        final webSocketUrl = json['webSocketDebuggerUrl'] as String?;
        if (webSocketUrl != null && webSocketUrl.isNotEmpty) return webSocketUrl;
      } catch (_) {
        // DevTools endpoint is not up yet (or the process died); retry
        // until the deadline instead of failing on the first attempt.
      } finally {
        client.close(force: true);
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    throw const MediaExtractionException(
      'NETWORK',
      'Timed out waiting for the browser DevTools endpoint to come up.',
    );
  }

  @override
  Stream<CdpEvent> get events =>
      _cdp.events.where((e) => e.sessionId != null && _attachedSessionIds.contains(e.sessionId));

  @override
  Future<Map<String, dynamic>> send(String method, [Map<String, dynamic>? params]) =>
      _cdp.send(method, params: params, sessionId: _sessionId);

  @override
  Future<Map<String, dynamic>> sendBrowserLevel(String method, [Map<String, dynamic>? params]) =>
      _cdp.send(method, params: params);

  @override
  List<String> get childSessionIds => _childSessionIds.toList(growable: false);

  @override
  Future<Map<String, dynamic>> sendToSession(String sessionId, String method, [Map<String, dynamic>? params]) =>
      _cdp.send(method, params: params, sessionId: sessionId);

  @override
  Future<void> close() async {
    try {
      await _autoAttachSubscription?.cancel();
    } catch (_) {}
    try {
      await sendBrowserLevel('Browser.close').timeout(const Duration(seconds: 3), onTimeout: () => const {});
    } catch (_) {
      // The renderer may already be gone; the process kill below is the
      // real guarantee, this is just a polite ask first.
    }
    try {
      await _cdp.close();
    } catch (_) {}
    await killAndAwaitExit(_process);
    await BrowserTempCleanup.deleteQuietly(_profileDir);
  }
}
