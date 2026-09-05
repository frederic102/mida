# Coverage Corpus (verified 2026-09-05)

Verification method: one GET per candidate (desktop Chrome UA, curl -L, 20s timeout,
max 3 candidates per site). "og/json hint" = og:video, .m3u8/.mpd/.mp4 string, or an
embedded JSON blob with the real title/videoId seen directly in the curl response body.

| Site key | URL | HTTP + content check | og/json hint (no-browser) | Note |
|---|---|---|---|---|
| rumble | https://rumble.com/v4yo3oo-real-americas-voice-247.html | 307 redirect loop to itself, never resolves | none reached | Cloudflare bot challenge blocks curl. Needs real browser/JS. |
| odysee | https://odysee.com/@lbry:3f/odysee:7 | 200, title "Introducing Odysee: A Short Video" | title present in HTML | Official lbry channel video, works without browser. |
| bandcamp | https://booelectric.bandcamp.com/track/want-for-nothing | 403 Forbidden (3 candidates, incl. extra headers) | none, blocked | Fastly WAF blocks curl/bot UA site-wide. Needs browser. |
| twitch vod | https://www.twitch.tv/shroud/videos | 200, but body is empty React SPA shell (no VOD id/title in HTML) | none | Big streamer's real channel page; individual VOD id needs JS. Needs browser. |
| twitch clip | https://clips.twitch.tv/AnimatedOptimisticWasabiVoteNay | 200, generic `<title>Twitch</title>` | none | SPA shell, same as VODs. Needs browser. |
| kuaishou | https://www.kuaishou.com/short-video/3xhf4kv5ahrt8cy | 200, generic default title "短视频-快手" | none | Page renders client-side; could not confirm this id is a live video without JS. Needs browser. |
| weibo | https://weibo.com/tv/show/1034:5080340418793999 | 200, but title is "Sina Visitor System" | none, anti-bot wall | Weibo serves a visitor-verification page to non-browser clients. Needs browser/session. |
| xiaohongshu | https://www.xiaohongshu.com/discovery/item/67669f850000000013000451 | 200, title "你访问的页面不见了" (page is gone) | none | Bare ids without a valid xsec_token share link 404. Needs browser + real share link. |
| youku | https://v.youku.com/v_show/id_XNDI5ODI5NTQzNg==.html | 200, real Chinese documentary title | og:video present, videoId in body | Works without browser. |
| vk | https://vk.com/video-30558759_456239017 | HTTP 418 (deliberate bot-block status) | none | VK blocks non-browser clients outright. Needs browser. |
| ok.ru | https://ok.ru/video/14543307672246 | 200, og:title "2026" | og:video + og:video:url present | Works without browser. |
| pinterest | https://www.pinterest.com/pin/617415430169271912/ | 200, real pin page, title "Midland country band..." | no og:video found | Pin is real but not confirmed as a video-type pin; video metadata is JS-rendered. Needs browser to confirm/pick a video pin. |
| likee | https://likee.video/@Likee_official | 200, generic title "Likee - Short Video Community" | none | Empty SPA shell, no server-rendered links. Needs browser. |
| naver (blog) | https://blog.naver.com/PostList.naver?blogId=naver_diary | 200, real title "네이버 공식블로그" | 12 hits of video/player strings in body | Real official blog with video posts; a single post permalink was not isolated without a browser click-through. Note: tv.naver.com (Naver TV) is scheduled to shut down 2026-09-30, avoid that domain for a durable case. |
| dailymotion | https://www.dailymotion.com/video/x3j0j89 | 200, embedded JSON title "Top 5 Dailymotion Channels" | JSON title present, no og:video meta match | Confirms real video page; full og:video meta is JS-rendered. Partial no-browser confirmation. |
| tiktok | https://www.tiktok.com/@tiktok | 200, body is a SlardarWAF "Please wait..." challenge page | none | WAF challenge blocks curl outright. Needs browser. |
| ted | https://www.ted.com/talks/simon_sinek_how_great_leaders_inspire_action | 200, og:title "How great leaders inspire action" | og:title present | Works without browser. |
| coub | https://coub.com/view/3dl4uh | 200, title "In a live-action clip, a white cat..." | og:video with direct .mp4 URL | Works without browser. |
| imgur | https://imgur.com/t/gifs | 200, title "Imgur: The magic of the Internet" but body is empty React shell | none | No server-rendered gallery/video links found within 3-candidate budget. Needs browser. |
| facebook watch | https://www.facebook.com/NatGeoAnimals/videos/reindeer-national-geographic/371360365972647/ | 200, og:title present, description present | og:type "video.other", oembed_video link present | Works without browser. Facebook Watch (the dedicated tab) was discontinued April 2023; canonical URL now redirects to /reel/, but this public video URL itself still resolves. |
| tumblr | https://staff.tumblr.com/post/70425851417 | 200, title "Tumblr Staff - When was the last time..." | title present | Works without browser. |
| nytimes | https://www.nytimes.com/video/multimedia/100000004703252/stephen-jones-talks-top-hats.html | 403 Forbidden (also tried /video listing page) | none, blocked | Bot-protection blocks curl. Needs browser. |
| bbc news | https://www.bbc.co.uk/news/videos/cz7z93zde3po | 200, og:title "Watch: US man struck by lightning..." | og:title + JSON-LD VideoObject present | Works without browser. |
| streamable | https://streamable.com/moo | 200, title "Watch \"Please don't eat me!\" \| Streamable" | og:video/.mp4 hint present | Works without browser. |
| archive.org | https://archive.org/details/BigBuckBunny_124 | 200, title "Big Buck Bunny : Free Download, Borrow, and Streaming" | title present | Works without browser. |
| w3schools | https://www.w3schools.com/html/mov_bbb.mp4 | 200, direct .mp4 file (788KB) | n/a (raw media file) | Works without browser, not an HTML page. |
| vimeo | https://vimeo.com/22439234 | 200, og:title and og:type present | og:title/og:image/og:type present, no og:video | Works without browser. |
| nicovideo | https://www.nicovideo.jp/watch/sm9 | 200, og:title with full Japanese title | og:video, og:video:url, JSON-LD VideoObject all present | Works without browser. |

## Summary of sites needing a real browser (curl blocked or SPA shell)

rumble, bandcamp, twitch (both vod and clip), kuaishou, weibo, xiaohongshu, vk,
pinterest (to confirm video type), likee, tiktok, imgur, nytimes.

## Sites that work fully via curl (no browser needed)

odysee, youku, ok.ru, ted, coub, facebook watch, tumblr, bbc news, streamable,
archive.org, w3schools, vimeo, nicovideo. dailymotion is a partial case (base
JSON confirms real content, full og:video meta needs a browser).
