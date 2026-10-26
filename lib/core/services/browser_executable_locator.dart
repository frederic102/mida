import 'dart:io';

/// One search attempt's outcome: the executable path found (or `null`),
/// plus every path this call actually checked, in order, so a caller can
/// build an honest `BROWSER_MISSING` message ("checked: ...").
class BrowserLookupResult {
  final String? path;
  final List<String> checkedPaths;

  const BrowserLookupResult({required this.path, required this.checkedPaths});

  bool get found => path != null;
}

/// Finds a system browser executable (Chrome/Edge/Brave/Vivaldi) for
/// headless automation, shared by `BrowserPageFetcher` (DOM dump) and
/// `BrowserDevtoolsSession` (CDP capture): same small-locator pattern as
/// `FfmpegLocator` (one place resolves a path, callers just ask for it).
/// Search order:
///   1. `MIDA_BROWSER_PATH` environment variable, if set.
///   2. Fixed per-OS install paths.
///   3. Whatever `where` (Windows) / `which` (macOS/Linux) finds on PATH.
/// The first candidate that exists on disk wins.
class BrowserExecutableLocator {
  const BrowserExecutableLocator._();

  static const List<String> pathProbeNames = ['chrome', 'msedge', 'brave'];

  /// Fixed install-path candidates, in priority order (Chrome, then Edge,
  /// then Brave, then Vivaldi), before the PATH probe. Exposed so a
  /// caller building its own `BROWSER_MISSING` message, or a test that
  /// wants the real list without the env var/PATH-probe steps, can see
  /// exactly what this checks.
  static List<String> defaultFixedCandidatePaths({Map<String, String>? environment}) {
    if (Platform.isMacOS) {
      return const [
        '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
        '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
        '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser',
        '/Applications/Vivaldi.app/Contents/MacOS/Vivaldi',
      ];
    }
    final env = environment ?? Platform.environment;
    final programFilesX86 = env['ProgramFiles(x86)'] ?? r'C:\Program Files (x86)';
    final programFiles = env['ProgramFiles'] ?? r'C:\Program Files';
    final localAppData = env['LOCALAPPDATA'];
    return [
      '$programFiles\\Google\\Chrome\\Application\\chrome.exe',
      if (localAppData != null && localAppData.isNotEmpty) '$localAppData\\Google\\Chrome\\Application\\chrome.exe',
      '$programFilesX86\\Microsoft\\Edge\\Application\\msedge.exe',
      '$programFiles\\Microsoft\\Edge\\Application\\msedge.exe',
      '$programFiles\\BraveSoftware\\Brave-Browser\\Application\\brave.exe',
      if (localAppData != null && localAppData.isNotEmpty)
        '$localAppData\\BraveSoftware\\Brave-Browser\\Application\\brave.exe',
      '$programFiles\\Vivaldi\\Application\\vivaldi.exe',
      if (localAppData != null && localAppData.isNotEmpty) '$localAppData\\Vivaldi\\Application\\vivaldi.exe',
    ];
  }

  /// True when [path]'s file name is Google Chrome's (`chrome.exe` on
  /// Windows, `Google Chrome` on macOS). The file name only, so a folder
  /// called `chrome` or a `chromium.exe` does not count.
  static bool isChromePath(String path) {
    final name = path.split(RegExp(r'[\\/]')).last.toLowerCase();
    return name == 'chrome.exe' || name == 'chrome' || name == 'google chrome';
  }

  /// Finds the first working candidate.
  ///
  /// When [fixedCandidatePaths] is supplied (tests only: this is how
  /// `BrowserPageFetcher`/`BrowserDevtoolsSession` keep their existing
  /// `candidatePaths` test-injection parameter working unchanged), the
  /// search is limited to exactly that list, skipping the environment
  /// variable and PATH probe entirely, for a fully deterministic test.
  /// Otherwise the full production search runs: `MIDA_BROWSER_PATH`, then
  /// [defaultFixedCandidatePaths], then [probePath].
  ///
  /// With [chromeOnly] (browser login session: the signed-in profile staged
  /// is Chrome's), only Google Chrome qualifies: `MIDA_BROWSER_PATH` must
  /// name `chrome.exe` / `Google Chrome`, and every other candidate list
  /// (including [fixedCandidatePaths]) is filtered the same way. No Edge fallback.
  ///
  /// [exists] and [probePath] are independently injectable so tests can
  /// exercise the environment-variable and PATH-probe steps hermetically
  /// (without touching the real filesystem or PATH) while still calling
  /// production's own search order.
  static Future<BrowserLookupResult> find({
    List<String> Function()? fixedCandidatePaths,
    Future<bool> Function(String path)? exists,
    Future<List<String>> Function()? probePath,
    Map<String, String>? environment,
    bool chromeOnly = false,
  }) async {
    final checkExists = exists ?? (path) => File(path).exists();
    final checked = <String>[];

    Future<BrowserLookupResult?> tryPath(String path) async {
      checked.add(path);
      return await checkExists(path) ? BrowserLookupResult(path: path, checkedPaths: checked) : null;
    }

    Iterable<String> only(Iterable<String> paths) => chromeOnly ? paths.where(isChromePath) : paths;

    if (fixedCandidatePaths != null) {
      for (final path in only(fixedCandidatePaths())) {
        final hit = await tryPath(path);
        if (hit != null) return hit;
      }
      return BrowserLookupResult(path: null, checkedPaths: checked);
    }

    final env = environment ?? Platform.environment;
    final override = env['MIDA_BROWSER_PATH'];
    if (override != null && override.isNotEmpty && only([override]).isNotEmpty) {
      final hit = await tryPath(override);
      if (hit != null) return hit;
    }

    for (final path in only(defaultFixedCandidatePaths(environment: env))) {
      final hit = await tryPath(path);
      if (hit != null) return hit;
    }

    for (final path in only(await (probePath ?? _probePath)())) {
      if (checked.contains(path)) continue;
      final hit = await tryPath(path);
      if (hit != null) return hit;
    }

    return BrowserLookupResult(path: null, checkedPaths: checked);
  }

  /// `where chrome msedge brave` on Windows, `which chrome msedge brave`
  /// elsewhere. Both accept an argument list (no shell string is built),
  /// print whichever names resolved (one per line) to stdout, and print
  /// the rest as "not found" to stderr without failing the whole command
  /// as long as at least one name resolved - so stdout is read regardless
  /// of the exit code, and a total failure (command missing, or none of
  /// the names found) is swallowed into an empty list rather than
  /// thrown, since PATH probing is a best-effort supplementary step.
  static Future<List<String>> _probePath() async {
    try {
      final result = await Process.run(Platform.isWindows ? 'where' : 'which', pathProbeNames);
      final stdout = result.stdout;
      if (stdout is! String || stdout.isEmpty) return const [];
      return stdout.split(RegExp(r'\r?\n')).map((line) => line.trim()).where((line) => line.isNotEmpty).toList();
    } catch (_) {
      return const [];
    }
  }
}
