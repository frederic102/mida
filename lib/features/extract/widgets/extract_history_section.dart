import 'dart:io';
import 'package:flutter/material.dart';
import '../services/extract_service.dart';
import '../../../core/utils/file_utils.dart';
import 'extract_status_chip.dart';

/// Recent extraction history list (max 5 rows).
class ExtractHistorySection extends StatelessWidget {
  const ExtractHistorySection({super.key, required this.history});

  final List<ExtractTask> history;

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
              'Extraction History',
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
                        Icons.audiotrack_rounded,
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
                            task.outputPath
                                    ?.split(Platform.pathSeparator)
                                    .last ??
                                task.inputPath
                                    .split(Platform.pathSeparator)
                                    .last,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFFFAFAFA),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (task.duration != null) ...[
                            const SizedBox(height: 4),
                            Text(
                              'Duration: ${FileUtils.formatDuration(task.duration!)}',
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
                    ExtractStatusChip(status: task.status),
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
