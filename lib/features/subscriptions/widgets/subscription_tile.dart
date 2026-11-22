import 'package:flutter/material.dart';
import '../../../core/subscriptions/subscription.dart';
import '../../../core/utils/display_text.dart';

/// "2026-11-22 14:05" in local time (the app has no date-format package).
String formatChecked(DateTime t) {
  final l = t.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
}

/// One subscribed channel: title (editable), folder, last check, remove.
class SubscriptionTile extends StatelessWidget {
  const SubscriptionTile({
    super.key,
    required this.sub,
    required this.error,
    required this.onRename,
    required this.onChooseFolder,
    required this.onUseDefaultFolder,
    required this.onRemove,
  });

  final Subscription sub;

  /// Why the last check of this channel failed, if it did.
  final String? error;
  final VoidCallback onRename;
  final VoidCallback onChooseFolder;
  final VoidCallback onUseDefaultFolder;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final muted = text.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final last = sub.lastChecked;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  displayText(sub.title).isEmpty ? displayText(sub.source) : displayText(sub.title),
                  style: text.titleSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(tooltip: 'Rename', icon: const Icon(Icons.edit_outlined, size: 18), onPressed: onRename),
              IconButton(tooltip: 'Remove subscription', icon: const Icon(Icons.delete_outline, size: 18), onPressed: onRemove),
            ],
          ),
          Text(displayText(sub.source), style: muted, maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 4),
          Text(last == null ? 'Not checked yet' : 'Last checked ${formatChecked(last)}', style: muted),
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(sub.outputDir == null ? 'Saves to the default folder' : 'Saves to ${sub.outputDir}', style: muted),
              TextButton(onPressed: onChooseFolder, child: const Text('Change folder')),
              if (sub.outputDir != null) TextButton(onPressed: onUseDefaultFolder, child: const Text('Use default')),
            ],
          ),
          if (error != null) Text(error!, style: text.bodySmall?.copyWith(color: scheme.error)),
        ],
      ),
    );
  }
}
