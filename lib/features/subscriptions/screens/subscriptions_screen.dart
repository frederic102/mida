import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/subscriptions/subscription.dart';
import '../../download/services/cli_command_builder.dart';
import '../services/subscription_list.dart';
import '../services/subscription_scheduler.dart';
import '../widgets/add_subscription_card.dart';
import '../widgets/subscription_check_card.dart';
import '../widgets/subscription_tile.dart';

Future<String?> _pickWithFilePicker() => FilePicker.platform.getDirectoryPath();

/// Subscribed channels: add, remove, rename, per-channel folder, check now,
/// and the check interval. The checks themselves run in
/// [SubscriptionScheduler] whether or not this screen is open.
class SubscriptionsScreen extends StatelessWidget {
  /// [pickFolder] exists for tests; the app uses the system folder picker.
  const SubscriptionsScreen({super.key, this.pickFolder});

  final Future<String?> Function()? pickFolder;

  @override
  Widget build(BuildContext context) {
    final pick = pickFolder ?? _pickWithFilePicker;
    final warning = context.read<SubscriptionList>().storageWarning;
    return Scaffold(
      appBar: AppBar(title: const Text('Subscriptions')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (warning != null) ...[
              Card(
                key: const ValueKey('sub-storage-warning'),
                color: Theme.of(context).colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Icon(Icons.warning_amber_rounded, color: Theme.of(context).colorScheme.onErrorContainer),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          warning,
                          style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
            ],
            AddSubscriptionCard(pickFolder: pick),
            const SizedBox(height: 24),
            const SubscriptionCheckCard(),
            const SizedBox(height: 24),
            _ChannelsCard(pickFolder: pick),
          ],
        ),
      ),
    );
  }
}

class _ChannelsCard extends StatelessWidget {
  const _ChannelsCard({required this.pickFolder});

  final Future<String?> Function() pickFolder;

  Future<void> _show(BuildContext context, Future<String?> result) async {
    final error = await result;
    if (error != null && context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(error)));
    }
  }

  Future<void> _rename(BuildContext context, SubscriptionList list, Subscription sub) async {
    final controller = TextEditingController(text: sub.title);
    final title = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename channel'),
        content: TextField(key: const ValueKey('sub-rename-field'), controller: controller, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Save')),
        ],
      ),
    );
    controller.dispose();
    if (title != null && context.mounted) await _show(context, list.rename(sub, title));
  }

  @override
  Widget build(BuildContext context) {
    final list = context.watch<SubscriptionList>();
    final scheduler = context.watch<SubscriptionScheduler>();
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final muted = text.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final cli = const CliCommandBuilder().sync(subscriptions: list.store.file.path, archive: scheduler.archiveFile.path);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Channels (${list.items.length})', style: text.titleMedium),
            if (list.loadError != null) ...[
              const SizedBox(height: 8),
              Text(
                '${list.loadError} The file is left as it is; fix or remove it to continue.',
                key: const ValueKey('sub-load-error'),
                style: text.bodySmall?.copyWith(color: scheme.error),
              ),
            ],
            if (list.items.isEmpty && list.loadError == null) ...[
              const SizedBox(height: 8),
              Text('No subscriptions yet.', style: muted),
            ],
            for (final (i, sub) in list.items.indexed) ...[
              if (i > 0) const Divider(),
              SubscriptionTile(
                key: ValueKey('sub-${sub.source}'),
                sub: sub,
                error: scheduler.errorFor(sub),
                onRename: () => _rename(context, list, sub),
                onRemove: () => _show(context, list.remove(sub)),
                onChooseFolder: () async {
                  final dir = await pickFolder();
                  if (dir != null && context.mounted) await _show(context, list.setOutputDir(sub, dir));
                },
                onUseDefaultFolder: () => _show(context, list.setOutputDir(sub, null)),
              ),
            ],
            const SizedBox(height: 12),
            SelectableText('Stored in ${list.store.file.path}', style: muted),
            const SizedBox(height: 4),
            SelectableText(
              key: const ValueKey('sub-cli-command'),
              cli.command == null
                  ? 'No mida-cli command is shown: ${cli.refusal}'
                  : 'Run the same data from a script with: ${cli.command}',
              style: muted,
            ),
          ],
        ),
      ),
    );
  }
}
