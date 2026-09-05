# MiDa - Build Windows Application
# This script builds the Windows executable and packages it with required binaries

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectDir = Split-Path -Parent $scriptDir
$binariesDir = Join-Path $projectDir "windows_binaries"
$buildDir = Join-Path $projectDir "build\windows\x64\runner\Release"
$outputDir = Join-Path $projectDir "dist\windows"

Write-Host "======================================" -ForegroundColor Cyan
Write-Host "       MiDa - Windows Build          " -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan
Write-Host ""

# Check if binaries exist
if (-not (Test-Path (Join-Path $binariesDir "ffmpeg.exe"))) {
    Write-Host "Binaries not found. Running download script..." -ForegroundColor Yellow
    & (Join-Path $scriptDir "download_binaries.ps1")
}

# Clean previous build
Write-Host "Cleaning previous build..." -ForegroundColor Yellow
Set-Location $projectDir
& flutter clean

# Get dependencies
Write-Host "Getting dependencies..." -ForegroundColor Yellow
& flutter pub get

# Build Windows release
Write-Host "Building Windows release..." -ForegroundColor Yellow
& flutter build windows --release

if ($LASTEXITCODE -ne 0) {
    Write-Host "Build failed!" -ForegroundColor Red
    exit 1
}

# Create output directory
if (Test-Path $outputDir) {
    Remove-Item $outputDir -Recurse -Force
}
New-Item -ItemType Directory -Path $outputDir | Out-Null

# Copy build files
Write-Host "Copying build files..." -ForegroundColor Yellow
Copy-Item "$buildDir\*" $outputDir -Recurse

# Copy binaries
Write-Host "Copying binaries..." -ForegroundColor Yellow
Copy-Item (Join-Path $binariesDir "ffmpeg.exe") $outputDir
Copy-Item (Join-Path $binariesDir "ffprobe.exe") $outputDir

# Rename executable
$oldExe = Join-Path $outputDir "mida.exe"
$newExe = Join-Path $outputDir "MiDa.exe"
if (Test-Path $oldExe) {
    Rename-Item $oldExe $newExe
}

Write-Host ""
Write-Host "======================================" -ForegroundColor Green
Write-Host "       Build Complete!               " -ForegroundColor Green
Write-Host "======================================" -ForegroundColor Green
Write-Host ""
Write-Host "Output: $outputDir" -ForegroundColor White
Write-Host ""
Write-Host "Files:" -ForegroundColor White
Get-ChildItem $outputDir | ForEach-Object { Write-Host "  - $($_.Name)" }
Write-Host ""
Write-Host "To run the app, execute: MiDa.exe" -ForegroundColor Cyan
