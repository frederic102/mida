import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../extractors/media_models.dart';
import '../net/host_policy.dart';
import 'browser_executable_locator.dart';
import 'browser_profile.dart';

/// Finds a system browser and drives it headless to dump the fully
/// rendered DOM of a page, for sites that only populate `<video>` tags /
/// JSON-LD / og tags after client-side JS runs (e.g. Instagram). Spec:
/// `docs/plan-phase2-extractors.md` SCOPE 1 ("공통") and the Instagram
/// research section it links back to.
///
/// Every invocation gets its own throwaway `--user-data-dir` so concurrent
/// fetches never collide and so no browsing state survives the call; the
/// directory is deleted in a `finally` block regardless of outcome.
class BrowserPageFetcher {
  /// Test-only override: when set, `fetchDom` searches exactly this list
  /// (skipping `MIDA_BROWSER_PATH` and the PATH probe). See
  /// `BrowserExecutableLocator.find`.
  final List<String> Function()? _candidatePaths;
  final Duration timeout;

  /// Test-only escape hatch for the SSRF guard below, so tests can point
  /// the fake browser at a local fixture URL. Production code must never
  /// set this to true. Note this only covers the URL handed to the
  /// browser: redirects the browser itself follows while rendering the
  /// page happen outside this process and are not something we can police
  /// from here (see [fetchDom] doc).
  final bool allowPrivateHosts;

  /// When true (Settings: "Use browser login session"), the launch uses a
  /// staged copy of the user's real browser profile instead of an empty
  /// one, so the rendered page sees the user's own cookies. Default false
  /// keeps today's behavior byte-identical. See
  /// `docs/plan-phase4-cookies-resilience.md` SCOPE 1-2.
  final bool useBrowserLoginSession;

  /// Test injection point for [useBrowserLoginSession]'s staging step, so
  /// tests never touch a real browser profile. Defaults to
  /// [BrowserProfile.stageCopy].
  final Future<Directory?> Function(BrowserProfileKind kind)? _stageProfileDir;

  BrowserPageFetcher({
    List<String> Function()? candidatePaths,
    this.timeout = const Duration(seconds: 60),
    this.allowPrivateHosts = false,
    this.useBrowserLoginSession = false,
    Future<Directory?> Function(BrowserProfileKind kind)? stageProfileDir,
  })  : _candidatePaths = candidatePaths,
        _stageProfileDir = stageProfileDir;

  /// Renders [url] headlessly and returns the dumped DOM as HTML text.
  ///
  /// Throws [MediaExtractionException] with code `UNSUPPORTED_URL` when
  /// [url] itself resolves to a loopback/private/link-local address (SSRF
  /// guard; this does not, and cannot, police redirects the browser
  /// follows on its own once launched), `BROWSER_MISSING` when no
  /// candidate executable exists (message lists everything checked), or
  /// `NETWORK` on timeout / empty output.
  Future<String> fetchDom(Uri url) async {
    if (!allowPrivateHosts && HostPolicy.isDisallowedHost(url)) {
      throw MediaExtractionException(
        'UNSUPPORTED_URL',
        'Refusing to render $url: it resolves to a private, loopback, or link-local '
            'network address. This extractor only follows public internet hosts.',
      );
    }

    final lookup = await BrowserExecutableLocator.find(fixedCandidatePaths: _candidatePaths);
    final executable = lookup.path;
    if (executable == null) {
      throw MediaExtractionException(
        'BROWSER_MISSING',
        'Instagram and other JS-rendered pages need Microsoft Edge, Google Chrome, Brave, or '
            'Vivaldi installed to load. Checked: ${lookup.checkedPaths.join(', ')}.',
      );
    }

    final profileDir = await _resolveProfileDir(executable);
    try {
      return await _renderWith(executable, profileDir, url);
    } finally {
      try {
        if (profileDir.existsSync()) {
          profileDir.deleteSync(recursive: true);
        }
      } catch (_) {
        // Best-effort: a transiently locked profile file should not mask
        // the extraction result (or error) computed above.
      }
    }
  }

  /// A fresh empty temp dir, unless [useBrowserLoginSession] is on and
  /// staging the resolved browser's real profile (see [BrowserProfile])
  /// succeeds - staging failure (unknown browser kind, no profile present,
  /// copy error) falls back to the same empty temp dir as when the toggle
  /// is off, never throws.
  Future<Directory> _resolveProfileDir(String executable) async {
    if (useBrowserLoginSession) {
      final kind = BrowserProfile.kindForExecutable(executable);
      if (kind != null) {
        final stage = _stageProfileDir ?? BrowserProfile.stageCopy;
        final staged = await stage(kind);
        if (staged != null) return staged;
      }
    }
    return Directory.systemTemp.createTempSync('mida_browser_');
  }

  Future<String> _renderWith(String executable, Directory profileDir, Uri url) async {
    final process = await Process.start(executable, [
      '--headless=new',
      '--disable-gpu',
      '--no-first-run',
      '--no-default-browser-check',
      '--user-data-dir=${profileDir.path}',
      '--dump-dom',
      url.toString(),
    ]);

    final stdoutDone = process.stdout.transform(utf8.decoder).join();
    unawaited(process.stderr.drain<void>());

    var timedOut = false;
    await process.exitCode.timeout(
      timeout,
      onTimeout: () {
        timedOut = true;
        process.kill();
        return -1;
      },
    );

    if (timedOut) {
      throw MediaExtractionException(
        'NETWORK',
        'Timed out waiting for the headless browser to render $url '
            '(${timeout.inSeconds}s).',
      );
    }

    final dom = await stdoutDone;
    if (dom.trim().isEmpty) {
      throw MediaExtractionException('NETWORK', 'The headless browser returned an empty page for $url.');
    }
    return dom;
  }
}
