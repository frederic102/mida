import 'package:flutter/material.dart';
import '../services/extract_service.dart';

/// Status pill shown on the current extract task and history rows.
class ExtractStatusChip extends StatelessWidget {
  const ExtractStatusChip({super.key, required this.status});

  final ExtractStatus status;

  @override
  Widget build(BuildContext context) {
    Color color;
    String label;
    IconData icon;

    switch (status) {
      case ExtractStatus.idle:
        color = const Color(0xFF71717A);
        label = 'Idle';
        icon = Icons.schedule_rounded;
        break;
      case ExtractStatus.analyzing:
        color = const Color(0xFF3B82F6);
        label = 'Analyzing';
        icon = Icons.search_rounded;
        break;
      case ExtractStatus.extracting:
        color = const Color(0xFFF59E0B);
        label = 'Extracting';
        icon = Icons.audiotrack_rounded;
        break;
      case ExtractStatus.completed:
        color = const Color(0xFF22C55E);
        label = 'Done';
        icon = Icons.check_circle_rounded;
        break;
      case ExtractStatus.error:
        color = const Color(0xFFEF4444);
        label = 'Error';
        icon = Icons.error_rounded;
        break;
      case ExtractStatus.unsupported:
        color = const Color(0xFF71717A);
        label = 'Unsupported';
        icon = Icons.block_rounded;
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: color.withOpacity(0.3),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
