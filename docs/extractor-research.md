# Extractor Research: Twitter/X, TikTok, Instagram

Source: yt-dlp `master` branch, `yt_dlp/extractor/{twitter,tiktok,instagram}.py`,
fetched via raw.githubusercontent.com on 2026-09-05. Line numbers below refer to
that snapshot and will drift as yt-dlp is updated; re-fetch before relying on
exact line numbers again.

Scope: MiDa is Flutter/Dart, `dart:io HttpClient` only. No JS engine (V8/QuickJS),
no yt-dlp binary, no `curl-cffi`/browser TLS-impersonation library.

## 1. Twitter / X

### Request sequence yt-dlp tries, in order

1. **GraphQL API (default, `TwitterIE._selected_api == 'graphql'`)**
   - `POST https://api.x.com/1.1/guest/activate.json` body `b''`
     Headers: `Authorization: Bearer AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA`
     (hardcoded public bearer token, `TwitterBaseIE._AUTH`).
     Response: `{"guest_token": "..."}`.
   - `GET https://x.com/i/api/graphql/2ICDjqPd81tulZcYrtpTuQ/TweetResultByRestId`
     Query: `variables={"tweetId":"<id>","withCommunity":false,...}`,
     `features={...long feature-flag map...}` (both JSON-stringified).
     Headers: same `Authorization` bearer, `x-guest-token: <guest_token>`,
     `x-csrf-token` (from cookie `ct0`, absent when logged out).
     JSON path to video: `data.tweetResult.result.legacy.extended_entities.media[].video_info.variants[]`
     (`.url`, `.bitrate`); title/description: `...legacy.full_text`; thumbnail:
     `...media[].media_url_https`; duration: `...video_info.duration_millis / 1000`.
   - On HTTP 429 from the GraphQL call, yt-dlp automatically falls back to syndication (below).
2. **Syndication API (fallback on 429, or explicit `--extractor-args twitter:api=syndication`)**
   - `GET https://cdn.syndication.twimg.com/tweet-result?id=<twid>&token=<token>`
   - Header: `User-Agent: Googlebot` only. **No auth, no cookies, no guest token.**
   - `token` = `((Number(twid) / 1e15) * Math.PI).toString(36)` with all `0` and `.`
     characters stripped (source comment, `twitter.py:1157`).
   - JSON path to video: `mediaDetails[].video_info.variants[]` (`.url` mp4/m3u8, `.bitrate`);
     title/text: top-level `text`; thumbnail: `mediaDetails[].media_url_https`;
     duration: `mediaDetails[].video_info.duration_millis / 1000`.
   - Explicit code comment: `'Not all metadata or media is available via syndication endpoint'`.
3. **Legacy API (only via explicit `--extractor-args twitter:api=legacy`, not tried by default)**
   - `GET https://api.x.com/1.1/statuses/show/<id>.json?tweet_mode=extended&...`, same guest-token
     dance as GraphQL, plus `x-twitter-auth-type` etc. only added when logged in.

None of the three strategies is marked broken in the current source. Default,
unauthenticated behavior for a public tweet is GraphQL first (two round trips:
guest-token POST, then GraphQL GET), syndication as automatic 429 fallback.

### Login required?

No. `is_logged_in` only gates which bearer/headers are sent (`x-twitter-auth-type`
if a session cookie exists); guest tokens are fetched automatically when logged
out. NSFW or protected tweets trigger `self.raise_login_required(...)` (source,
`twitter.py:1090-1092`), but ordinary public video tweets do not.

### Feasibility in pure Dart

**FEASIBLE.** The syndication endpoint is a single unauthenticated GET with one
static header and a token computed by a pure-math formula (float multiply,
base-36 stringify, no JS execution, verified working live below). It alone is
enough to ship v1. The GraphQL path is also plain JSON-over-HTTPS with no TLS
fingerprinting requirement observed, but needs the extra guest-token POST and a
large, brittle `features` payload that must be kept in sync with yt-dlp's copy.

### Test URLs (from yt-dlp `_TESTS`)

- `https://twitter.com/starwars/status/665052190608723968` (no `skip` flag)
- `https://twitter.com/captainamerica/status/719944021058060289` (no `skip` flag, native attached video)

## 2. TikTok

### Request sequence yt-dlp tries, in order

1. **Mobile app API (`_extract_aweme_app`), only if the user supplies
   `--extractor-args "tiktok:app_info=..."` or `device_id=...`.** Not attempted
   for a plain URL by default (`_KNOWN_APP_INFO` is empty otherwise,
   `tiktok.py:60-63`, `994-1002`).
   - `POST https://api16-normal-c-useast1a.tiktokv.com/aweme/v1/multi/aweme/detail/`
     Query: ~35 spoofed Android-app params (`device_platform=android`, `aid`,
     `app_name=musical_ly`, `version_code`, `device_id`, `iid`, `cdid`, etc, all
     built in `_build_api_query`). Body: `aweme_ids=[<id>]&request_source=0`.
     Header: `User-Agent: com.zhiliaoapp.musically/<version> (Linux; ... Pixel 7 ...)`,
     `X-Argus: ''`.
     JSON path: `aweme_details[0].video.bit_rate[].play_addr.url_list[]` (mp4,
     with `.bit_rate` bps), also `.play_addr`/`.download_addr`/`.play_addr_h264`.
2. **Web page + embedded JSON (`_extract_web_data_and_status`), this is the
   actual default path for a plain URL today.**
   - `GET https://www.tiktok.com/@<user>/video/<id>` with `impersonate=True`
     (yt-dlp's curl-cffi browser-TLS-fingerprint layer, source `tiktok.py:281`).
   - Looks for `<script id="__UNIVERSAL_DATA_FOR_REHYDRATION__">` JSON blob.
   - If absent, TikTok served an anti-bot **JS-free SHA256 proof-of-work
     challenge page** instead (`id="cs"` element, base64 JSON with `v.a` = hash
     seed and `v.c` = expected digest). yt-dlp brute-forces an integer `0..1e6`
     whose SHA256(seed+integer) equals the digest natively in Python
     (`_solve_challenge_and_set_cookies`, `tiktok.py:223-273`, no JS engine
     used), sets the resulting cookie, and re-requests the page.
   - JSON path once obtained: `__DEFAULT_SCOPE__["webapp.video-detail"].itemInfo.itemStruct`,
     then `.video.bitrateInfo[].PlayAddr.UrlList[]` (mp4 URLs, resolution encoded
     in `.PlayAddr.UrlKey`); title/description: `.desc`; thumbnail: `.video.cover`
     / `.dynamicCover`; duration: `.video.duration`.
   - `statusCode` 10216/10222 in the response means private post/account and
     triggers `raise_login_required`; 10204 means IP-blocked.

### Login required?

Not for the account itself, but source comment: `'TikTok is requiring login for
access to this content'` fires whenever the webpage GET redirects to `/login`
(`tiktok.py:289-293`), which TikTok does routinely for traffic it does not
trust regardless of the post being public. `impersonate=True` is passed
unconditionally on every web request, i.e. yt-dlp assumes plain header spoofing
is not enough.

### Feasibility in pure Dart

**PARTIAL.** The SHA256 proof-of-work challenge itself needs no JS engine, only
a hash loop, and is portable to Dart as-is. But it is gated behind a TLS/HTTP2
fingerprint check that a stock `dart:io HttpClient` cannot pass (confirmed
live below: a plain curl with a full Chrome `User-Agent` still got served the
challenge page, matching yt-dlp's design of using browser impersonation on
every call). Without a fingerprint-matching layer the flow stalls at step 2 no
matter how well the PoW and cookie logic are implemented. The mobile-app-API
path avoids the browser-fingerprint problem but is not yt-dlp's default
anymore and needs a maintained pool of spoofed Android `app_info` presets.

### Test URLs (from yt-dlp `_TESTS`)

- `https://www.tiktok.com/@hankgreen1/video/7047596209028074758`
- `https://www.tiktok.com/@leenabhushan/video/6748451240264420610`

## 3. Instagram

### Request sequence yt-dlp tries, in order

1. `GET https://www.instagram.com/` with `impersonate` (if available) to seed
   cookies and scrape the LSD token, either from a `<script id="__eqmc">` JSON
   blob or regex `\["LSD",\[\],\{"token":"([^"]+)"` (`instagram.py:426-433`).
2. `GET https://www.instagram.com/api/v1/web/get_ruling_for_content/?content_type=MEDIA&target_id=<media_id>`
   Headers: `X-IG-App-ID: 936619743392459` (web app id), `X-ASBD-ID: 359341`,
   `X-IG-WWW-Claim: 0`, `Origin: https://www.instagram.com`. Used only to
   decide whether the `csrftoken` cookie should be trusted as a real CSRF
   token (`status == 'ok'`).
3. `POST https://www.instagram.com/api/graphql`, **only attempted if
   `self._can_impersonate` is true** (`instagram.py:471-488`, `) if self._can_impersonate else None`
   literally short-circuits the call otherwise).
   Headers: `X-FB-Friendly-Name: PolarisLoggedOutDesktopWWWPostRootContentQuery`,
   `X-CSRFToken`, `X-FB-LSD`, `X-Requested-With: XMLHttpRequest`, `Referer: <post url>`.
   Body (form): `lsd`, `fb_api_caller_class=RelayModern`,
   `fb_api_req_friendly_name=PolarisLoggedOutDesktopWWWPostRootContentQuery`,
   `server_timestamps=true`, `variables={"media_id":"<numeric id>"}`,
   `doc_id=27130156389949648` (hardcoded persisted-query id, will rot over time).
   JSON path: `data.xig_polaris_media.if_not_gated_logged_out` then, per media,
   `.video_versions[].url` (mp4, with `.width`/`.height`, no explicit bitrate
   field) and `.video_dash_manifest` (MPD, has real bitrate ladder);
   title: `.caption.text` / `Video by <username>`; thumbnail:
   `.image_versions2.candidates[0].url`; duration: `.video_duration`.
4. If step 3 returns nothing, fallback: `GET https://www.instagram.com/p/<shortcode>`
   directly and regex out `<script data-sjs>` blobs, walking
   `require -> ... -> __bbox.require -> RelayPrefetchedStreamCache -> __bbox.result.data.xig_polaris_media`.
   If that request's final URL path starts with `/accounts/login` or is `/`,
   yt-dlp raises: `'The webpage request was redirected to the login page. You
   have exceeded the rate-limit for accessing posts anonymously'`
   (`instagram.py:507-510`).
5. Shortcode to numeric `media_id`: custom base-64-ish decode with alphabet
   `ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_`
   (`_id_to_pk`, `instagram.py:28-41`), pure arithmetic, no JS needed.

### Login required?

Not formally, but every one of the four still-active `InstagramIE._TESTS`
entries (the `p/BQ0eAlwhDrw`, `reel/Chunk8-jurw`, `tv/BkfuX9UB-eK`,
`p/aye83DjauH` cases) carries `'expected_warnings': ['General metadata
extraction failed', 'Main webpage is locked behind the login page']` in the
current source, i.e. yt-dlp's own CI expects the logged-out webpage fallback
to be login-walled on every run and only succeeds because the GraphQL call
(step 3) usually gets through first when impersonation is available. Long
shortcodes (>28 chars) are explicitly private and raise
`raise_login_required('This content is only available for registered users
who follow this account')`.

### Feasibility in pure Dart

**NOT WITHOUT TLS IMPERSONATION.** yt-dlp's own code refuses to call the
GraphQL endpoint at all unless a browser-TLS-fingerprint layer is present,
and live verification below confirms why: an unauthenticated `dart:io`-style
plain HTTPS client gets HTTP 200 with an HTML shell (not JSON) from
`/api/graphql`, meaning Instagram is filtering on connection fingerprint, not
just headers or cookies. No JS execution is required (all logic is plain
JSON/regex parsing) but a bot-detection layer sits in front that
`dart:io HttpClient` cannot spoof on its own.

### Test URLs (from yt-dlp `_TESTS`)

- `https://www.instagram.com/reel/Chunk8-jurw/`
- `https://www.instagram.com/p/BQ0eAlwhDrw/` (carousel/multi-video post)

## 4. Live verification (2026-09-05, curl, no cookies/accounts, HEAD/Range only)

### Twitter: full unauthenticated sequence, PASS end to end

```
GET https://cdn.syndication.twimg.com/tweet-result?id=719944021058060289&token=1qtrrnvqpw
Header: User-Agent: Googlebot
-> HTTP 200, JSON with mediaDetails[0].video_info.variants:
   video/mp4 https://video.twimg.com/ext_tw_video/717462543795523584/pu/vid/1280x720/jkWo76O5ZLxpBTVN.mp4 (bitrate 2176000)
   + 640x360 (832000) and 320x180 (320000) variants, plus an .m3u8

Range GET (bytes 0-1023) on the 1280x720 mp4:
-> HTTP 206 Partial Content, Content-Type: video/mp4, Content-Range: bytes 0-1023/537709
```
Also checked two card-based tweets (`623160978427936768`, `665052190608723968`,
NASA/Star Wars): both returned HTTP 200 JSON with no `mediaDetails` because
their video is embedded via a `unified_card`/vmap player, not attached native
media, confirming the extractor's card-vs-native-media branching matters.

### TikTok: web path blocked by anti-bot challenge, no impersonation available

```
GET https://www.tiktok.com/@hankgreen1/video/7047596209028074758
Header: full Chrome desktop User-Agent + standard Accept headers
-> HTTP 200, but body is 1462 bytes containing id="cs" and "Please wait..."
   (the SHA256 proof-of-work challenge page), not __UNIVERSAL_DATA_FOR_REHYDRATION__.
```
Matches yt-dlp's own design (`impersonate=True` unconditionally on this call).

### Instagram: GraphQL call reachable but bot-blocked without impersonation

```
GET https://www.instagram.com/                 -> HTTP 200, LSD token + csrftoken cookie obtained
GET .../api/v1/web/get_ruling_for_content/?...  -> HTTP 200, {"status":"ok"} (post is public/accessible)
POST https://www.instagram.com/api/graphql (doc_id=27130156389949648, media_id=2913440072144448240)
-> HTTP 200, but body is 618KB of HTML (<title>Instagram</title> SPA shell), not JSON.
```
Confirms the GraphQL endpoint silently swaps JSON for an HTML shell when the
request's TLS/connection fingerprint does not look like a real browser, which
is exactly why yt-dlp gates this call behind `self._can_impersonate`.

## 5. Summary table

| Platform | Default strategy (unauth) | Feasible in pure Dart | Blocker if not |
|---|---|---|---|
| Twitter/X | Syndication GET (fallback) or GraphQL (primary) | FEASIBLE | none observed; syndication verified end to end |
| TikTok | Webpage + embedded JSON | PARTIAL | TLS/HTTP2 fingerprint check in front of the JSON blob (PoW itself is portable) |
| Instagram | Webpage LSD + GraphQL POST | NOT WITHOUT TLS impersonation | GraphQL endpoint swaps JSON for HTML shell without a browser-matching fingerprint |

Recommendation for MiDa: ship Twitter/X via the syndication endpoint first (no
extra work needed). TikTok and Instagram both need either a TLS-fingerprint-
spoofing HTTP layer (not available in stock `dart:io`) or accepting a lower
success rate against their anti-bot layers; this is a build decision, not a
protocol-knowledge gap.
