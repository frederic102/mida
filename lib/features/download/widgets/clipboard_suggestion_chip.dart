import 'package:flutter/material.dart';
import '../screens/url_batch.dart';

/// Inline offer to insert link(s) found on the clipboard. Only ever
/// inserts on click; never starts a download.
class ClipboardSuggestionChip extends StatelessWidget {
  const ClipboardSuggestionChip({
    super.key,
    required this.urls,
    required this.onInsert,
    required this.onDismiss,
  });

  final List<String> urls;
  final VoidCallback onInsert;
  final VoidCallback onDismiss;

  static String labelFor(List<String> urls) =>
      urls.length == 1 ? 'Paste ${linkHost(urls.single)}' : 'Paste ${urls.length} links';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InputChip(
      key: const ValueKey('clipboard-suggestion'),
      avatar: Icon(Icons.content_paste, size: 16, color: scheme.primary),
      label: Text(labelFor(urls)),
      tooltip: urls.length == 1 ? urls.single : urls.join('\n'),
      onPressed: onInsert,
      onDeleted: onDismiss,
      deleteButtonTooltipMessage: 'Dismiss',
    );
  }
}
