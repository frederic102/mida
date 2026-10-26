import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../screens/url_batch.dart';
import 'clipboard_suggestion_chip.dart';

/// Link entry card: accepts one or many links (one per line or separated
/// by spaces), Enter starts, Shift+Enter adds a line, Esc clears.
class DownloadUrlInputCard extends StatelessWidget {
  const DownloadUrlInputCard({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.batch,
    required this.onChanged,
    required this.onPaste,
    required this.onClear,
    required this.onSubmit,
    required this.suggestion,
    required this.onAcceptSuggestion,
    required this.onDismissSuggestion,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final UrlBatch batch;
  final ValueChanged<String> onChanged;
  final VoidCallback onPaste;
  final VoidCallback onClear;
  final VoidCallback onSubmit;
  final List<String>? suggestion;
  final VoidCallback onAcceptSuggestion;
  final VoidCallback onDismissSuggestion;

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
            Text('Links', style: text.titleMedium),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: CallbackShortcuts(
                    bindings: {
                      const SingleActivator(LogicalKeyboardKey.enter): onSubmit,
                      const SingleActivator(LogicalKeyboardKey.numpadEnter): onSubmit,
                      const SingleActivator(LogicalKeyboardKey.escape): onClear,
                    },
                    child: TextField(
                      key: const ValueKey('url-field'),
                      controller: controller,
                      focusNode: focusNode,
                      onChanged: onChanged,
                      minLines: 1,
                      maxLines: 6,
                      keyboardType: TextInputType.multiline,
                      decoration: InputDecoration(
                        hintText: 'Paste one or more video links, one per line',
                        prefixIcon: const Icon(Icons.link),
                        suffixIcon: controller.text.isNotEmpty
                            ? IconButton(
                                tooltip: 'Clear (Esc)',
                                icon: const Icon(Icons.clear),
                                onPressed: onClear,
                              )
                            : null,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: onPaste,
                  icon: const Icon(Icons.paste, size: 18),
                  label: const Text('Paste'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (suggestion != null)
                  ClipboardSuggestionChip(
                    urls: suggestion!,
                    onInsert: onAcceptSuggestion,
                    onDismiss: onDismissSuggestion,
                  ),
                Text(_status(), style: muted),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _status() {
    final count = batch.urls.length;
    final skipped = batch.skipped;
    if (count == 0 && skipped == 0) {
      return 'Enter to start · Shift+Enter for a new line · Esc to clear';
    }
    if (count == 0) return 'No http or https link found yet.';
    final ready = count == 1 ? '1 link ready' : '$count links ready';
    if (skipped == 0) return ready;
    final word = skipped == 1 ? 'entry' : 'entries';
    return '$ready, $skipped $word skipped (not an http or https link)';
  }
}
