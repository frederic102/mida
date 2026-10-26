import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../settings_service.dart';

/// "Downloads" card on the Settings screen.
class DownloadsSettingsSection extends StatelessWidget {
  const DownloadsSettingsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    final scheme = Theme.of(context).colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.download_done, color: scheme.primary),
                const SizedBox(width: 12),
                Text('Downloads', style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 16),
            SwitchListTile(
              key: const ValueKey('open-folder-after-download'),
              title: const Text('Open folder after download'),
              subtitle: const Text(
                'Shows the download folder once the queue finishes, '
                'if at least one file was saved.',
              ),
              value: settings.openFolderAfterDownload,
              onChanged: settings.setOpenFolderAfterDownload,
              secondary: const Icon(Icons.folder_open_outlined),
            ),
          ],
        ),
      ),
    );
  }
}
