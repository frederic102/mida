import 'dart:io';
import 'package:flutter/material.dart';
import '../services/compress_service.dart';
import '../../../core/utils/file_utils.dart';
import 'compress_status_chip.dart';

/// Progress card shown while a compress task is active, including the
/// "Open Folder" shortcut once the output file exists.
class CompressProgressCard extends StatelessWidget {
  const CompressProgressCard({
    super.key,
    required this.task,
    required this.onOpenFolder,
  });

  final CompressTask task;
  final ValueChanged<String> onOpenFolder;

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
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF8B5CF6).withOpacity(0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.video_file_rounded,
                    size: 24,
                    color: Color(0xFF8B5CF6),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        task.inputPath.split(Platform.pathSeparator).last,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFFFAFAFA),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (task.originalSize != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          'Original: ${FileUtils.formatFileSize(task.originalSize!)}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF71717A),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                CompressStatusChip(status: task.status),
              ],
            ),
            const SizedBox(height: 20),
            Stack(
              children: [
                Container(
                  height: 10,
                  decoration: BoxDecoration(
                    color: const Color(0xFF27272A),
                    borderRadius: BorderRadius.circular(5),
                  ),
                ),
                if (task.status != CompressStatus.analyzing)
                  FractionallySizedBox(
                    widthFactor: task.progress,
                    child: Container(
                      height: 10,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFF8B5CF6), Color(0xFFA78BFA)],
                        ),
                        borderRadius: BorderRadius.circular(5),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  task.status == CompressStatus.analyzing
                      ? 'Analyzing video...'
                      : '${FileUtils.formatProgress(task.progress)} complete',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFFA1A1AA),
                  ),
                ),
                if (task.compressedSize != null)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF22C55E).withOpacity(0.15),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          'Result: ${FileUtils.formatFileSize(task.compressedSize!)}',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF22C55E),
                          ),
                        ),
                      ),
                      if (task.status == CompressStatus.completed &&
                          task.outputPath != null) ...[
                        const SizedBox(width: 8),
                        InkWell(
                          onTap: () => onOpenFolder(task.outputPath!),
                          borderRadius: BorderRadius.circular(6),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFF8B5CF6).withOpacity(0.15),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color:
                                    const Color(0xFF8B5CF6).withOpacity(0.3),
                              ),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.folder_open_rounded,
                                  size: 14,
                                  color: Color(0xFF8B5CF6),
                                ),
                                SizedBox(width: 4),
                                Text(
                                  'Open Folder',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF8B5CF6),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
              ],
            ),
            if (task.error != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFEF4444).withOpacity(0.1),
                  border: Border.all(
                    color: const Color(0xFFEF4444).withOpacity(0.3),
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.error_outline_rounded,
                      size: 18,
                      color: Color(0xFFEF4444),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        task.error!,
                        style: const TextStyle(
                          color: Color(0xFFEF4444),
                          fontSize: 12,
                        ),
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
