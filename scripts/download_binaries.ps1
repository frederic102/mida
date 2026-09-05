# MiDa - Download required binaries for Windows
# Run this script before building the Windows version

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectDir = Split-Path -Parent $scriptDir
$binariesDir = Join-Path $projectDir "windows_binaries"

Write-Host "MiDa - Downloading required binaries..." -ForegroundColor Cyan

# Create binaries directory
if (-not (Test-Path $binariesDir)) {
    New-Item -ItemType Directory -Path $binariesDir | Out-Null
}

# Download FFmpeg
$ffmpegUrl = "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip"
$ffmpegZip = Join-Path $binariesDir "ffmpeg.zip"
$ffmpegPath = Join-Path $binariesDir "ffmpeg.exe"
$ffprobePath = Join-Path $binariesDir "ffprobe.exe"

if (-not (Test-Path $ffmpegPath)) {
    Write-Host "Downloading FFmpeg..." -ForegroundColor Yellow
    Invoke-WebRequest -Uri $ffmpegUrl -OutFile $ffmpegZip

    Write-Host "Extracting FFmpeg..." -ForegroundColor Yellow
    Expand-Archive -Path $ffmpegZip -DestinationPath $binariesDir -Force

    # Find and move executables
    $ffmpegDir = Get-ChildItem -Path $binariesDir -Directory -Filter "ffmpeg-*" | Select-Object -First 1
    if ($ffmpegDir) {
        $binDir = Join-Path $ffmpegDir.FullName "bin"
        Copy-Item (Join-Path $binDir "ffmpeg.exe") $binariesDir
        Copy-Item (Join-Path $binDir "ffprobe.exe") $binariesDir
        Remove-Item $ffmpegDir.FullName -Recurse -Force
    }

    Remove-Item $ffmpegZip -Force
    Write-Host "FFmpeg downloaded successfully!" -ForegroundColor Green
} else {
    Write-Host "FFmpeg already exists, skipping..." -ForegroundColor Gray
}

Write-Host ""
Write-Host "All binaries downloaded to: $binariesDir" -ForegroundColor Cyan
Write-Host ""
Write-Host "Files:" -ForegroundColor White
Get-ChildItem $binariesDir | ForEach-Object { Write-Host "  - $($_.Name)" }
Write-Host ""
Write-Host "Done! You can now build the Windows app." -ForegroundColor Green
