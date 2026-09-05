# Council brief - MiDa v2.0 (yt-dlp removal) - 2026-09-05 16:30

## What was built (uncommitted working tree)

Contracts: `plan-native-extractor.md` (YouTube), `plan-phase2-extractors.md` (X/TikTok/
Instagram), `plan-generic-extractor.md` (generic), `plan-browser-capture.md` (CDP capture),
`plan-phase2b-wiring.md` (integration). Phase 3 (`plan-phase3-remove-ytdlp.md`, deleting
yt-dlp code/binaries/auto-updater, version 2.0.0) is NOT done yet and waits for this verdict.

Registry order: YouTube > Twitter > TikTok > Instagram > Generic, BrowserCapture fallback.
Fall-through: catch-all NO_MEDIA_FOUND, platform CHALLENGE_FAILED/RATE_LIMITED/PARSE_ERROR/
NETWORK -> Generic -> BrowserCapture; first status code kept, last reason appended.
Pipeline: FormatSelector.rank -> up to 3 candidates -> StreamDownloader (https, 10MB chunks,
retry) or HlsFfmpegDownloader (hls/dash, protocol whitelist, header CRLF guard) -> ffmpeg
merge/convert -> ffprobe sanity check (missing claimed stream = next candidate; silent source
accepted) -> captions (YouTube, tlang fallback). Temps in output dir, .part then FileMover.
Legacy yt-dlp backend: injectable dead field, test proves it is never called.

## Lead live measurements (real registry + pipeline, ffprobe on outputs)

| URL | Result |
|---|---|
| YouTube dQw4w9WgXcQ 480p/1080p mp4, mp3 | pass (h264+aac; 1080p 80.5MB earlier) |
| X 719944021058060289 mp4, mkv, mp3 | pass |
| TikTok hankgreen1/7047596209028074758 | dedicated path passed 2/2 in the social lane at ~15:30, then this IP got RATE_LIMITED (WAF interstitial after ~30 hits today); capture fallback then yields a video-only asset and the pipeline fails cleanly with what/why/next. Not re-verifiable from this IP until the WAF cools off. |
| Instagram reel Chunk8-jurw | pass; source has no audio track logged-out (DASH manifest has_audio=false; yt-dlp sees the same); 9 video-only renditions, pipeline announces "Source has no audio track." |
| Vimeo 76979871 | DRM_PROTECTED with clean message; logged-out playlists are cbcs, yt-dlp fails too ("only works when logged-in") |
| mux HLS test stream | pass (63.9MB h264+aac via ffmpeg) |
| w3schools direct mp4 -> mp3 | pass |
| nonsense URL, private IG post | clean errors, no msedge leak |

Korean auto-translated captions: code path unit-tested; live blocked by YouTube 429 on
`tlang` from this IP.

## AEGIS round 2 (before fixes) and what the lanes report as fixed

Vigil (SHIP-WITH-CAVEATS): HLS direct writes without temp (fixed: .part before extension +
FileMover), cross-volume rename data loss (fixed: FileMover copy+delete fallback, temps in
output dir), StreamDownloader client never closed (fixed), fall-through masks first error
(fixed), YouTube NETWORK_ERROR/TIMEOUT status drift (fixed -> NETWORK), no reentrancy guard
(fixed), quality override silent (fixed: status line).
Assay (SHIP-WITH-CAVEATS): hasAudio hardcoded true in TikTok/Instagram/Twitter/generic/
capture (fixed in TikTok via `music` signal, Instagram via DASH mimeType, capture via
mimeType/codecs; Twitter still assumes muxed mp4, ffprobe check is the safety net),
tautological Instagram test (rewritten), profile dir race (fixed: await exit + retry),
undifferentiated NO_MEDIA_FOUND (fixed: LOGIN_REQUIRED/NOT_FOUND detection), Vimeo DRM
surfaced as ffmpeg stderr (fixed: DRM_PROTECTED before download).
Bulwark (SHIP-WITH-CAVEATS): ffmpeg protocol whitelist (fixed), header CRLF injection
(fixed, HeaderInjectionException), SSRF private hosts (fixed in generic + capture, two
host_policy files pending dedupe; DNS rebinding not covered), filename Unicode/bidi/rune cap
(fixed), DevTools port TOCTOU (fixed: address pin + Browser.getVersion check).

## Current verification state

`flutter analyze` 0 errors (info-level lints only, incl. docs/spikes). `flutter test`
490 passed, 25 live skipped. `flutter build windows --release` ok. Live suites: see table;
`social_live_test` TikTok red for the RATE_LIMITED reason above.

## Known open items (candidates for follow-ups)

1. TikTok under WAF escalation: capture fallback picks the wrong asset (aweme play URL 403 or
   static asset); needs a re-probe from a cool IP.
2. Two host_policy implementations (generic vs browser_capture) to merge.
3. `youtube_download_pipeline.dart` wrapper + `ytdlp_*` + auto-updater still present (Phase 3).
4. DNS-rebinding not covered by host policy.
5. Instagram carousel: first video only. Playlists, live streams, login: out of scope.
