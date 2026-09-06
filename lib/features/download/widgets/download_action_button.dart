import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/download_service.dart';

/// Start-download button, disabled while a task is in flight or the URL
/// is invalid.
class DownloadActionButton extends StatelessWidget {
  const DownloadActionButton({
    super.key,
    required this.isValidUrl,
    required this.onPressed,
  });

  final bool isValidUrl;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Consumer<DownloadService>(
      builder: (context, service, child) {
        final isDownloading =
            service.currentTask?.status == DownloadStatus.downloading ||
                service.currentTask?.status == DownloadStatus.fetching;

        return FilledButton.icon(
          onPressed: isValidUrl && !isDownloading ? onPressed : null,
          icon: isDownloading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.download),
          label: Text(isDownloading ? 'Downloading...' : 'Start Download'),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 20),
          ),
        );
      },
    );
  }
}
