import 'dart:io';
import 'package:flutter/material.dart';
import '../services/extract_service.dart';
import '../../../core/utils/file_utils.dart';
import 'extract_status_chip.dart';

/// Progress card shown while an extract task is active.
class ExtractProgressCard extends StatelessWidget {
  const ExtractProgressCard({super.key, required this.task});

  final ExtractTask task;

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
                if (task.status != ExtractStatus.analyzing)
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
            Text(
              task.status == ExtractStatus.analyzing
                  ? 'Analyzing video...'
                  : '${FileUtils.formatProgress(task.progress)} complete',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: Color(0xFFA1A1AA),
              ),
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
            if (task.status == ExtractStatus.completed &&
                task.outputPath != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF22C55E).withOpacity(0.1),
                  border: Border.all(
                    color: const Color(0xFF22C55E).withOpacity(0.3),
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF22C55E).withOpacity(0.15),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Icon(
                        Icons.audiotrack_rounded,
                        color: Color(0xFF22C55E),
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Extraction Complete',
                            style: TextStyle(
                              color: Color(0xFF22C55E),
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            task.outputPath!
                                .split(Platform.pathSeparator)
                                .last,
                            style: const TextStyle(
                              color: Color(0xFFA1A1AA),
                              fontSize: 12,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
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
