import 'package:flutter/material.dart';
import '../../../core/utils/file_utils.dart';

/// Target-size preset/custom selector card, plus the compression ratio
/// preview shown once a file and a valid target size are known.
class CompressSizeSelectorCard extends StatelessWidget {
  const CompressSizeSelectorCard({
    super.key,
    required this.presets,
    required this.selectedPreset,
    required this.isCustomSize,
    required this.customSizeController,
    required this.originalSize,
    required this.targetSizeBytes,
    required this.onPresetSelected,
    required this.onCustomToggle,
  });

  final List<int> presets;
  final int selectedPreset;
  final bool isCustomSize;
  final TextEditingController customSizeController;
  final int? originalSize;
  final int targetSizeBytes;
  final ValueChanged<int> onPresetSelected;
  final VoidCallback onCustomToggle;

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
                    Icons.tune_rounded,
                    size: 20,
                    color: Color(0xFF8B5CF6),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  'Target Size',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ],
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                ...presets.map((size) => _PresetChip(
                      sizeMB: size,
                      isSelected: !isCustomSize && selectedPreset == size,
                      onTap: () => onPresetSelected(size),
                    )),
                _CustomChip(
                  isSelected: isCustomSize,
                  onTap: onCustomToggle,
                ),
              ],
            ),
            if (isCustomSize) ...[
              const SizedBox(height: 20),
              TextField(
                controller: customSizeController,
                keyboardType: TextInputType.text,
                decoration: const InputDecoration(
                  hintText: 'e.g. 200MB, 1.5GB',
                  prefixIcon: Icon(Icons.edit_rounded),
                ),
              ),
            ],
            if (originalSize != null && targetSizeBytes > 0) ...[
              const SizedBox(height: 20),
              _CompressionInfo(
                originalSize: originalSize!,
                targetSizeBytes: targetSizeBytes,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PresetChip extends StatelessWidget {
  const _PresetChip({
    required this.sizeMB,
    required this.isSelected,
    required this.onTap,
  });

  final int sizeMB;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final label = sizeMB >= 1000
        ? '${(sizeMB / 1000).toStringAsFixed(1)}GB'
        : '${sizeMB}MB';

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected
              ? const Color(0xFF8B5CF6).withOpacity(0.2)
              : const Color(0xFF18181B),
          border: Border.all(
            color:
                isSelected ? const Color(0xFF8B5CF6) : const Color(0xFF27272A),
            width: 1.5,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          'Under $label',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: isSelected
                ? const Color(0xFF8B5CF6)
                : const Color(0xFFA1A1AA),
          ),
        ),
      ),
    );
  }
}

class _CustomChip extends StatelessWidget {
  const _CustomChip({
    required this.isSelected,
    required this.onTap,
  });

  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected
              ? const Color(0xFF8B5CF6).withOpacity(0.2)
              : const Color(0xFF18181B),
          border: Border.all(
            color:
                isSelected ? const Color(0xFF8B5CF6) : const Color(0xFF27272A),
            width: 1.5,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          'Custom',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: isSelected
                ? const Color(0xFF8B5CF6)
                : const Color(0xFFA1A1AA),
          ),
        ),
      ),
    );
  }
}

class _CompressionInfo extends StatelessWidget {
  const _CompressionInfo({
    required this.originalSize,
    required this.targetSizeBytes,
  });

  final int originalSize;
  final int targetSizeBytes;

  @override
  Widget build(BuildContext context) {
    final ratio = (targetSizeBytes / originalSize * 100).clamp(0, 100);
    final isValid = targetSizeBytes < originalSize;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isValid
            ? const Color(0xFF8B5CF6).withOpacity(0.1)
            : const Color(0xFFEF4444).withOpacity(0.1),
        border: Border.all(
          color: isValid
              ? const Color(0xFF8B5CF6).withOpacity(0.3)
              : const Color(0xFFEF4444).withOpacity(0.3),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: isValid
                  ? const Color(0xFF8B5CF6).withOpacity(0.15)
                  : const Color(0xFFEF4444).withOpacity(0.15),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(
              isValid ? Icons.check_circle_rounded : Icons.warning_rounded,
              color:
                  isValid ? const Color(0xFF8B5CF6) : const Color(0xFFEF4444),
              size: 20,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isValid
                      ? '${FileUtils.formatFileSize(originalSize)} → ${FileUtils.formatFileSize(targetSizeBytes)}'
                      : 'Target size is larger than original',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    color: isValid
                        ? const Color(0xFFFAFAFA)
                        : const Color(0xFFEF4444),
                  ),
                ),
                if (isValid) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Compress to ~${ratio.toStringAsFixed(0)}%',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFFA1A1AA),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
