import 'package:flutter/material.dart';
import '../../../core/utils/file_utils.dart';
import '../screens/url_batch.dart';
import '../services/cli_command_builder.dart';
import '../services/download_queue_service.dart';
import '../services/download_service.dart';
import 'download_error_mapping.dart';
import 'download_error_panel.dart';

/// One row of the download queue: state, name, progress, per-item actions,
/// and (when failed) the actionable error panel.
class DownloadQueueItemTile extends StatelessWidget {
  const DownloadQueueItemTile({
    super.key,
    required this.item,
    required this.browserLoginEnabled,
    required this.onRemove,
    required this.onRetry,
    required this.onEnableBrowserLoginAndRetry,
    required this.onShowInFolder,
    required this.onCopyCliCommand,
    this.copyRefusal,
  });

  final QueueItem item;
  final bool browserLoginEnabled;
  final VoidCallback onRemove;
  final VoidCallback onRetry;
  final VoidCallback onEnableBrowserLoginAndRetry;
  final VoidCallback onShowInFolder;
  /// Null when no paste-safe command exists for this link (the button is
  /// then disabled and its tooltip shows [copyRefusal]).
  final VoidCallback? onCopyCliCommand;

  /// Why there is no command, for the disabled button's tooltip.
  final String? copyRefusal;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final error = item.state == QueueItemState.failed
        ? describeFailure(item.error ?? '', browserLoginEnabled: browserLoginEnabled)
        : null;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _StateIcon(state: item.state),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title ?? _shortUrl(item.url),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodyLarge?.copyWith(color: scheme.onSurface),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _subtitle(error),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall?.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                        color: error != null ? scheme.error : scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              ..._actions(),
            ],
          ),
          if (item.isActive) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: item.state == QueueItemState.downloading && item.progress > 0 ? item.progress : null,
                minHeight: 4,
              ),
            ),
          ],
          if (error != null) ...[
            const SizedBox(height: 10),
            DownloadErrorPanel(
              error: error,
              onRetry: onRetry,
              onEnableBrowserLoginAndRetry: onEnableBrowserLoginAndRetry,
            ),
          ],
        ],
      ),
    );
  }

  String _subtitle(ActionableError? error) {
    final kind = item.type == DownloadType.audio ? 'Audio' : 'Video';
    final head = '${linkHost(item.url)} · $kind';
    switch (item.state) {
      case QueueItemState.queued:
        return '$head · Waiting';
      case QueueItemState.fetching:
        return '$head · Reading the page';
      case QueueItemState.downloading:
        final pct = item.progress > 0 ? FileUtils.formatProgress(item.progress) : null;
        final message = item.statusMessage;
        if (message != null && pct != null) return '$head · $message ($pct)';
        return '$head · ${message ?? pct ?? 'Starting download'}';
      case QueueItemState.done:
        final path = item.outputPath;
        return path == null ? '$head · Saved' : '$head · Saved as ${_fileName(path)}';
      case QueueItemState.failed:
        return '$head · Failed';
    }
  }

  List<Widget> _actions() {
    switch (item.state) {
      case QueueItemState.fetching:
      case QueueItemState.downloading:
        return const [];
      case QueueItemState.queued:
        return [_remove()];
      case QueueItemState.failed:
        return [
          IconButton(tooltip: 'Retry', onPressed: onRetry, icon: const Icon(Icons.refresh, size: 20)),
          _remove(),
        ];
      case QueueItemState.done:
        return [
          if (item.outputPath != null)
            IconButton(
              tooltip: 'Show in folder',
              onPressed: onShowInFolder,
              icon: const Icon(Icons.folder_open_outlined, size: 20),
            ),
          IconButton(
            tooltip: onCopyCliCommand == null
                ? 'No command: ${copyRefusal ?? 'this download cannot be written as a PowerShell or bash command.'}'
                : CliCommandBuilder.label,
            onPressed: onCopyCliCommand,
            icon: const Icon(Icons.terminal, size: 20),
          ),
          _remove(),
        ];
    }
  }

  Widget _remove() => IconButton(
        tooltip: 'Remove from queue',
        onPressed: onRemove,
        icon: const Icon(Icons.close, size: 20),
      );

  static String _shortUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    final path = uri.path.length > 1 ? uri.path : '';
    return '${linkHost(url)}$path';
  }

  static String _fileName(String path) {
    final parts = path.split(RegExp(r'[\\/]'));
    return parts.isEmpty ? path : parts.last;
  }
}

class _StateIcon extends StatelessWidget {
  const _StateIcon({required this.state});

  final QueueItemState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (IconData icon, Color color, String label) = switch (state) {
      QueueItemState.queued => (Icons.schedule, scheme.onSurfaceVariant, 'Waiting'),
      QueueItemState.fetching => (Icons.travel_explore, scheme.primary, 'Reading the page'),
      QueueItemState.downloading => (Icons.downloading, scheme.primary, 'Downloading'),
      QueueItemState.done => (Icons.check_circle_outline, scheme.primary, 'Done'),
      QueueItemState.failed => (Icons.error_outline, scheme.error, 'Failed'),
    };
    return Icon(icon, size: 20, color: color, semanticLabel: label);
  }
}
