import 'package:flutter/material.dart';
import '../services/download_service.dart';

/// Status pill shown on the current download task and history rows.
class DownloadStatusChip extends StatelessWidget {
  const DownloadStatusChip({super.key, required this.status});

  final DownloadStatus status;

  @override
  Widget build(BuildContext context) {
    Color color;
    String label;
    IconData icon;

    switch (status) {
      case DownloadStatus.idle:
        color = Colors.grey;
        label = 'Idle';
        icon = Icons.hourglass_empty;
        break;
      case DownloadStatus.fetching:
        color = Colors.blue;
        label = 'Analyzing';
        icon = Icons.search;
        break;
      case DownloadStatus.downloading:
        color = Colors.orange;
        label = 'Downloading';
        icon = Icons.downloading;
        break;
      case DownloadStatus.completed:
        color = Colors.green;
        label = 'Done';
        icon = Icons.check_circle;
        break;
      case DownloadStatus.error:
        color = Colors.red;
        label = 'Error';
        icon = Icons.error;
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
