import 'package:flutter/material.dart';
import 'download_error_mapping.dart';

/// Failure explanation under a failed queue row: what happened, the next
/// step, at most one action button, and the redacted raw text on demand.
class DownloadErrorPanel extends StatefulWidget {
  const DownloadErrorPanel({
    super.key,
    required this.error,
    required this.onRetry,
    required this.onEnableBrowserLoginAndRetry,
  });

  final ActionableError error;
  final VoidCallback onRetry;
  final VoidCallback onEnableBrowserLoginAndRetry;

  @override
  State<DownloadErrorPanel> createState() => _DownloadErrorPanelState();
}

class _DownloadErrorPanelState extends State<DownloadErrorPanel> {
  bool _showDetails = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final error = widget.error;
    final onPanel = scheme.onErrorContainer;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.error.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            error.headline,
            style: text.bodyMedium?.copyWith(color: onPanel, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(error.nextStep, style: text.bodySmall?.copyWith(color: onPanel)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (error.action == FailureAction.enableBrowserLoginAndRetry)
                FilledButton.tonalIcon(
                  onPressed: widget.onEnableBrowserLoginAndRetry,
                  icon: const Icon(Icons.login, size: 18),
                  label: const Text('Use browser login and retry'),
                ),
              if (error.action == FailureAction.retry)
                OutlinedButton.icon(
                  onPressed: widget.onRetry,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Retry'),
                ),
              if (error.details.isNotEmpty)
                TextButton(
                  onPressed: () => setState(() => _showDetails = !_showDetails),
                  child: Text(_showDetails ? 'Hide details' : 'Show details'),
                ),
            ],
          ),
          if (_showDetails) ...[
            const SizedBox(height: 4),
            SelectableText(
              error.details,
              style: text.bodySmall?.copyWith(color: onPanel.withValues(alpha: 0.8)),
            ),
            const SizedBox(height: 4),
          ],
        ],
      ),
    );
  }
}
