import 'package:flutter/material.dart';
import '../services/download_service.dart';
import '../../../core/utils/url_parser.dart';
import 'download_status_chip.dart';

/// Recent download history list (max 5 rows), with a secondary-tap context
/// menu hook passed through by the caller.
class DownloadHistorySection extends StatelessWidget {
  const DownloadHistorySection({
    super.key,
    required this.history,
    required this.onItemSecondaryTap,
  });

  final List<DownloadTask> history;
  final void Function(BuildContext context, Offset position, DownloadTask task)
      onItemSecondaryTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Download History',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 12),
        ListView.separated(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: history.length > 5 ? 5 : history.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final task = history[index];
            return Card(
              child: GestureDetector(
                onSecondaryTapUp: (details) {
                  onItemSecondaryTap(context, details.globalPosition, task);
                },
                child: ListTile(
                  leading: CircleAvatar(
                    child: Text(UrlParser.getPlatformIcon(task.platform)),
                  ),
                  title: Text(
                    task.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    task.type == DownloadType.video
                        ? '${task.options.videoFormat.label} - ${task.options.videoQuality.label}'
                        : '${task.options.audioFormat.label} - ${task.options.audioQuality.label}',
                  ),
                  trailing: DownloadStatusChip(status: task.status),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}
