# Changelog

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
