import 'dart:io';
import 'package:flutter/material.dart';
import '../services/compress_service.dart';
import '../../../core/utils/file_utils.dart';
import 'compress_status_chip.dart';

/// Recent compression history list (max 5 rows).
class CompressHistorySection extends StatelessWidget {
  const CompressHistorySection({super.key, required this.history});

  final List<CompressTask> history;

  @override
  Widget build(BuildContext context) {
    return Column(
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
                Icons.history_rounded,
                size: 20,
                color: Color(0xFF8B5CF6),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              'Compression History',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ],
        ),
        const SizedBox(height: 16),
        ListView.separated(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: history.length > 5 ? 5 : history.length,
          separatorBuilder: (_, __) => const SizedBox(height: 10),
          itemBuilder: (context, index) {
            final task = history[index];
            return Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF27272A),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(
                        Icons.video_file_rounded,
                        size: 20,
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
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFFFAFAFA),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (task.originalSize != null &&
                              task.compressedSize != null) ...[
                            const SizedBox(height: 4),
                            Text(
                              '${FileUtils.formatFileSize(task.originalSize!)} → ${FileUtils.formatFileSize(task.compressedSize!)}',
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
              ),
            );
          },
        ),
      ],
    );
  }
}
