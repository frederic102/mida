# Supported Sites

Last updated 2026-10-25 (v2.4.0). This list reflects what is registered in
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
| Naver TV | `tv.naver.com/v/<id>` | Naver TV shut down on 2026-09-30. The extractor is kept so the URL gets a clear error instead of a browser capture, but no Naver TV link is expected to work any more. |
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
| Vimeo | `vimeo.com/<id>`, `vimeo.com/<id>/<unlisted hash>`, `player.vimeo.com/video/<id>` | Progressive mp4 and an HLS master, read from the same unauthenticated player-config endpoint Vimeo's own web player calls. A private/unlisted video without the right hash is a login wall: it falls through to generic analysis and browser capture (which can use your signed-in browser when the "Use browser login session" toggle is on), and if those fail too it is reported as login required. |
| Facebook | `facebook.com/<page>/videos/<id>`, `/watch/?v=<id>`, `/reel/<id>`, `/share/v/<slug>`, `fb.watch/<slug>` | Public videos only, read from the server-rendered data Facebook's own web player starts from (no cookies sent). A login wall falls through to generic analysis and browser capture; turn on the "Use browser login session" toggle for videos that need a signed-in browser. The page shapes are taken from public notes and are not yet confirmed live. |
| Pinterest | `pinterest.<tld>/pin/<id>/`, `pin.it/<code>` | Video pins and story pins (first video block only) via the anonymous pin resource call. Image pins report "no video". Short links may only lead to a Pinterest pin. Not yet confirmed live. |
| SOOP (AfreecaTV) | `vod.sooplive.co.kr/player/<n>`, `vod.afreecatv.com/player/<n>` | VOD only, no live streams. A multi-part VOD returns part 1 only, marked "(part 1 of N)" in the title. Adult, password and members-only VODs need a login session. Not yet confirmed live. |
| LinkedIn | `linkedin.com/posts/<slug>`, `linkedin.com/feed/update/urn:li:activity:<id>`, `linkedin.com/embed/feed/update/...` | Public video posts only. Learning courses, profiles and posts behind the sign-in wall are not supported (LinkedIn's anonymous wall falls through to the browser tier). Not yet confirmed live. |
| Xiaohongshu (RedNote) | `xiaohongshu.com/explore/<id>`, `xiaohongshu.com/discovery/item/<id>`, `xhslink.com/<code>` | Video notes only. Image-only notes report "no video". An empty note shell is treated as a bot wall and falls through to the browser tier. Share links should keep their `xsec_token`. Not yet confirmed live. |
| Telegram | `t.me/<channel>/<id>`, `t.me/s/<channel>/<id>` | Public channel posts only, read from the same embed page Telegram's own "Embed post" widget loads (no login, no cookies). In an album only the video of the linked post is returned, a post with several videos gives the first, and a channel page shown instead of the post falls through to the other tiers, and only an explicit private message reports login required. Not yet confirmed live. |
| Rumble | `rumble.com/<slug>.html`, `rumble.com/embed/<id>` | Mp4/webm renditions per height plus the HLS stream, from the same data call Rumble's own embed player makes (no cookies sent). Live streams without a recording and DRM are reported, not bypassed. Not yet confirmed live. |
| Streamable | `streamable.com/<code>`, `streamable.com/e/<code>` | `mp4` and `mp4-mobile`, from the API Streamable's own player calls. A video that is still processing says so and can be retried. Not yet confirmed live. |
| Bluesky | `bsky.app/profile/<handle-or-did>/post/<rkey>` | Video posts only (HLS), from the public read-only API the Bluesky web app uses (no account). Accounts hidden from signed-out viewers and blocked posts report login required (the other tiers are still tried); only a genuinely deleted post reports not found. Not yet confirmed live. |

## Other sites

Any other `http(s)` URL is handled in two steps, tried in order:

1. **Generic page analysis** - fetches the page and looks for `og:video`
   meta tags, JSON-LD, inline JSON state blobs (`__NEXT_DATA__`,
   `__INITIAL_STATE__`, `__NUXT__`, `__APOLLO_STATE__`), an oEmbed link, HLS
   or DASH manifests, and common `data-*` video attributes. This step never
   launches a browser.
2. **Browser capture** - if step 1 finds nothing, MiDa launches your
   installed Chrome (Edge only when Chrome is missing; the browser login
   session requires Chrome) as a real, visible-to-the-OS but off-screen
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
