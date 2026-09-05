import 'dart:io';

/// Single source for finding the ffmpeg/ffprobe executables bundled next to
/// the app. Extracted so compress/extract/download all resolve the same
/// way instead of each carrying its own copy (DRY; previously duplicated
/// across `CompressService`, `ExtractService`, and `DownloadService`).
class FfmpegLocator {
  const FfmpegLocator._();

  static Future<String> ffmpegPath() => _resolve('ffmpeg.exe', 'ffmpeg');

  static Future<String> ffprobePath() => _resolve('ffprobe.exe', 'ffprobe');

  static Future<String> _resolve(String windowsFileName, String posixName) async {
    if (Platform.isWindows) {
      final appDir = File(Platform.resolvedExecutable).parent.path;
      final bundled = '$appDir/$windowsFileName';
      if (await File(bundled).exists()) return bundled;
      return posixName;
    }
    if (Platform.isMacOS) {
      final appDir = File(Platform.resolvedExecutable).parent.parent.path;
      final bundled = '$appDir/Resources/$posixName';
      if (await File(bundled).exists()) return bundled;
      return posixName;
    }
    return posixName;
  }
}
