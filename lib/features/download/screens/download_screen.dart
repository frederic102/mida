import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/download_service.dart';
import '../../../core/utils/url_parser.dart';
import '../../../core/utils/file_utils.dart';
import '../widgets/download_url_input_card.dart';
import '../widgets/download_type_selector.dart';
import '../widgets/download_options_card.dart';
import '../widgets/download_action_button.dart';
import '../widgets/download_progress_card.dart';
import '../widgets/download_history_section.dart';

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
                DownloadUrlInputCard(
                  controller: _urlController,
                  onChanged: _onUrlChanged,
                  onPaste: _pasteFromClipboard,
                  onClear: () {
                    _urlController.clear();
                    _onUrlChanged('');
                  },
                  isValidUrl: _isValidUrl,
                  detectedPlatform: _detectedPlatform,
                ),
                const SizedBox(height: 24),
                DownloadTypeSelectorCard(
                  selectedType: _selectedType,
                  onTypeSelected: (type) =>
                      setState(() => _selectedType = type),
                ),
                const SizedBox(height: 24),
                DownloadOptionsCard(
                  selectedType: _selectedType,
                  selectedVideoQuality: _selectedVideoQuality,
                  selectedVideoFormat: _selectedVideoFormat,
                  selectedSubtitle: _selectedSubtitle,
                  selectedAudioQuality: _selectedAudioQuality,
                  selectedAudioFormat: _selectedAudioFormat,
                  onVideoQualityChanged: (value) =>
                      setState(() => _selectedVideoQuality = value),
                  onVideoFormatChanged: (value) =>
                      setState(() => _selectedVideoFormat = value),
                  onSubtitleChanged: (value) =>
                      setState(() => _selectedSubtitle = value),
                  onAudioQualityChanged: (value) =>
                      setState(() => _selectedAudioQuality = value),
                  onAudioFormatChanged: (value) =>
                      setState(() => _selectedAudioFormat = value),
                ),
                const SizedBox(height: 24),
                DownloadActionButton(
                  isValidUrl: _isValidUrl,
                  onPressed: _startDownload,
                ),
                if (service.currentTask != null) ...[
                  const SizedBox(height: 32),
                  DownloadProgressCard(task: service.currentTask!),
                ],
                if (service.history.isNotEmpty) ...[
                  const SizedBox(height: 32),
                  DownloadHistorySection(
                    history: service.history,
                    onItemSecondaryTap: _showContextMenu,
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  void _showContextMenu(
      BuildContext context, Offset position, DownloadTask task) {
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
