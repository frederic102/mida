import 'package:flutter/material.dart';
import '../../../core/utils/url_parser.dart';

/// URL entry card with paste button and detected-platform pill.
class DownloadUrlInputCard extends StatelessWidget {
  const DownloadUrlInputCard({
    super.key,
    required this.controller,
    required this.onChanged,
    required this.onPaste,
    required this.onClear,
    required this.isValidUrl,
    required this.detectedPlatform,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onPaste;
  final VoidCallback onClear;
  final bool isValidUrl;
  final PlatformType? detectedPlatform;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Enter URL',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: controller,
                    onChanged: onChanged,
                    decoration: InputDecoration(
                      hintText: 'YouTube, Twitter, Instagram, TikTok URL',
                      prefixIcon: const Icon(Icons.link),
                      suffixIcon: controller.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: onClear,
                            )
                          : null,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: onPaste,
                  icon: const Icon(Icons.paste),
                  label: const Text('Paste'),
                ),
              ],
            ),
            if (detectedPlatform != null && isValidUrl) ...[
              const SizedBox(height: 12),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      UrlParser.getPlatformIcon(detectedPlatform!),
                      style: const TextStyle(fontSize: 18),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      UrlParser.getPlatformName(detectedPlatform!),
                      style: TextStyle(
                        color:
                            Theme.of(context).colorScheme.onPrimaryContainer,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
