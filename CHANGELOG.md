# Changelog

## [Unreleased]

## [2.4.0] - 2026-10-25

Nothing in this release has been measured live yet: no real-site download,
no 32-site corpus rerun, and no agent session calling the installed CLI.
Everything below is covered by offline tests only (fixtures, fake servers,
fake processes). Treat the new extractors and tiers as unconfirmed until a
live run says otherwise.

### Added
- Agent CLI `mida-cli` (`bin/mida_cli.dart`, shipped as `mida-cli.exe` next
  to `MiDa.exe`): `resolve`, `download`, `sites`, `version`, `help`. stdout is
  JSON lines only (`status`, `progress`, `result`, `error`), stable exit codes
  0/2/3/4/5/6/7, plus 8 when the reader closes stdout early (a download
  that already saved its file still exits 0). `sites` reports
  `measured_live`, the ids confirmed by a recorded live download; every
  v2.4.0 addition is absent from it. Every string on stdout
  passes URL redaction at one choke point; headers, cookies and media URLs
  are never printed. `MIDA_DEBUG=1` prints the sanitized classification to
  stderr, never the raw exception.
- `download` options `--container mp4|webm|mkv`, `--audio-quality
  best|320|256|128` and `--subtitles ko|en|ko,en`, so every GUI choice has a
  CLI spelling. `--help` / `-h` (where an option may stand) and `help` print
  usage and exit 0; `--out help` stays a folder name. `--quiet` and `--json`
  may come before the command; any option given twice is refused; options
  that cannot affect the chosen `--type` are reported as `Note:` status
  lines; `output_path` is always absolute.
- `resolve` prints selection ids that `download --format-id` accepts: the
  extractor's id when it is short plain text, else `fmt-<n>`, so a signed
  URL used as an id is never printed and still selectable.
- If a detached error ends a CLI run while it is still working, the run
  stops: exactly one terminal `error`, no later `result`, no file left.
- Forced headless mode (`--headless`, `MIDA_HEADLESS=1`) for the
  browser-capture tier, with an honest `HEADLESS_BLOCKED` result instead of
  any attempt to get past a bot check. Not measured live.
- Native Facebook extractor (public videos and reels). Not measured live:
  no Facebook download has been confirmed on a real page yet.
- Eight more native extractors: Telegram, Rumble, Streamable, Bluesky,
  Pinterest, SOOP VOD, LinkedIn and Xiaohongshu. Not measured live: each is
  built and tested against recorded page shapes only.
- Embedded-player families in the generic tier: JW Player, Brightcove,
  Kaltura and Wistia, plus delegation of YouTube and Vimeo iframes to their
  native extractors. Not measured live.
- GUI download queue: paste several links, they run one after another; the
  queue is the session history (finished items stay until "Clear finished").
  "Copy command (PowerShell or bash)" on a finished item gives a line that
  reproduces the job (type, quality, container, audio format and quality,
  subtitles, browser login session, folder). The URL and folder are copied
  byte for byte inside single quotes, which both shells keep literal; cmd.exe
  is not supported. A URL or folder holding a quote or control character
  gets no command, and the button says why.
- "Open folder after download" setting, now persisted. With it on, the folder
  opens once when the queue finishes with at least one saved file, not once
  per item.
- Claude Code skill `.claude/skills/mida-download/SKILL.md` and `AGENTS.md`.

### Changed
- Browser capture prefers Google Chrome over Microsoft Edge (Edge is used only when
  Chrome is missing). The browser login session now requires Chrome: it ignores a
  `MIDA_BROWSER_PATH` that is not `chrome.exe` / `Google Chrome`, never falls back to
  Edge, and reports `BROWSER_MISSING` asking to install Chrome or turn the setting off.
- The GUI ignores `MIDA_FFMPEG_PATH`; only the CLI reads it, per run, and
  only as an absolute path. When neither the override nor the bundled copy
  exists, ffmpeg and ffprobe are looked up in absolute `PATH` directories
  only, never by bare name (which on Windows would search the working
  folder first).
- CLI runs no longer share process-wide state: the ffmpeg environment, the
  registry builder and the ffprobe step are per call, so two runs in one
  process cannot see each other's settings.
- The ffprobe summary after a CLI download is bounded (20 s) and the child
  is killed on expiry; a finished download is never held back by it.
- CLI error messages no longer embed OS-localized text: a fixed English
  sentence plus the OS error number. `ProcessException` maps to
  `FFMPEG_MISSING`, `BROWSER_MISSING` or `PROCESS_START_FAILED` by program.
- `SettingsService` moved to `lib/features/settings/`, so `lib/core` has no
  Flutter import and compiles into the CLI.
- Dropped the unused `cupertino_icons` package; 9 direct Dart packages remain.
- README states the measured coverage, the dependency footprint, and that no macOS
  installer has been published. Supported-sites list marks Naver TV as shut down
  (2026-09-30).

### Removed
- The Settings "Dark Mode" switch. MiDa has only a dark theme, so the switch
  changed nothing; it is gone instead of pretending.
- The separate "Download History" list on the download screen (its data was
  no longer shown); the queue shows the session's finished downloads.

## [2.3.0] - 2026-09-06

### Added
- Native Vimeo extractor (public videos on vimeo.com and player.vimeo.com):
  reads the player config the site's own player uses, exposes the
  progressive MP4s and the HLS master, and reports private or sign-in-only
  videos as such. This replaces the generic path, which only ever saw byte
  range slices of Vimeo's CMAF files. Built against the documented config
  shape; the development machine's address was rate-banned by Vimeo during
  this release, so a live confirmation is still owed.

### Fixed
- Sites whose HLS master keeps audio in a separate rendition group (Pinterest,
  TED, and many CMAF packagers) downloaded silent video. MiDa now pairs each
  video rendition with its own audio group, honors DEFAULT and AUTOSELECT,
  demotes described-audio and forced tracks, and merges the two halves.
- Progressive MP4 links that were really one half of a DASH pair (Facebook,
  Vimeo shapes) were labeled as complete files. A small byte sniffer now reads
  the first 64 KiB, confirms which tracks the file carries, and corrects the
  label before ranking; a file that claimed audio and turns out silent fails
  loudly instead of being reported as a success.
- Niconico returned 403 on media playlists because the registry dropped the
  session cookies while normalizing protocols. Cookies survive now, and the
  native Niconico client keeps only cookies whose Domain matches the host.
- Adaptive pairs whose halves are manifests (m3u8, mpd) are fetched through
  ffmpeg with a process timeout, and transcode halves use MKV temporaries.
- Downloads are checked against the declared duration (from the extractor or
  the manifest) and refused when shorter than 90 percent.

### Security
- The manifest scan that runs before ffmpeg fails closed on error pages,
  non-manifest bodies, unreachable child playlists, budget and depth limits,
  and a 30 second deadline; it parses each playlist against the URL it was
  actually served from after redirects.
- Cookie and Authorization headers never follow a redirect to another origin,
  and are stripped from ffmpeg's global headers when a manifest references
  hosts outside the cookie's scope (the status line says so instead of
  refusing the download).
- Header names are validated as RFC 7230 tokens before reaching ffmpeg.

### Changed
- The retry loop re-ranks after every failed attempt and offers the best
  pre-muxed rendition within the first three attempts.
- `aac_adtstoasc` is applied only to transport stream input.

## [2.2.0] - 2026-09-06

### Added
- Native extractors for 11 more sites: Naver TV, CHZZK (VOD), Kakao TV
  (the public service has ended; the extractor still recognizes the URL
  and returns a clean, specific error instead of falling through to a
  browser capture that could never succeed), Dailymotion, Twitch (VOD and
  clips), Reddit (v.redd.it DASH), SoundCloud, Bilibili, Douyin, Niconico
  and Odysee. Combined with YouTube, X, TikTok and Instagram from 2.0.0,
  MiDa now has 15 native platform extractors; see
  [docs/supported-sites.md](docs/supported-sites.md) for the full list and
  what is still out of scope (DRM, most login-only or age-gated content,
  live streams).
- Browser capture now launches the system browser headed and off-screen
  by default (headless only as a fallback, for example a non-interactive
  session), because several anti-bot layers were found to fingerprint and
  block a `--headless` browser outright. It also dismisses consent and
  age-gate overlays before trying to start playback, tries several common
  play-button selectors and a center-of-player click, polls longer for the
  first media request, backfills from the page's own
  `performance.getEntriesByType('resource')` list, and can reconstruct a
  missing HLS/DASH manifest by probing sibling paths when only media
  segment URLs were observed.
- A "Use browser login session" toggle in Settings (off by default) lets
  MiDa reuse your own signed-in Edge or Chrome session for sign-in-only
  videos, by staging a cookie-only copy of your real browser profile. It
  never reads, decrypts, or holds a cookie value itself, and never touches
  saved passwords, history, or bookmarks.
- Retry with backoff for transient failures (rate limiting, momentary
  network or server errors); a failure the source reports as permanent
  (not found, private, DRM-protected, and similar) is not retried.

### Changed
- Generic page analysis now also parses inline JSON state blobs
  (`__NEXT_DATA__`, `__INITIAL_STATE__`, `__NUXT__`, `__APOLLO_STATE__`),
  follows an oEmbed link when present, and reads common `data-*` video
  attributes, which recovers resolution metadata for several sites that
  previously returned a format with no known quality.
- DRM detection now also inspects the body of an HLS or DASH manifest for
  encryption signals (Widevine, PlayReady, FairPlay), not just the
  candidate URL's own text, so a clean-looking manifest URL that is
  actually DRM-protected is caught before it is offered as downloadable.
- Generic analysis now caps total outbound requests, resource size, and
  recursion depth per page, so a single page cannot make MiDa fetch an
  unbounded number of embeds or an unbounded amount of data.
- Downloads now accept an HTTP 200 in addition to 206 on a ranged request
  (some hosts ignore the `Range` header and return the whole file), and
  every redirect hop and DNS answer is re-checked against the same
  private-network guard as the original URL, closing a path where a
  redirect or a DNS answer could point at a loopback or internal address.
- Cookies sent with a download request are now scoped per domain
  (respecting the `secure` flag) instead of one blanket header sent to
  every host a download touches.
- A TLS handshake failure caused by a certificate this system does not
  trust (observed on some CDNs) now surfaces a specific message explaining
  that MiDa will not bypass certificate verification, instead of a raw
  exception or an unexplained retry loop.

## [2.0.0] - 2026-09-05

### Changed
- yt-dlp has been removed entirely. Downloads from YouTube, X (Twitter),
  TikTok and Instagram natively. Other sites are handled by generic page
  analysis and, when needed, a headless copy of your installed Microsoft
  Edge or Google Chrome (override with `MIDA_BROWSER_PATH`). DRM-protected
  and login-only content is not supported.
- YouTube downloads talk to the InnerTube API directly (visionOS client,
  with an android client fallback) to fetch playable stream URLs, then
  download and merge video/audio with ffmpeg. X, TikTok and Instagram have
  their own native extractors built the same way.
- HLS/DASH streams are downloaded directly through ffmpeg instead of a
  yt-dlp subprocess.
- Removed the yt-dlp auto-update mechanism and the Settings "Download
  Engine" card; there is nothing left to update.

### Removed
- The bundled yt-dlp binary and every yt-dlp download/copy/packaging step
  in the build scripts and installer.

## [1.2.0] - 2026-09-05

### Added
- yt-dlp auto-update: MiDa now checks GitHub for a newer yt-dlp release on
  startup (throttled to once per 24h) and downloads it to a user-writable
  folder, so downloads keep working as sites change without waiting for a
  MiDa release.
- New "Download Engine" card in Settings showing installed/latest yt-dlp
  version, last checked time, and manual "Check for updates" / "Update now"
  actions.
- Downloaded yt-dlp binaries are verified against yt-dlp's published
  SHA-256 checksums before being installed.

### Fixed
- Build failure on Flutter 3.44 caused by the Material `CardTheme` to
  `CardThemeData` type change.

## [1.1.0] - 2026-02-24

### Added
- Drag & drop support for video file selection in Compress
- Auto-open output folder on compression complete
- "Open Folder" button on completed compression tasks

### Fixed
- Compression failing (Pass 1) due to pass log file permission issues
- Better error messages showing actual FFmpeg errors instead of generic failure

## [1.0.0] - 2025-02-15

### Initial Release
- Video download from YouTube, Twitter/X, Instagram, TikTok
- Audio download (MP3, M4A, FLAC, WAV, Opus)
- Video compression with target file size (two-pass encoding)
- Audio extraction from local video files
- Subtitle download support (.srt)
- Windows and macOS support
