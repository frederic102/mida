import 'package:flutter/material.dart';
import '../services/download_service.dart';
import '../screens/download_screen_helpers.dart';
import '../../../core/utils/url_parser.dart';
import 'download_status_chip.dart';

/// Progress card shown while a download task is active.
class DownloadProgressCard extends StatelessWidget {
  const DownloadProgressCard({super.key, required this.task});

  final DownloadTask task;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  UrlParser.getPlatformIcon(task.platform),
                  style: const TextStyle(fontSize: 24),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        task.title,
                        style: Theme.of(context).textTheme.titleMedium,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (task.duration != null)
                        Text(
                          task.duration!,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                    ],
                  ),
                ),
                DownloadStatusChip(status: task.status),
              ],
            ),
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: task.status == DownloadStatus.fetching
                    ? null
                    : task.progress,
                minHeight: 8,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              downloadProgressText(task),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (task.error != null) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  task.error!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onErrorContainer,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
