import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../extractors/media_models.dart';
import 'browser_executable_locator.dart';
import 'browser_profile.dart';
import 'cdp_client.dart';

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

  Future<void> close();
}

/// Drives a headless system browser (Edge/Chrome) over the Chrome DevTools
/// Protocol. Spec: `docs/plan-browser-capture.md`. Launches its own
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
  StreamSubscription<CdpEvent>? _autoAttachSubscription;

  BrowserDevtoolsSession._(this._process, this._profileDir, this._cdp, this._sessionId, this.targetId)
      : _attachedSessionIds = {_sessionId};

  static Future<int> _reserveFreePort() async {
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();
    return port;
  }

  /// A fresh empty temp dir, unless [useBrowserLoginSession] is on and
  /// staging [executable]'s real profile (see [BrowserProfile]) succeeds -
  /// staging failure (unknown browser kind, no profile present, copy
  /// error) falls back to the same empty temp dir as when the toggle is
  /// off, never throws. Same fallback shape as
  /// `BrowserPageFetcher._resolveProfileDir`.
  static Future<Directory> _resolveProfileDir(
    String executable, {
    required bool useBrowserLoginSession,
    Future<Directory?> Function(BrowserProfileKind kind)? stageProfileDir,
  }) async {
    if (useBrowserLoginSession) {
      final kind = BrowserProfile.kindForExecutable(executable);
      if (kind != null) {
        final stage = stageProfileDir ?? BrowserProfile.stageCopy;
        final staged = await stage(kind);
        if (staged != null) return staged;
      }
    }
    return Directory.systemTemp.createTempSync('mida_cdp_');
  }

  /// Launches a fresh headless browser instance and attaches to a new
  /// `about:blank` target, with `Network`/`Page`/`Runtime` already enabled
  /// on it. Throws [MediaExtractionException] (`BROWSER_MISSING` when no
  /// candidate executable exists, message lists everything checked;
  /// `NETWORK` if the DevTools endpoint never comes up within
  /// [connectTimeout] or the CDP handshake fails), always killing the
  /// process and deleting the profile directory first.
  static Future<BrowserDevtoolsSession> launch({
    List<String> Function()? candidatePaths,
    Duration connectTimeout = const Duration(seconds: 10),
    bool useBrowserLoginSession = false,
    Future<Directory?> Function(BrowserProfileKind kind)? stageProfileDir,
  }) async {
    final lookup = await BrowserExecutableLocator.find(fixedCandidatePaths: candidatePaths);
    final executable = lookup.path;
    if (executable == null) {
      throw MediaExtractionException(
        'BROWSER_MISSING',
        'Browser network capture needs Microsoft Edge, Google Chrome, Brave, or Vivaldi installed. '
            'Checked: ${lookup.checkedPaths.join(', ')}.',
      );
    }

    final port = await _reserveFreePort();
    final profileDir = await _resolveProfileDir(
      executable,
      useBrowserLoginSession: useBrowserLoginSession,
      stageProfileDir: stageProfileDir,
    );
    Process? process;
    try {
      process = await Process.start(executable, [
        '--headless=new',
        '--disable-gpu',
        '--no-first-run',
        '--no-default-browser-check',
        '--user-data-dir=${profileDir.path}',
        '--remote-debugging-port=$port',
        // Without this, some Chrome/Edge builds bind the DevTools port to
        // every interface rather than just loopback, briefly exposing an
        // unauthenticated remote-control endpoint to the local network
        // for as long as the browser process runs.
        '--remote-debugging-address=127.0.0.1',
        '--mute-audio',
        '--autoplay-policy=no-user-gesture-required',
        'about:blank',
      ]);
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
      await _deleteProfileQuietly(profileDir);
      if (e is MediaExtractionException) rethrow;
      throw MediaExtractionException('NETWORK', 'Failed to start a browser DevTools session: $e');
    }
  }

  /// Kills [process] and waits for it to actually exit (escalating to
  /// `SIGKILL` and waiting again, briefly, if it does not exit within
  /// [timeout]) before returning. Exposed (not private) so tests can drive
  /// it directly against a fake `Process` without needing a real OS
  /// process; production code only reaches it via [launch]'s failure path
  /// and [close].
  static Future<void> killAndAwaitExit(Process process, {Duration timeout = const Duration(seconds: 5)}) async {
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

    // Must be wired before `Target.setAutoAttach` is requested: Chrome can
    // fire `Target.attachedToTarget` for an already-loading child target
    // as soon as auto-attach is turned on, and a listener attached after
    // that call could lose the very first one.
    session._autoAttachSubscription = cdp.events.listen((event) => session._onCdpEvent(event));

    // `waitForDebuggerOnStart: false`: child targets (iframes) start
    // running immediately on attach rather than pausing for us to call
    // `Runtime.runIfWaitingForDebugger`, so there is no matching call to
    // make here for that flag.
    await session.send('Target.setAutoAttach', const {
      'autoAttach': true,
      'waitForDebuggerOnStart': false,
      'flatten': true,
    });

    return session;
  }

  void _onCdpEvent(CdpEvent event) {
    if (event.method != 'Target.attachedToTarget') return;
    final childSessionId = event.params['sessionId'] as String?;
    if (childSessionId == null || !_attachedSessionIds.add(childSessionId)) return;
    unawaited(() async {
      try {
        await _cdp.send('Network.enable', sessionId: childSessionId);
      } catch (_) {
        // A child target that closes before we finish enabling Network on
        // it just never contributes events; that is not a capture failure
        // on its own (other targets, or this one on a later attach, may
        // still supply the media).
      }
    }());
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
      'Timed out waiting for the headless browser DevTools endpoint to come up.',
    );
  }

  static Future<void> _deleteProfileQuietly(Directory dir) async {
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      return;
    } catch (_) {
      // A just-killed browser process's profile files can stay briefly
      // locked (Windows file-handle release, antivirus scan); one short
      // retry clears most of these instead of leaking the directory.
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (_) {
      // Still locked; leave it - best-effort cleanup must never mask
      // whatever error or result the caller already has.
    }
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
    await _deleteProfileQuietly(_profileDir);
  }
}
