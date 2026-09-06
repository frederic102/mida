import '../services/download_service.dart';
import '../../../core/utils/file_utils.dart';

/// Pure formatting helper for [DownloadScreen] progress text.
///
/// Extracted from the screen's build methods with no behavior change.
String downloadProgressText(DownloadTask task) {
  switch (task.status) {
    case DownloadStatus.idle:
      return 'Waiting...';
    case DownloadStatus.fetching:
      return 'Fetching video info...';
    case DownloadStatus.downloading:
      if (task.statusMessage != null) {
        if (task.progress > 0) {
          return '${task.statusMessage} (${FileUtils.formatProgress(task.progress)})';
        }
        return task.statusMessage!;
      }
      if (task.progress == 0) {
        return 'Preparing download...';
      }
      return '${FileUtils.formatProgress(task.progress)} complete';
    case DownloadStatus.completed:
      return 'Download complete!';
    case DownloadStatus.error:
      return 'Error occurred';
  }
}
