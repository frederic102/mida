/// Chrome/Edge command-line flags for one `BrowserDevtoolsSession.launch`
/// attempt - split out of that file to keep both under this project's
/// 400-line cap, and because this half is a pure function over already-known
/// values (port, profile dir path) with no process or CDP state of its own.
///
/// docs/plan-phase5-coverage.md Lane A (headed-first, 2026-09-05 measurement):
/// a growing set of anti-bot layers (Cloudflare, DataDome) fingerprint
/// `--headless=new` and serve a challenge page or an empty SPA shell instead
/// of the real page - a real, visible browser window gets the real page and
/// the real media requests (measured: dailymotion 0 -> 1 candidate, nytimes
/// 0 -> 2, both from the exact same page, only the headless flag changed).
/// [build] never passes `--enable-automation`: that flag, not the DevTools
/// port itself, is what sets `navigator.webdriver` on current Chromium, so
/// simply not passing it already avoids the one signal measurement found
/// differed between modes on its own (both modes read `false`) - no stealth
/// patch of any kind is applied here. Headed positions the window
/// off-screen (`--window-position=-32000,-32000`) so nothing pops into the
/// user's view during a capture.
class BrowserLaunchArgs {
  const BrowserLaunchArgs._();

  static List<String> build({
    required bool headed,
    required String profileDirPath,
    required int port,
  }) {
    return [
      if (!headed) '--headless=new',
      // Extreme off-screen position keeps nothing visible on the user's
      // desktop; an explicit normal window size (rather than whatever
      // default a position that far off-screen might otherwise pick)
      // keeps the render viewport - and so the page's own responsive
      // layout/autoplay eligibility checks - unremarkable. A code-review
      // pass raised whether the extreme off-screen position could itself
      // be a fingerprint signal; kept as-is deliberately (see class doc):
      // live measurement already shows headed winning decisively over
      // headless today, and there is no live evidence yet that this
      // position specifically costs anything - chasing that without
      // evidence would just be a second unmeasured guess replacing the
      // first.
      if (headed) ...['--window-position=-32000,-32000', '--window-size=1280,720'],
      '--disable-gpu',
      '--no-first-run',
      '--no-default-browser-check',
      '--user-data-dir=$profileDirPath',
      '--remote-debugging-port=$port',
      // Without this, some Chrome/Edge builds bind the DevTools port to
      // every interface rather than just loopback, briefly exposing an
      // unauthenticated remote-control endpoint to the local network for
      // as long as the browser process runs.
      '--remote-debugging-address=127.0.0.1',
      '--mute-audio',
      '--autoplay-policy=no-user-gesture-required',
      'about:blank',
    ];
  }
}
