# Changelog

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
