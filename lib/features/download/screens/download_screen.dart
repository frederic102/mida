import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/download_service.dart';
import '../../../core/utils/url_parser.dart';
import '../../../core/utils/file_utils.dart';

class DownloadScreen extends StatefulWidget {
  const DownloadScreen({super.key});

  @override
  State<DownloadScreen> createState() => _DownloadScreenState();
}

class _DownloadScreenState extends State<DownloadScreen> {
  final _urlController = TextEditingController();
  DownloadType _selectedType = DownloadType.video;
  bool _isValidUrl = false;
  PlatformType? _detectedPlatform;

  // Download options
  VideoQuality _selectedVideoQuality = VideoQuality.best;
  VideoFormat _selectedVideoFormat = VideoFormat.mp4;
  AudioQuality _selectedAudioQuality = AudioQuality.best;
  AudioFormat _selectedAudioFormat = AudioFormat.mp3;
  SubtitleOption _selectedSubtitle = SubtitleOption.none;

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  void _onUrlChanged(String value) {
    final isValid = UrlParser.isValidUrl(value);
    final platform = isValid ? UrlParser.detectPlatform(value) : null;

    setState(() {
      _isValidUrl = isValid && platform != PlatformType.unknown;
      _detectedPlatform = platform;
    });
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null) {
      _urlController.text = data!.text!;
      _onUrlChanged(data.text!);
    }
  }

  void _startDownload() {
    if (!_isValidUrl) return;

    final service = context.read<DownloadService>();
    final options = DownloadOptions(
      videoQuality: _selectedVideoQuality,
      videoFormat: _selectedVideoFormat,
      audioQuality: _selectedAudioQuality,
      audioFormat: _selectedAudioFormat,
      subtitleOption: _selectedSubtitle,
    );
    service.download(_urlController.text, _selectedType, options: options);
  }

  String _getProgressText(DownloadTask task) {
    switch (task.status) {
      case DownloadStatus.idle:
        return 'Waiting...';
      case DownloadStatus.fetching:
        return 'Fetching video info...';
      case DownloadStatus.downloading:
        if (task.statusMessage != null) {
          if (task.progress > 0) {
            return '${task.statusMessage} (${FileUtils.formatProgress(task.progress)})';
          }
          return task.statusMessage!;
        }
        if (task.progress == 0) {
          return 'Preparing download...';
        }
        return '${FileUtils.formatProgress(task.progress)} complete';
      case DownloadStatus.completed:
        return 'Download complete!';
      case DownloadStatus.error:
        return 'Error occurred';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Download'),
      ),
      body: Consumer<DownloadService>(
        builder: (context, service, child) {
          return SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildUrlInput(),
                const SizedBox(height: 24),
                _buildTypeSelector(),
                const SizedBox(height: 24),
                _buildOptionsSelector(),
                const SizedBox(height: 24),
                _buildDownloadButton(),
                if (service.currentTask != null) ...[
                  const SizedBox(height: 32),
                  _buildProgressCard(service.currentTask!),
                ],
                if (service.history.isNotEmpty) ...[
                  const SizedBox(height: 32),
                  _buildHistorySection(service.history),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildUrlInput() {
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
                    controller: _urlController,
                    onChanged: _onUrlChanged,
                    decoration: InputDecoration(
                      hintText: 'YouTube, Twitter, Instagram, TikTok URL',
                      prefixIcon: const Icon(Icons.link),
                      suffixIcon: _urlController.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: () {
                                _urlController.clear();
                                _onUrlChanged('');
                              },
                            )
                          : null,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: _pasteFromClipboard,
                  icon: const Icon(Icons.paste),
                  label: const Text('Paste'),
                ),
              ],
            ),
            if (_detectedPlatform != null && _isValidUrl) ...[
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
                      UrlParser.getPlatformIcon(_detectedPlatform!),
                      style: const TextStyle(fontSize: 18),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      UrlParser.getPlatformName(_detectedPlatform!),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onPrimaryContainer,
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

  Widget _buildTypeSelector() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Download Type',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _buildTypeOption(
                    type: DownloadType.video,
                    icon: Icons.videocam,
                    label: 'Video (MP4)',
                    subtitle: 'Video with audio',
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _buildTypeOption(
                    type: DownloadType.audio,
                    icon: Icons.audiotrack,
                    label: 'Audio (MP3)',
                    subtitle: 'Audio only',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTypeOption({
    required DownloadType type,
    required IconData icon,
    required String label,
    required String subtitle,
  }) {
    final isSelected = _selectedType == type;

    return InkWell(
      onTap: () => setState(() => _selectedType = type),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          border: Border.all(
            color: isSelected
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.outline.withOpacity(0.3),
            width: isSelected ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(12),
          color: isSelected
              ? Theme.of(context).colorScheme.primaryContainer.withOpacity(0.3)
              : null,
        ),
        child: Column(
          children: [
            Icon(
              icon,
              size: 32,
              color: isSelected
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 8),
            Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: isSelected
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOptionsSelector() {
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
            if (_selectedType == DownloadType.video) ...[
              _buildDropdownRow(
                label: 'Video Quality',
                icon: Icons.high_quality,
                child: DropdownButton<VideoQuality>(
                  value: _selectedVideoQuality,
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
                      setState(() => _selectedVideoQuality = value);
                    }
                  },
                ),
              ),
              const SizedBox(height: 12),
              _buildDropdownRow(
                label: 'Video Format',
                icon: Icons.video_file,
                child: DropdownButton<VideoFormat>(
                  value: _selectedVideoFormat,
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
                      setState(() => _selectedVideoFormat = value);
                    }
                  },
                ),
              ),
              const SizedBox(height: 12),
              _buildDropdownRow(
                label: 'Subtitle',
                icon: Icons.subtitles,
                child: DropdownButton<SubtitleOption>(
                  value: _selectedSubtitle,
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
                      setState(() => _selectedSubtitle = value);
                    }
                  },
                ),
              ),
            ] else ...[
              _buildDropdownRow(
                label: 'Audio Quality',
                icon: Icons.graphic_eq,
                child: DropdownButton<AudioQuality>(
                  value: _selectedAudioQuality,
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
                      setState(() => _selectedAudioQuality = value);
                    }
                  },
                ),
              ),
              const SizedBox(height: 12),
              _buildDropdownRow(
                label: 'Audio Format',
                icon: Icons.audio_file,
                child: DropdownButton<AudioFormat>(
                  value: _selectedAudioFormat,
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
                      setState(() => _selectedAudioFormat = value);
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

  Widget _buildDropdownRow({
    required String label,
    required IconData icon,
    required Widget child,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(0.3),
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

  Widget _buildDownloadButton() {
    return Consumer<DownloadService>(
      builder: (context, service, child) {
        final isDownloading = service.currentTask?.status ==
                DownloadStatus.downloading ||
            service.currentTask?.status == DownloadStatus.fetching;

        return FilledButton.icon(
          onPressed: _isValidUrl && !isDownloading ? _startDownload : null,
          icon: isDownloading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.download),
          label: Text(isDownloading ? 'Downloading...' : 'Start Download'),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 20),
          ),
        );
      },
    );
  }

  Widget _buildProgressCard(DownloadTask task) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  UrlParser.getPlatformIcon(task.platform),
                  style: const TextStyle(fontSize: 24),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        task.title,
                        style: Theme.of(context).textTheme.titleMedium,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (task.duration != null)
                        Text(
                          task.duration!,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                    ],
                  ),
                ),
                _buildStatusChip(task.status),
              ],
            ),
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: task.status == DownloadStatus.fetching
                    ? null
                    : task.progress,
                minHeight: 8,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _getProgressText(task),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (task.error != null) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  task.error!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onErrorContainer,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStatusChip(DownloadStatus status) {
    Color color;
    String label;
    IconData icon;

    switch (status) {
      case DownloadStatus.idle:
        color = Colors.grey;
        label = 'Idle';
        icon = Icons.hourglass_empty;
        break;
      case DownloadStatus.fetching:
        color = Colors.blue;
        label = 'Analyzing';
        icon = Icons.search;
        break;
      case DownloadStatus.downloading:
        color = Colors.orange;
        label = 'Downloading';
        icon = Icons.downloading;
        break;
      case DownloadStatus.completed:
        color = Colors.green;
        label = 'Done';
        icon = Icons.check_circle;
        break;
      case DownloadStatus.error:
        color = Colors.red;
        label = 'Error';
        icon = Icons.error;
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHistorySection(List<DownloadTask> history) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Download History',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 12),
        ListView.separated(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: history.length > 5 ? 5 : history.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final task = history[index];
            return Card(
              child: GestureDetector(
                onSecondaryTapUp: (details) {
                  _showContextMenu(context, details.globalPosition, task);
                },
                child: ListTile(
                  leading: CircleAvatar(
                    child: Text(UrlParser.getPlatformIcon(task.platform)),
                  ),
                  title: Text(
                    task.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    task.type == DownloadType.video
                        ? '${task.options.videoFormat.label} - ${task.options.videoQuality.label}'
                        : '${task.options.audioFormat.label} - ${task.options.audioQuality.label}',
                  ),
                  trailing: _buildStatusChip(task.status),
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  void _showContextMenu(BuildContext context, Offset position, DownloadTask task) {
    showMenu(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: [
        PopupMenuItem(
          child: const Row(
            children: [
              Icon(Icons.folder_open, size: 20),
              SizedBox(width: 8),
              Text('Open Folder'),
            ],
          ),
          onTap: () {
            if (task.outputPath != null) {
              FileUtils.openFileLocation(task.outputPath!);
            }
          },
        ),
      ],
    );
  }
}
