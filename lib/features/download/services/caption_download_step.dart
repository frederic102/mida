import 'dart:io';

import '../../../core/download/caption_downloader.dart';
import '../../../core/download/media_merger.dart';
import '../../../core/extractors/media_models.dart';
import '../../../core/utils/file_utils.dart';
import 'download_service_io.dart';

/// Downloads and converts every requested subtitle track for one download.
/// Split out of `MediaDownloadPipeline` to keep that file under this
/// project's 400-line cap. Captions are a nice-to-have: any failure here
/// (network, ffmpeg conversion, ...) is reported via [onStatus] and
/// skipped, never surfaced as a failure of the main download.
class CaptionDownloadStep {
  final CaptionDownloader _captionDownloader;
  final MediaMerger _merger;

  CaptionDownloadStep({required CaptionDownloader captionDownloader, required MediaMerger merger})
      : _captionDownloader = captionDownloader,
        _merger = merger;

  Future<void> run({
    required MediaInfo info,
    required DownloadOptions options,
    required String baseName,
    required String outputDir,
    required String tempPrefix,
    required Map<String, String> headers,
    void Function(String message)? onStatus,
  }) async {
    final plans = CaptionDownloader.selectPlans(info.captions, info.translatableLanguageCodes, options.subtitleOption);
    for (final plan in plans) {
      final vttTemp = '$tempPrefix.${plan.outputLanguageCode}.vtt';
      try {
        await _captionDownloader.download(
          plan.sourceTrack,
          vttTemp,
          translateTo: plan.translateTo,
          headers: headers,
        );
        final srtPath = await FileUtils.getUniqueFilePath('$outputDir/$baseName.${plan.outputLanguageCode}.srt');
        await _merger.run(['-y', '-i', vttTemp, srtPath]);
      } catch (e) {
        // Captions are a nice-to-have: never fail the main download for them.
        onStatus?.call('Subtitle (${plan.outputLanguageCode}) skipped: $e');
      } finally {
        await _tryDelete(vttTemp);
      }
    }
  }

  Future<void> _tryDelete(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Best effort cleanup only.
    }
  }
}
