#!/bin/bash
# MiDa - Download required binaries for macOS
# Run this script before building the macOS version

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BINARIES_DIR="$PROJECT_DIR/macos_binaries"

echo "MiDa - Downloading required binaries..."

# Create binaries directory
mkdir -p "$BINARIES_DIR"

# Detect architecture
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
    FFMPEG_ARCH="arm64"
    YTDLP_ARCH="macos"
else
    FFMPEG_ARCH="x86_64"
    YTDLP_ARCH="macos_legacy"
fi

# Download yt-dlp
YTDLP_URL="https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_${YTDLP_ARCH}"
YTDLP_PATH="$BINARIES_DIR/yt-dlp"

if [ ! -f "$YTDLP_PATH" ]; then
    echo "Downloading yt-dlp..."
    curl -L "$YTDLP_URL" -o "$YTDLP_PATH"
    chmod +x "$YTDLP_PATH"
    echo "yt-dlp downloaded successfully!"
else
    echo "yt-dlp already exists, skipping..."
fi

# Download FFmpeg (using evermeet.cx for macOS builds)
FFMPEG_PATH="$BINARIES_DIR/ffmpeg"
FFPROBE_PATH="$BINARIES_DIR/ffprobe"

if [ ! -f "$FFMPEG_PATH" ]; then
    echo "Downloading FFmpeg..."

    # Download ffmpeg
    curl -L "https://evermeet.cx/ffmpeg/getrelease/ffmpeg/zip" -o "$BINARIES_DIR/ffmpeg.zip"
    unzip -o "$BINARIES_DIR/ffmpeg.zip" -d "$BINARIES_DIR"
    chmod +x "$FFMPEG_PATH"
    rm "$BINARIES_DIR/ffmpeg.zip"

    # Download ffprobe
    curl -L "https://evermeet.cx/ffmpeg/getrelease/ffprobe/zip" -o "$BINARIES_DIR/ffprobe.zip"
    unzip -o "$BINARIES_DIR/ffprobe.zip" -d "$BINARIES_DIR"
    chmod +x "$FFPROBE_PATH"
    rm "$BINARIES_DIR/ffprobe.zip"

    echo "FFmpeg downloaded successfully!"
else
    echo "FFmpeg already exists, skipping..."
fi

echo ""
echo "All binaries downloaded to: $BINARIES_DIR"
echo ""
echo "Files:"
ls -la "$BINARIES_DIR"
echo ""
echo "Done! You can now build the macOS app."
