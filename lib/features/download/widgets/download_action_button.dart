import 'package:flutter/material.dart';

/// Primary "start" button. Adding links while the queue is running is
/// allowed, so it is only disabled when the field holds no usable link.
class DownloadActionButton extends StatelessWidget {
  const DownloadActionButton({
    super.key,
    required this.linkCount,
    required this.queueBusy,
    required this.onPressed,
  });

  final int linkCount;
  final bool queueBusy;
  final VoidCallback onPressed;

  static String labelFor({required int linkCount, required bool queueBusy}) {
    if (queueBusy) {
      return linkCount > 1 ? 'Add $linkCount links to queue' : 'Add to queue';
    }
    return linkCount > 1 ? 'Download $linkCount links' : 'Download';
  }

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      key: const ValueKey('start-download'),
      onPressed: linkCount > 0 ? onPressed : null,
      icon: Icon(queueBusy ? Icons.playlist_add : Icons.download),
      label: Text(labelFor(linkCount: linkCount, queueBusy: queueBusy)),
      style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 20)),
    );
  }
}
