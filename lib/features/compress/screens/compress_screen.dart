import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import '../services/compress_service.dart';
import '../../../core/utils/file_utils.dart';
import '../../../core/services/platform_service.dart';
import '../widgets/compress_file_selector_card.dart';
import '../widgets/compress_size_selector_card.dart';
import '../widgets/compress_action_button.dart';
import '../widgets/compress_progress_card.dart';
import '../widgets/compress_history_section.dart';

class CompressScreen extends StatefulWidget {
  const CompressScreen({super.key});

  @override
  State<CompressScreen> createState() => _CompressScreenState();
}

class _CompressScreenState extends State<CompressScreen> {
  String? _selectedFilePath;
  String? _selectedFileName;
  int? _originalSize;
  int _selectedPreset = 500; // MB
  bool _isCustomSize = false;
  bool _isDragging = false;
  final _customSizeController = TextEditingController();

  final List<int> _presets = [1000, 500, 300, 100, 50];

  @override
  void dispose() {
    _customSizeController.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.video,
      allowMultiple: false,
    );

    if (result != null && result.files.isNotEmpty) {
      final file = result.files.first;
      if (file.path != null) {
        await _setFile(file.path!, file.name);
      }
    }
  }

  Future<void> _setFile(String filePath, String fileName) async {
    final fileSize = await File(filePath).length();
    setState(() {
      _selectedFilePath = filePath;
      _selectedFileName = fileName;
      _originalSize = fileSize;
    });
  }

  Future<void> _openOutputFolder(String filePath) =>
      FileUtils.openFileLocation(filePath);

  int get _targetSizeBytes {
    if (_isCustomSize) {
      return FileUtils.parseTargetSize(_customSizeController.text);
    }
    return _selectedPreset * 1024 * 1024;
  }

  Future<void> _startCompress() async {
    if (_selectedFilePath == null) return;

    final targetSize = _targetSizeBytes;
    if (targetSize <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a valid size.')),
      );
      return;
    }

    final service = context.read<CompressService>();
    await service.compress(_selectedFilePath!, targetSize);

    if (service.currentTask?.status == CompressStatus.completed &&
        service.currentTask?.outputPath != null) {
      _openOutputFolder(service.currentTask!.outputPath!);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Mobile not supported
    if (PlatformService.isMobile) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Compress'),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: const Color(0xFF27272A),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Icon(
                    Icons.desktop_windows_rounded,
                    size: 64,
                    color: Color(0xFF8B5CF6),
                  ),
                ),
                const SizedBox(height: 24),
                const Text(
                  'Desktop Only',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFFFAFAFA),
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Video compression is only available\non Windows/macOS.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: Color(0xFFA1A1AA),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Compress'),
      ),
      body: Consumer<CompressService>(
        builder: (context, service, child) {
          return SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                CompressFileSelectorCard(
                  selectedFilePath: _selectedFilePath,
                  selectedFileName: _selectedFileName,
                  originalSize: _originalSize,
                  isDragging: _isDragging,
                  onDragEntered: (_) => setState(() => _isDragging = true),
                  onDragExited: (_) => setState(() => _isDragging = false),
                  onDragDone: (details) async {
                    setState(() => _isDragging = false);
                    if (details.files.isNotEmpty) {
                      final file = details.files.first;
                      final path = file.path;
                      final ext = path.split('.').last.toLowerCase();
                      final videoExts = [
                        'mp4',
                        'mkv',
                        'avi',
                        'mov',
                        'wmv',
                        'flv',
                        'webm',
                        'ts',
                        'm4v'
                      ];
                      if (videoExts.contains(ext)) {
                        await _setFile(
                            path, path.split(Platform.pathSeparator).last);
                      } else {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text('Please drop a video file.')),
                          );
                        }
                      }
                    }
                  },
                  onTap: _pickFile,
                ),
                const SizedBox(height: 24),
                CompressSizeSelectorCard(
                  presets: _presets,
                  selectedPreset: _selectedPreset,
                  isCustomSize: _isCustomSize,
                  customSizeController: _customSizeController,
                  originalSize: _originalSize,
                  targetSizeBytes: _targetSizeBytes,
                  onPresetSelected: (size) {
                    setState(() {
                      _isCustomSize = false;
                      _selectedPreset = size;
                    });
                  },
                  onCustomToggle: () {
                    setState(() {
                      _isCustomSize = !_isCustomSize;
                    });
                  },
                ),
                const SizedBox(height: 24),
                CompressActionButton(
                  isValid: _selectedFilePath != null &&
                      _targetSizeBytes > 0 &&
                      (_originalSize == null ||
                          _targetSizeBytes < _originalSize!),
                  onPressed: _startCompress,
                ),
                if (service.currentTask != null) ...[
                  const SizedBox(height: 32),
                  CompressProgressCard(
                    task: service.currentTask!,
                    onOpenFolder: _openOutputFolder,
                  ),
                ],
                if (service.history.isNotEmpty) ...[
                  const SizedBox(height: 32),
                  CompressHistorySection(history: service.history),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}
