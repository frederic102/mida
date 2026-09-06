import 'package:flutter/material.dart';
import 'package:desktop_drop/desktop_drop.dart';
import '../../../core/utils/file_utils.dart';

/// Video file picker card with drag & drop support, shown at the top of
/// the compress screen.
class CompressFileSelectorCard extends StatelessWidget {
  const CompressFileSelectorCard({
    super.key,
    required this.selectedFilePath,
    required this.selectedFileName,
    required this.originalSize,
    required this.isDragging,
    required this.onDragEntered,
    required this.onDragExited,
    required this.onDragDone,
    required this.onTap,
  });

  final String? selectedFilePath;
  final String? selectedFileName;
  final int? originalSize;
  final bool isDragging;
  final ValueChanged<DropEventDetails> onDragEntered;
  final ValueChanged<DropEventDetails> onDragExited;
  final OnDragDoneCallback onDragDone;
  final VoidCallback onTap;

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
            DropTarget(
              onDragEntered: onDragEntered,
              onDragExited: onDragExited,
              onDragDone: onDragDone,
              child: InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(12),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: double.infinity,
                  padding: const EdgeInsets.all(40),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: isDragging
                          ? const Color(0xFF8B5CF6)
                          : selectedFilePath != null
                              ? const Color(0xFF8B5CF6).withOpacity(0.5)
                              : const Color(0xFF27272A),
                      width: isDragging ? 2.5 : 2,
                    ),
                    borderRadius: BorderRadius.circular(12),
                    color: isDragging
                        ? const Color(0xFF8B5CF6).withOpacity(0.1)
                        : selectedFilePath != null
                            ? const Color(0xFF8B5CF6).withOpacity(0.05)
                            : const Color(0xFF18181B),
                  ),
                  child: Column(
                    children: [
                      Icon(
                        isDragging
                            ? Icons.file_download_rounded
                            : selectedFilePath != null
                                ? Icons.video_file_rounded
                                : Icons.upload_file_rounded,
                        size: 56,
                        color: isDragging || selectedFilePath != null
                            ? const Color(0xFF8B5CF6)
                            : const Color(0xFF71717A),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        isDragging
                            ? 'Drop video file here'
                            : selectedFileName ??
                                'Click or drag & drop video file',
                        style:
                            Theme.of(context).textTheme.titleMedium?.copyWith(
                                  color: isDragging || selectedFilePath != null
                                      ? const Color(0xFFFAFAFA)
                                      : const Color(0xFFA1A1AA),
                                  fontWeight: FontWeight.w600,
                                ),
                        textAlign: TextAlign.center,
                      ),
                      if (originalSize != null && !isDragging) ...[
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
                            'Original size: ${FileUtils.formatFileSize(originalSize!)}',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(
                                  color: const Color(0xFFA1A1AA),
                                ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
