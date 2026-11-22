import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/subscription_list.dart';

/// "Add a channel": the link, an optional folder for this channel, Add.
class AddSubscriptionCard extends StatefulWidget {
  const AddSubscriptionCard({super.key, required this.pickFolder});

  final Future<String?> Function() pickFolder;

  @override
  State<AddSubscriptionCard> createState() => _AddSubscriptionCardState();
}

class _AddSubscriptionCardState extends State<AddSubscriptionCard> {
  final _controller = TextEditingController();
  String? _folder;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    if (_busy || _controller.text.trim().isEmpty) return;
    final list = context.read<SubscriptionList>();
    setState(() {
      _busy = true;
      _error = null;
    });
    final error = await list.add(_controller.text, outputDir: _folder);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
      if (error == null) {
        _controller.clear();
        _folder = null;
      }
    });
  }

  Future<void> _chooseFolder() async {
    final dir = await widget.pickFolder();
    if (dir != null && mounted) setState(() => _folder = dir);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final muted = text.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Add a channel', style: text.titleMedium),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('sub-url-field'),
              controller: _controller,
              enabled: !_busy,
              onSubmitted: (_) => _add(),
              decoration: const InputDecoration(
                hintText: 'Channel link, for example https://www.youtube.com/@name',
                prefixIcon: Icon(Icons.link),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton.icon(
                  key: const ValueKey('sub-add-folder'),
                  onPressed: _busy ? null : _chooseFolder,
                  icon: const Icon(Icons.folder_open, size: 18),
                  label: const Text('Folder'),
                ),
                Text(_folder ?? 'Default download folder', style: muted),
                if (_folder != null)
                  TextButton(onPressed: () => setState(() => _folder = null), child: const Text('Use default')),
              ],
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const ValueKey('sub-add'),
              onPressed: _busy ? null : _add,
              icon: _busy
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.add),
              label: Text(_busy ? 'Reading the channel...' : 'Subscribe'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, key: const ValueKey('sub-add-error'), style: text.bodySmall?.copyWith(color: scheme.error)),
            ],
            const SizedBox(height: 8),
            Text(
              'Only videos published after you subscribe are downloaded automatically.',
              style: muted,
            ),
          ],
        ),
      ),
    );
  }
}
