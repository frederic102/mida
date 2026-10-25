<p align="center">
  <img src="assets/logo.png" width="100" height="100" alt="MiDa">
</p>

<h1 align="center">MiDa</h1>

<p align="center">
  Desktop media downloader & encoder with native extractors and FFmpeg.
</p>

<p align="center">
  <img src="https://img.shields.io/github/v/release/frederic102/mida?style=flat-square&color=brightgreen" alt="Release">
  <img src="https://img.shields.io/badge/license-GPLv3-blue?style=flat-square" alt="License">
  <img src="https://img.shields.io/badge/platform-Windows-blue?style=flat-square" alt="Platform">
  <img src="https://img.shields.io/badge/Flutter-3.5+-02569B?style=flat-square&logo=flutter" alt="Flutter">
</p>

---

<p align="center">
  <img src="docs/mida-promo.gif" width="800" alt="MiDa Demo">
</p>

## Features

- **Video Download** - YouTube, Twitter/X, Instagram, TikTok and 12 more native platforms, plus most other video sites via page analysis and browser capture (see [Supported Sites](docs/supported-sites.md))
- **Audio Download** - Extract audio in MP3, M4A, FLAC, WAV, Opus
- **Video Compression** - Two-pass encoding with target file size (presets or custom)
- **Audio Extraction** - Extract audio tracks from local video files
- **Subtitle Download** - Download subtitles as .srt files

## Download

Go to [**Releases**](https://github.com/frederic102/mida/releases/latest) and download the installer for your platform.

| Platform | File | Requirements |
|----------|------|--------------|
| Windows | `MiDa_Setup_v*.exe` | Windows 10+ |
| macOS | No installer published yet. A build script exists (`scripts/build_macos.sh`) but no release has been built or tested on a Mac. | Build from source |

FFmpeg is bundled in the installer. No additional setup required. Downloads from YouTube, X (Twitter), TikTok, Instagram and more natively; see [Supported Sites](docs/supported-sites.md) for the full list. Other sites are handled by generic page analysis and, when needed, a real off-screen window of your installed Microsoft Edge or Google Chrome (headless only as a fallback, for example on a machine with no interactive session). DRM-protected content, live streams, and most login-only or age-gated content are not supported; see [Supported Sites](docs/supported-sites.md) for the exceptions. Set `MIDA_BROWSER_PATH` to point at a specific browser install, and turn on "Use browser login session" in Settings to let MiDa reuse your own signed-in browser session for sign-in-only videos (off by default).

## What actually works

Numbers below come from `test/live/lead_coverage_probe_test.dart`, a 32-site corpus where "works"
means resolve, a real download through the pipeline, and ffprobe reporting a stream. Details and
per-site reasons are in [docs/coverage-corpus.md](docs/coverage-corpus.md).

| Measured | Result |
|---|---|
| v2.2.0 full run (2026-09-06) | 19 of 32 downloaded, 28 of 32 resolved |
| v2.3.0 A/V pairing fix, five previously failing sites | 4 of 5 now download with video and audio (Vimeo still open; the native Vimeo extractor shipped after this run and is not yet confirmed live) |

The full 32-site run has not been repeated on v2.3.0. Treat the numbers as a snapshot.

## Dependencies

MiDa deliberately keeps its footprint small. There is no yt-dlp, no Python, no Node, no runtime
to install, and no network service of ours in the loop.

- **Bundled**: `ffmpeg.exe` and `ffprobe.exe` (static builds, in the installer).
- **Used from your machine**: Microsoft Edge or Google Chrome, only for the browser-capture fallback.
- **Dart packages (9 direct)**: `provider`, `path`, `path_provider`, `file_picker`, `desktop_drop`,
  `url_launcher`, `shared_preferences`, `crypto`, `google_fonts`. Everything else (HTTP, HTML and
  JSON parsing, HLS/DASH manifest handling, MP4 box sniffing, the DevTools protocol client) is
  written against the Dart SDK. `google_fonts` fetches the Inter font once at first launch and
  caches it; the app falls back to the system font if that fetch fails.

## Building from Source

### Prerequisites

- [Flutter SDK](https://docs.flutter.dev/get-started/install) 3.5+
- **Windows**: Visual Studio 2022 with C++ Desktop Development workload
- **macOS**: Xcode

### Build

```bash
# Clone
git clone https://github.com/frederic102/mida.git
cd mida

# Download FFmpeg (first time only)
# Windows:
.\scripts\download_binaries.ps1
# macOS:
./scripts/download_binaries_mac.sh

# Build
# Windows:
.\scripts\build_windows.ps1
# macOS:
./scripts/build_macos.sh
```

### Development

```bash
flutter pub get
flutter run -d windows   # or: flutter run -d macos
```

## Tech Stack

| Component | Role |
|-----------|------|
| [Flutter](https://flutter.dev) | Cross-platform desktop UI |
| Native extractors | YouTube, X (Twitter), TikTok, Instagram and 11 more (see [Supported Sites](docs/supported-sites.md)), plus generic page analysis |
| Microsoft Edge / Google Chrome (off-screen window, user-installed) | Fallback capture for sites the generic analysis cannot parse; headless only if a real window cannot launch |
| [FFmpeg](https://ffmpeg.org) | Media encoding and processing |

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for details.

## Disclaimer

This software is provided for personal use. Users are responsible for ensuring compliance with applicable laws and the Terms of Service of each platform. Do not download copyrighted content without permission.

## License

[GPLv3](LICENSE)

Third-party: [FFmpeg](https://ffmpeg.org/legal.html) (GPL v2+)
