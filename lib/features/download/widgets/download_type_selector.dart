import 'package:flutter/material.dart';
import '../services/download_service.dart';

/// Video/Audio type selector card shown on the download screen.
class DownloadTypeSelectorCard extends StatelessWidget {
  const DownloadTypeSelectorCard({
    super.key,
    required this.selectedType,
    required this.onTypeSelected,
  });

  final DownloadType selectedType;
  final ValueChanged<DownloadType> onTypeSelected;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Download Type',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _DownloadTypeOption(
                    icon: Icons.videocam,
                    label: 'Video (MP4)',
                    subtitle: 'Video with audio',
                    isSelected: selectedType == DownloadType.video,
                    onTap: () => onTypeSelected(DownloadType.video),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _DownloadTypeOption(
                    icon: Icons.audiotrack,
                    label: 'Audio (MP3)',
                    subtitle: 'Audio only',
                    isSelected: selectedType == DownloadType.audio,
                    onTap: () => onTypeSelected(DownloadType.audio),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DownloadTypeOption extends StatelessWidget {
  const _DownloadTypeOption({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.isSelected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String subtitle;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          border: Border.all(
            color: isSelected
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.outline.withOpacity(0.3),
            width: isSelected ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(12),
          color: isSelected
              ? Theme.of(context).colorScheme.primaryContainer.withOpacity(0.3)
              : null,
        ),
        child: Column(
          children: [
            Icon(
              icon,
              size: 32,
              color: isSelected
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 8),
            Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: isSelected
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
