<p align="center">
  <img src="assets/logo.png" width="100" height="100" alt="MiDa">
</p>

<h1 align="center">MiDa</h1>

<p align="center">
  Desktop media downloader & encoder powered by yt-dlp and FFmpeg.
</p>

<p align="center">
  <img src="https://img.shields.io/github/v/release/frederic102/mida?style=flat-square&color=brightgreen" alt="Release">
  <img src="https://img.shields.io/badge/license-GPLv3-blue?style=flat-square" alt="License">
  <img src="https://img.shields.io/badge/platform-Windows%20%7C%20macOS-blue?style=flat-square" alt="Platform">
  <img src="https://img.shields.io/badge/Flutter-3.5+-02569B?style=flat-square&logo=flutter" alt="Flutter">
</p>

---

<p align="center">
  <img src="docs/mida-promo.gif" width="800" alt="MiDa Demo">
</p>

## Features

- **Video Download** - YouTube, Twitter/X, Instagram, TikTok and more
- **Audio Download** - Extract audio in MP3, M4A, FLAC, WAV, Opus
- **Video Compression** - Two-pass encoding with target file size (presets or custom)
- **Audio Extraction** - Extract audio tracks from local video files
- **Subtitle Download** - Download subtitles as .srt files

## Download

Go to [**Releases**](https://github.com/frederic102/mida/releases/latest) and download the installer for your platform.

| Platform | File | Requirements |
|----------|------|--------------|
| Windows | `MiDa_Setup_v*.exe` | Windows 10+ |
| macOS | `MiDa.dmg` | macOS 11+ |

Bundled dependencies (yt-dlp, FFmpeg) are included in the installer. No additional setup required.

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

# Download yt-dlp and FFmpeg (first time only)
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
| [yt-dlp](https://github.com/yt-dlp/yt-dlp) | Video/audio download engine |
| [FFmpeg](https://ffmpeg.org) | Media encoding and processing |

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for details.

## Disclaimer

This software is provided for personal use. Users are responsible for ensuring compliance with applicable laws and the Terms of Service of each platform. Do not download copyrighted content without permission.

## License

[GPLv3](LICENSE)

Third-party: [FFmpeg](https://ffmpeg.org/legal.html) (GPL v2+), [yt-dlp](https://github.com/yt-dlp/yt-dlp/blob/master/LICENSE) (Unlicense)
