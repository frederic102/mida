#!/bin/bash
# MiDa - Build macOS Application
# This script builds the macOS app and packages it with required binaries

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BINARIES_DIR="$PROJECT_DIR/macos_binaries"
BUILD_DIR="$PROJECT_DIR/build/macos/Build/Products/Release"
OUTPUT_DIR="$PROJECT_DIR/dist/macos"

echo "======================================"
echo "       MiDa - macOS Build            "
echo "======================================"
echo ""

# Check if binaries exist
if [ ! -f "$BINARIES_DIR/yt-dlp" ]; then
    echo "Binaries not found. Running download script..."
    bash "$SCRIPT_DIR/download_binaries_mac.sh"
fi

# Clean previous build
echo "Cleaning previous build..."
cd "$PROJECT_DIR"
flutter clean

# Get dependencies
echo "Getting dependencies..."
flutter pub get

# Build macOS release
echo "Building macOS release..."
flutter build macos --release

if [ $? -ne 0 ]; then
    echo "Build failed!"
    exit 1
fi

# Create output directory
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

# Copy app bundle
echo "Copying app bundle..."
cp -R "$BUILD_DIR/mida.app" "$OUTPUT_DIR/MiDa.app"

# Copy binaries to app bundle Resources
RESOURCES_DIR="$OUTPUT_DIR/MiDa.app/Contents/Resources"
echo "Copying binaries to app bundle..."
cp "$BINARIES_DIR/yt-dlp" "$RESOURCES_DIR/"
cp "$BINARIES_DIR/ffmpeg" "$RESOURCES_DIR/"
cp "$BINARIES_DIR/ffprobe" "$RESOURCES_DIR/"

# Make binaries executable
chmod +x "$RESOURCES_DIR/yt-dlp"
chmod +x "$RESOURCES_DIR/ffmpeg"
chmod +x "$RESOURCES_DIR/ffprobe"

echo ""
echo "======================================"
echo "       Build Complete!               "
echo "======================================"
echo ""
echo "Output: $OUTPUT_DIR/MiDa.app"
echo ""
echo "To run the app:"
echo "  1. Move MiDa.app to /Applications"
echo "  2. Right-click and select 'Open' (first time only)"
echo ""

# Create DMG (optional)
echo "Creating DMG installer..."
hdiutil create -volname "MiDa" -srcfolder "$OUTPUT_DIR/MiDa.app" -ov -format UDZO "$OUTPUT_DIR/MiDa.dmg"
echo "DMG created: $OUTPUT_DIR/MiDa.dmg"
