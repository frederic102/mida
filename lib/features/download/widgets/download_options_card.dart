import 'package:flutter/material.dart';
import '../services/download_service.dart';

/// Quality/format/subtitle dropdown card, contents depend on [selectedType].
class DownloadOptionsCard extends StatelessWidget {
  const DownloadOptionsCard({
    super.key,
    required this.selectedType,
    required this.selectedVideoQuality,
    required this.selectedVideoFormat,
    required this.selectedSubtitle,
    required this.selectedAudioQuality,
    required this.selectedAudioFormat,
    required this.onVideoQualityChanged,
    required this.onVideoFormatChanged,
    required this.onSubtitleChanged,
    required this.onAudioQualityChanged,
    required this.onAudioFormatChanged,
  });

  final DownloadType selectedType;
  final VideoQuality selectedVideoQuality;
  final VideoFormat selectedVideoFormat;
  final SubtitleOption selectedSubtitle;
  final AudioQuality selectedAudioQuality;
  final AudioFormat selectedAudioFormat;
  final ValueChanged<VideoQuality> onVideoQualityChanged;
  final ValueChanged<VideoFormat> onVideoFormatChanged;
  final ValueChanged<SubtitleOption> onSubtitleChanged;
  final ValueChanged<AudioQuality> onAudioQualityChanged;
  final ValueChanged<AudioFormat> onAudioFormatChanged;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Download Options',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            if (selectedType == DownloadType.video) ...[
              _DropdownRow(
                label: 'Video Quality',
                icon: Icons.high_quality,
                child: DropdownButton<VideoQuality>(
                  value: selectedVideoQuality,
                  isExpanded: true,
                  underline: const SizedBox(),
                  items: VideoQuality.values.map((quality) {
                    return DropdownMenuItem(
                      value: quality,
                      child: Text(quality.label),
                    );
                  }).toList(),
                  onChanged: (value) {
                    if (value != null) {
                      onVideoQualityChanged(value);
                    }
                  },
                ),
              ),
              const SizedBox(height: 12),
              _DropdownRow(
                label: 'Video Format',
                icon: Icons.video_file,
                child: DropdownButton<VideoFormat>(
                  value: selectedVideoFormat,
                  isExpanded: true,
                  underline: const SizedBox(),
                  items: VideoFormat.values.map((format) {
                    return DropdownMenuItem(
                      value: format,
                      child: Text(format.label),
                    );
                  }).toList(),
                  onChanged: (value) {
                    if (value != null) {
                      onVideoFormatChanged(value);
                    }
                  },
                ),
              ),
              const SizedBox(height: 12),
              _DropdownRow(
                label: 'Subtitle',
                icon: Icons.subtitles,
                child: DropdownButton<SubtitleOption>(
                  value: selectedSubtitle,
                  isExpanded: true,
                  underline: const SizedBox(),
                  items: SubtitleOption.values.map((option) {
                    return DropdownMenuItem(
                      value: option,
                      child: Text(option.label),
                    );
                  }).toList(),
                  onChanged: (value) {
                    if (value != null) {
                      onSubtitleChanged(value);
                    }
                  },
                ),
              ),
            ] else ...[
              _DropdownRow(
                label: 'Audio Quality',
                icon: Icons.graphic_eq,
                child: DropdownButton<AudioQuality>(
                  value: selectedAudioQuality,
                  isExpanded: true,
                  underline: const SizedBox(),
                  items: AudioQuality.values.map((quality) {
                    return DropdownMenuItem(
                      value: quality,
                      child: Text(quality.label),
                    );
                  }).toList(),
                  onChanged: (value) {
                    if (value != null) {
                      onAudioQualityChanged(value);
                    }
                  },
                ),
              ),
              const SizedBox(height: 12),
              _DropdownRow(
                label: 'Audio Format',
                icon: Icons.audio_file,
                child: DropdownButton<AudioFormat>(
                  value: selectedAudioFormat,
                  isExpanded: true,
                  underline: const SizedBox(),
                  items: AudioFormat.values.map((format) {
                    return DropdownMenuItem(
                      value: format,
                      child: Text(format.label),
                    );
                  }).toList(),
                  onChanged: (value) {
                    if (value != null) {
                      onAudioFormatChanged(value);
                    }
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DropdownRow extends StatelessWidget {
  const _DropdownRow({
    required this.label,
    required this.icon,
    required this.child,
  });

  final String label;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withOpacity(0.3),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Theme.of(context).colorScheme.outline.withOpacity(0.2),
        ),
      ),
      child: Row(
        children: [
          Icon(
            icon,
            size: 20,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 12),
          Text(
            label,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
          ),
          const Spacer(),
          Expanded(
            flex: 2,
            child: child,
          ),
        ],
      ),
    );
  }
}
