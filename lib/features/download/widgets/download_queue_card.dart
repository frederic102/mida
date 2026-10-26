import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../settings/settings_service.dart';
import '../../../core/utils/file_utils.dart';
import '../services/download_queue_service.dart';
import 'download_queue_item_tile.dart';

/// The session's download queue. Hidden while empty.
class DownloadQueueCard extends StatelessWidget {
  const DownloadQueueCard({super.key});

  @override
  Widget build(BuildContext context) {
    final queue = context.watch<DownloadQueueService>();
    final loginOn = context.select<SettingsService, bool>((s) => s.useBrowserLoginSession);
    final items = queue.items;
    if (items.isEmpty) return const SizedBox.shrink();

    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text('Queue', style: text.titleMedium),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _summary(items),
                    style: text.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                if (queue.hasFinished)
                  TextButton(
                    onPressed: queue.clearFinished,
                    child: const Text('Clear finished'),
                  ),
              ],
            ),
            for (var i = 0; i < items.length; i++) ...[
              if (i > 0) const Divider(),
              DownloadQueueItemTile(
                key: ValueKey(items[i].id),
                item: items[i],
                browserLoginEnabled: loginOn,
                onRemove: () => queue.remove(items[i].id),
                onRetry: () => queue.retry(items[i].id),
                onEnableBrowserLoginAndRetry: () => _enableLoginAndRetry(context, items[i].id),
                onShowInFolder: () => FileUtils.openFileLocation(items[i].outputPath!),
                onCopyCliCommand: _copyAction(context, queue.cliCommandFor(items[i]).command),
                copyRefusal: queue.cliCommandFor(items[i]).refusal,
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _summary(List<QueueItem> items) {
    final done = items.where((i) => i.state == QueueItemState.done).length;
    final failed = items.where((i) => i.state == QueueItemState.failed).length;
    final parts = ['$done of ${items.length} done'];
    if (failed > 0) parts.add('$failed failed');
    return parts.join(' · ');
  }

  static Future<void> _enableLoginAndRetry(BuildContext context, int id) async {
    final settings = context.read<SettingsService>();
    final queue = context.read<DownloadQueueService>();
    await settings.setUseBrowserLoginSession(true);
    queue.retry(id);
  }

  static VoidCallback? _copyAction(BuildContext context, String? command) =>
      command == null ? null : () => _copyCli(context, command);

  static Future<void> _copyCli(BuildContext context, String command) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    await Clipboard.setData(ClipboardData(text: command));
    messenger?.showSnackBar(const SnackBar(content: Text('Command copied (PowerShell or bash)')));
  }
}
