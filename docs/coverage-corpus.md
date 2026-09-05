# Coverage Corpus (updated 2026-09-06)

This corpus is the exact 32 URLs in
`test/live/lead_coverage_probe_test.dart`'s `sites` map. That test is the
single source of truth for which URLs count; this document explains what
each one is and what tier of MiDa handles it. If a URL here does not match
that file, the test file wins and this document is stale.

## Verification criterion

Run with `MIDA_LIVE=1 flutter test test/live/lead_coverage_probe_test.dart`.
For each URL, in order:

1. **Resolve** - `ExtractorRegistry.resolveInfo(url)`, 90s timeout, through
   whichever tier actually handles that site (native extractor, generic
   analysis, or browser capture fallback).
2. **Range check** - a `GET` on the first resolved format URL with
   `Range: bytes=0-1023`, confirming the host actually serves media (not
   just that MiDa parsed a URL out of a page).
3. **Download + ffprobe** - only if step 2 returns HTTP 200 or 206: a real
   download through the production `MediaDownloadPipeline` (480p mp4
   target) into a temp directory, then `ffprobe` confirms the output file
   has at least one real video or audio stream.

A site counts as covered only if all three steps succeed end to end (the
test's `ok` counter). Resolving formats but failing the download or
ffprobe check does not count.

**Last measured aggregate** (per the `v2.2 coverage` commit message,
2026-09-06): 25/32 resolve formats, 20/32 complete the full
resolve-plus-download-plus-ffprobe criterion above. That commit did not
record a per-site pass/fail breakdown, so the table below documents what
each URL is and which tier handles it, not a claim about which specific
32 passed. Rerunning the command above prints one `OK`/`FAIL`/`ERR` line
per site (with format count, resolved heights, and range/download result)
plus the aggregate count; that live output is the source for a per-site
breakdown, to be measured by the lead.

## Corpus

| Site key | URL | Tier | Note |
|---|---|---|---|
| youtube | https://www.youtube.com/watch?v=dQw4w9WgXcQ | Native (YouTube) | |
| twitter | https://twitter.com/captainamerica/status/719944021058060289 | Native (X/Twitter) | |
| tiktok | https://www.tiktok.com/@hankgreen1/video/7047596209028074758 | Native (TikTok) | |
| instagram | https://www.instagram.com/reel/Chunk8-jurw/ | Native (Instagram) | |
| naver-tv | https://tv.naver.com/v/105228483 | Native (Naver TV) | Naver TV is scheduled to shut down 2026-09-30; this URL will stop working after that date regardless of MiDa. |
| chzzk | https://chzzk.naver.com/video/14834019 | Native (CHZZK) | VOD id, not a live channel. |
| dailymotion | https://www.dailymotion.com/video/x3j0j89 | Native (Dailymotion) | Page metadata resolves natively; the video CDN (`cdndirector.dailymotion.com` / `*.cf.dmcdn.net`) has a confirmed TLS-fingerprint-based block against this app's own HTTP client on some videos, separate from the extractor itself (see `docs/supported-sites.md`). |
| twitch-vod | https://www.twitch.tv/videos/2863640137 | Native (Twitch) | |
| twitch-clip | https://clips.twitch.tv/AnimatedOptimisticWasabiVoteNay | Native (Twitch) | |
| reddit | https://www.reddit.com/r/aww/comments/1c0xhqk/ | Native (Reddit) | v.redd.it DASH manifest. |
| soundcloud | https://soundcloud.com/rick-astley-official/never-gonna-give-you-up | Native (SoundCloud) | Audio only. |
| bilibili | https://www.bilibili.com/video/BV1GJ411x7h7 | Native (Bilibili) | Live-test diagnosis on this id also uncovered and fixed a `ConcurrentModificationError` in the browser-capture manifest-recovery path used as its fallback; see `docs/plan-phase5-coverage.md`. |
| douyin | https://www.douyin.com/video/7318947853764676900 | Native (Douyin) | The site's anti-bot layer is a JS-VM challenge that no plain HTTP client can solve by design; per `test/live/global_sites_live_test.dart`, this was not resolved within this pass's budget. |
| niconico | https://www.nicovideo.jp/watch/sm9 | Native (Niconico) | Per `test/live/global_sites_live_test.dart`, current-site auth for this extractor was not resolved within this pass's budget. |
| youku | https://v.youku.com/v_show/id_XNDI5ODI5NTQzNg==.html | Generic analysis | Works without a browser: `og:video` and a `videoId` are present directly in the HTML. |
| weibo-video | https://weibo.com/tv/show/1034:5080340418793999 | Browser capture | Weibo serves a visitor-verification interstitial to non-browser clients; needs a real browser session. |
| vk-video | https://vk.com/video-30558759_456239017 | Browser capture | VK returns HTTP 418 to non-browser clients. Real `video/mp4`/`audio/mp4` traffic was captured on `okcdn.ru` once a browser session was used; that host's mimeType-without-extension URLs previously fell through the classifier and were added as a fallback (see `docs/plan-phase5-coverage.md`). The download stage separately hit an untrusted-TLS-certificate failure on this CDN. |
| ok-ru | https://ok.ru/video/14543307672246 | Generic analysis | Works without a browser: `og:video` and `og:video:url` are present. Shares the same untrusted-TLS-certificate CDN issue noted for vk-video. |
| odysee | https://odysee.com/@lbry:3f/odysee:7 | Native (Odysee) | |
| rumble | https://rumble.com/v2r1rw6-top-7-most-viewed-videos.html (swapped 2026-09-06: previous URL was a 24/7 live stream) | Browser capture | Cloudflare bot challenge blocks a plain HTTP request; needs a real browser. |
| bandcamp | https://booelectric.bandcamp.com/track/want-for-nothing | Browser capture | A Fastly WAF blocks non-browser clients site-wide. `audio/mpeg` streams under an extension-less path (`mp3-128`) were previously dropped by the URL-extension check; fixed by trusting the server's own mimeType when the URL has no recognizable extension. |
| pinterest | https://www.pinterest.com/pin/diy-pin-tutorial-video--41025046600764526/ (swapped 2026-09-06: native video pin) | Browser capture | Known limitation, not fixed this pass: in an anonymous session this pin URL redirects to a generic feed page and the pin id itself is lost, with no reliable page signal to detect that case without risking false positives on other pins. |
| ted | https://www.ted.com/talks/simon_sinek_how_great_leaders_inspire_action | Generic analysis | Works without a browser: `og:title` present. |
| coub | https://coub.com/view/3dl4uh | Generic analysis | Works without a browser: `og:video` points directly at an `.mp4`. |
| facebook | https://www.facebook.com/NatGeoAnimals/videos/reindeer-national-geographic/371360365972647/ | Generic analysis | Works without a browser: `og:type` is `video.other` with an oembed_video link present. Facebook Watch (the dedicated tab) was discontinued in 2023; this direct video URL still resolves. |
| tumblr | https://nasa.tumblr.com/post/616923388224667648 | Generic analysis | Swapped 2026-09-06: the previously listed staff post had no video (an anonymous-session redirect to the blog root, confirmed via live diagnosis, not a capture-engine bug). This nasa.tumblr.com post is the replacement. |
| bbc-news | https://www.bbc.co.uk/news/videos/cz7z93zde3po | Generic analysis | Works without a browser: `og:title` plus a JSON-LD `VideoObject`. |
| nytimes | https://www.nytimes.com/video/multimedia/100000004703252/stephen-jones-talks-top-hats.html | Browser capture | Bot protection returns 403 to a plain HTTP request; needs a real browser. |
| streamable | https://streamable.com/moo | Generic analysis | Works without a browser: `og:video`/`.mp4` hint present. |
| archive-org | https://archive.org/details/BigBuckBunny_124 | Generic analysis | Works without a browser. |
| vimeo-public | https://vimeo.com/22439234 | Generic analysis | `og:title`/`og:type` present in the HTML; format resolution does not depend on a browser for this public video. |
| w3schools-mp4 | https://www.w3schools.com/html/mov_bbb.mp4 | Generic analysis | A direct `.mp4` file, not an HTML page. |

## Excluded (no verified single-video URL)

These sites were investigated during coverage research but are not in the
probe corpus above, because a single, durable, video-bearing URL could not
be confirmed within the research budget (see git history of this file for
the original per-site curl findings, October-dated entries now removed):

- **kuaishou** - the candidate short-video id's page renders client-side
  with only a generic title server-rendered; could not confirm it was a
  live video without a browser.
- **xiaohongshu** - a bare item id without a valid `xsec_token` share link
  returns a "page not found" response.
- **likee** - the candidate channel page is an empty client-rendered
  shell with no server-rendered video links.
- **imgur** - the candidate gallery page is an empty client-rendered
  React shell within the research budget's candidate limit.
- **naver (blog)** - a real official blog with video posts, but a single
  post permalink was not isolated without a browser click-through; Naver
  TV (`tv.naver.com`) is the durable single-video case used instead, and
  is itself scheduled to shut down 2026-09-30.

If a durable single-video URL for any of these is found later, add it to
`test/live/lead_coverage_probe_test.dart`'s `sites` map first, then add a
row here to match.

## Final measurement (2026-09-06, lead, `MIDA_LIVE=1 flutter test test/live/lead_coverage_probe_test.dart`)

Criterion: resolve, then a real pipeline download (480p mp4 or best audio), then ffprobe must
report at least one stream. Result: 19 of 32 downloaded; 28 of 32 resolved formats.

Downloaded: youtube, twitter, tiktok, instagram, naver-tv, chzzk, soundcloud, douyin, youku,
odysee, rumble, bandcamp, coub, tumblr, bbc-news, nytimes, streamable, archive-org, w3schools.

Resolved but not downloaded: dailymotion and twitch-vod (CDN answers 403 to non-browser TLS
fingerprint or geo block), vk-video and ok-ru (CDN certificate not trusted by the OS; no bypass),
niconico, pinterest, ted, facebook, vimeo (captured candidates are DASH/CMAF renditions whose
init or audio pairing the pipeline could not complete; open follow-up).

Not resolved: twitch-clip (anonymous GraphQL gated), reddit and bilibili (bot challenge), weibo
(visitor wall). The browser login session toggle may help on those when the user is signed in.
