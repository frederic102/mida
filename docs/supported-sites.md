# Supported Sites

Last updated 2026-09-06 (v2.2.0). This list reflects what is registered in
`lib/core/extractors/extractor_registry_builder.dart` and what MiDa's
generic/browser-capture tiers can reach today. Sites change their pages and
anti-bot layers without notice, so treat this as a snapshot, not a promise.

## Native extractors

These sites have a dedicated extractor that calls the same public playback
endpoint the site's own web or embed player calls. They are the fastest and
most reliable path, and are tried before generic page analysis.

| Site | URL shape | Notes |
|---|---|---|
| YouTube | `youtube.com/watch?v=...`, `youtu.be/...` | |
| X (Twitter) | `x.com` / `twitter.com` status URLs | |
| TikTok | `tiktok.com/@user/video/...` | |
| Instagram | `instagram.com/reel/...`, `/p/...` | |
| Naver TV | `tv.naver.com/v/<id>` | Naver announced Naver TV will shut down on 2026-09-30. Existing links will stop working after that date regardless of MiDa. |
| CHZZK | `chzzk.naver.com/video/<no>` | VOD only. Live broadcasts (`chzzk.naver.com/live/...`) are out of scope and are not matched by this extractor. |
| Kakao TV | `tv.kakao.com/.../cliplink/<id>` | Kakao's public video service has already ended. MiDa still recognizes the URL and returns a clear "not found" instead of wasting time on a browser capture that could never succeed. Kept so the error is honest rather than silent. |
| Dailymotion | `dailymotion.com/video/<id>` | The page resolves natively. On some videos the actual video CDN blocks this app's own TLS connection even though a format was found; see Not Supported below. |
| Twitch | `twitch.tv/videos/<id>` (VOD), `clips.twitch.tv/<slug>` (clips) | Live channel pages are not supported, only VODs and clips. |
| Reddit | `reddit.com/r/.../comments/...` | Covers `v.redd.it` hosted video via its DASH manifest. |
| SoundCloud | `soundcloud.com/<user>/<track>` | Audio only. |
| Bilibili | `bilibili.com/video/<BV id>` | |
| Douyin | `douyin.com/video/<id>` | |
| Niconico | `nicovideo.jp/watch/<id>` | |
| Odysee | `odysee.com/@channel/video` | |

## Other sites

Any other `http(s)` URL is handled in two steps, tried in order:

1. **Generic page analysis** - fetches the page and looks for `og:video`
   meta tags, JSON-LD, inline JSON state blobs (`__NEXT_DATA__`,
   `__INITIAL_STATE__`, `__NUXT__`, `__APOLLO_STATE__`), an oEmbed link, HLS
   or DASH manifests, and common `data-*` video attributes. This step never
   launches a browser.
2. **Browser capture** - if step 1 finds nothing, MiDa launches your
   installed Edge or Chrome as a real, visible-to-the-OS but off-screen
   window, loads the page, dismisses consent/age-gate overlays, tries to
   start playback, and records the actual media requests the page makes.
   This is what lets MiDa follow a site with no dedicated extractor and no
   server-rendered media links. It only falls back to a fully headless
   browser if a real window cannot launch on the machine (for example a
   non-interactive service session).

See `docs/coverage-corpus.md` for the exact list of sites this has been
verified against and what "verified" means there.

## Not supported

- **DRM-protected content** (Widevine, PlayReady, FairPlay). MiDa detects
  DRM signals in a manifest or page and stops with a clear error; it does
  not attempt to decrypt or bypass DRM.
- **Login-only or age-gated content**, unless the "Use browser login
  session" toggle in Settings is turned on and your own browser is already
  signed in to that site. With the toggle off (the default), MiDa never
  reads or copies your cookies, so any content requiring a sign-in fails
  with a clear "sign-in required" error instead.
- **Live streams.** MiDa downloads finished videos (VODs, clips, posts),
  not in-progress broadcasts.
- **Servers whose TLS certificate this machine's OS does not trust.** Some
  CDNs (observed on certain Russian video hosts) present a certificate
  chain the OS rejects. MiDa will not disable certificate verification to
  work around this, so the download fails with a specific message rather
  than a silent bypass.
- **Sites whose CDN blocks non-browser TLS connections.** Observed on
  Dailymotion's video CDN: the exact same request that succeeds from a
  real browser or `curl` is rejected when made from this app's own network
  stack, most likely because the CDN fingerprints the TLS handshake itself
  (not headers or user-agent). MiDa does not spoof a browser's TLS
  fingerprint to get around this.

## Policy

MiDa calls the same public endpoints a site's own web player calls, and
when that is not enough, it runs a real, honest system browser to see what
the page itself requests. It never solves bot or CAPTCHA challenges, never
spoofs a browser's TLS or JavaScript fingerprint, never rotates IP
addresses, and never bypasses DRM or certificate checks. When a site
changes the contract its player relies on, MiDa stops working there until
it is updated to match the new contract.
