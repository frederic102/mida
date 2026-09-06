import 'package:flutter/material.dart';
import '../../../core/utils/file_utils.dart';

/// Video file picker card shown at the top of the extract screen.
class ExtractFileSelectorCard extends StatelessWidget {
  const ExtractFileSelectorCard({
    super.key,
    required this.selectedFilePath,
    required this.selectedFileName,
    required this.fileSize,
    required this.onPickFile,
  });

  final String? selectedFilePath;
  final String? selectedFileName;
  final int? fileSize;
  final VoidCallback onPickFile;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF8B5CF6).withOpacity(0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    Icons.video_library_rounded,
                    size: 20,
                    color: Color(0xFF8B5CF6),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  'Select Video File',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ],
            ),
            const SizedBox(height: 20),
            InkWell(
              onTap: onPickFile,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(40),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: selectedFilePath != null
                        ? const Color(0xFF8B5CF6).withOpacity(0.5)
                        : const Color(0xFF27272A),
                    width: 2,
                  ),
                  borderRadius: BorderRadius.circular(12),
                  color: selectedFilePath != null
                      ? const Color(0xFF8B5CF6).withOpacity(0.05)
                      : const Color(0xFF18181B),
                ),
                child: Column(
                  children: [
                    Icon(
                      selectedFilePath != null
                          ? Icons.video_file_rounded
                          : Icons.upload_file_rounded,
                      size: 56,
                      color: selectedFilePath != null
                          ? const Color(0xFF8B5CF6)
                          : const Color(0xFF71717A),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      selectedFileName ?? 'Click to select video file',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: selectedFilePath != null
                                ? const Color(0xFFFAFAFA)
                                : const Color(0xFFA1A1AA),
                            fontWeight: FontWeight.w600,
                          ),
                      textAlign: TextAlign.center,
                    ),
                    if (fileSize != null) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF27272A),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          'File size: ${FileUtils.formatFileSize(fileSize!)}',
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: const Color(0xFFA1A1AA),
                                  ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
