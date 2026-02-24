import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import 'package:desktop_drop/desktop_drop.dart';
import '../services/compress_service.dart';
import '../../../core/utils/file_utils.dart';
import '../../../core/services/platform_service.dart';

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

  Future<void> _openOutputFolder(String filePath) async {
    if (Platform.isWindows) {
      await Process.run('explorer', ['/select,', filePath.replaceAll('/', '\\')]);
    } else if (Platform.isMacOS) {
      await Process.run('open', ['-R', filePath]);
    }
  }

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
                _buildFileSelector(),
                const SizedBox(height: 24),
                _buildSizeSelector(),
                const SizedBox(height: 24),
                _buildCompressButton(),
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

  Widget _buildFileSelector() {
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
                    Icons.video_library_rounded,
                    size: 20,
                    color: Color(0xFF8B5CF6),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  'Select Video File',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ],
            ),
            const SizedBox(height: 20),
            DropTarget(
              onDragEntered: (_) => setState(() => _isDragging = true),
              onDragExited: (_) => setState(() => _isDragging = false),
              onDragDone: (details) async {
                setState(() => _isDragging = false);
                if (details.files.isNotEmpty) {
                  final file = details.files.first;
                  final path = file.path;
                  final ext = path.split('.').last.toLowerCase();
                  final videoExts = ['mp4', 'mkv', 'avi', 'mov', 'wmv', 'flv', 'webm', 'ts', 'm4v'];
                  if (videoExts.contains(ext)) {
                    await _setFile(path, path.split(Platform.pathSeparator).last);
                  } else {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Please drop a video file.')),
                      );
                    }
                  }
                }
              },
              child: InkWell(
                onTap: _pickFile,
                borderRadius: BorderRadius.circular(12),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: double.infinity,
                  padding: const EdgeInsets.all(40),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: _isDragging
                          ? const Color(0xFF8B5CF6)
                          : _selectedFilePath != null
                              ? const Color(0xFF8B5CF6).withOpacity(0.5)
                              : const Color(0xFF27272A),
                      width: _isDragging ? 2.5 : 2,
                    ),
                    borderRadius: BorderRadius.circular(12),
                    color: _isDragging
                        ? const Color(0xFF8B5CF6).withOpacity(0.1)
                        : _selectedFilePath != null
                            ? const Color(0xFF8B5CF6).withOpacity(0.05)
                            : const Color(0xFF18181B),
                  ),
                  child: Column(
                    children: [
                      Icon(
                        _isDragging
                            ? Icons.file_download_rounded
                            : _selectedFilePath != null
                                ? Icons.video_file_rounded
                                : Icons.upload_file_rounded,
                        size: 56,
                        color: _isDragging || _selectedFilePath != null
                            ? const Color(0xFF8B5CF6)
                            : const Color(0xFF71717A),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _isDragging
                            ? 'Drop video file here'
                            : _selectedFileName ?? 'Click or drag & drop video file',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              color: _isDragging || _selectedFilePath != null
                                  ? const Color(0xFFFAFAFA)
                                  : const Color(0xFFA1A1AA),
                              fontWeight: FontWeight.w600,
                            ),
                        textAlign: TextAlign.center,
                      ),
                      if (_originalSize != null && !_isDragging) ...[
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF27272A),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            'Original size: ${FileUtils.formatFileSize(_originalSize!)}',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: const Color(0xFFA1A1AA),
                                ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSizeSelector() {
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
                ..._presets.map((size) => _buildPresetChip(size)),
                _buildCustomChip(),
              ],
            ),
            if (_isCustomSize) ...[
              const SizedBox(height: 20),
              TextField(
                controller: _customSizeController,
                keyboardType: TextInputType.text,
                decoration: const InputDecoration(
                  hintText: 'e.g. 200MB, 1.5GB',
                  prefixIcon: Icon(Icons.edit_rounded),
                ),
              ),
            ],
            if (_originalSize != null && _targetSizeBytes > 0) ...[
              const SizedBox(height: 20),
              _buildCompressionInfo(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildPresetChip(int sizeMB) {
    final isSelected = !_isCustomSize && _selectedPreset == sizeMB;
    final label = sizeMB >= 1000
        ? '${(sizeMB / 1000).toStringAsFixed(1)}GB'
        : '${sizeMB}MB';

    return InkWell(
      onTap: () {
        setState(() {
          _isCustomSize = false;
          _selectedPreset = sizeMB;
        });
      },
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected
              ? const Color(0xFF8B5CF6).withOpacity(0.2)
              : const Color(0xFF18181B),
          border: Border.all(
            color: isSelected
                ? const Color(0xFF8B5CF6)
                : const Color(0xFF27272A),
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

  Widget _buildCustomChip() {
    return InkWell(
      onTap: () {
        setState(() {
          _isCustomSize = !_isCustomSize;
        });
      },
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: _isCustomSize
              ? const Color(0xFF8B5CF6).withOpacity(0.2)
              : const Color(0xFF18181B),
          border: Border.all(
            color: _isCustomSize
                ? const Color(0xFF8B5CF6)
                : const Color(0xFF27272A),
            width: 1.5,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          'Custom',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: _isCustomSize
                ? const Color(0xFF8B5CF6)
                : const Color(0xFFA1A1AA),
          ),
        ),
      ),
    );
  }

  Widget _buildCompressionInfo() {
    final ratio = (_targetSizeBytes / _originalSize! * 100).clamp(0, 100);
    final isValid = _targetSizeBytes < _originalSize!;

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
              color: isValid
                  ? const Color(0xFF8B5CF6)
                  : const Color(0xFFEF4444),
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
                      ? '${FileUtils.formatFileSize(_originalSize!)} → ${FileUtils.formatFileSize(_targetSizeBytes)}'
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

  Widget _buildCompressButton() {
    return Consumer<CompressService>(
      builder: (context, service, child) {
        final isCompressing =
            service.currentTask?.status == CompressStatus.analyzing ||
                service.currentTask?.status == CompressStatus.compressing;

        final isValid = _selectedFilePath != null &&
            _targetSizeBytes > 0 &&
            (_originalSize == null || _targetSizeBytes < _originalSize!);

        return FilledButton(
          onPressed: isValid && !isCompressing ? _startCompress : null,
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 18),
            backgroundColor: const Color(0xFF8B5CF6),
            disabledBackgroundColor: const Color(0xFF27272A),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (isCompressing)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: Colors.white,
                  ),
                )
              else
                const Icon(Icons.compress_rounded, size: 20),
              const SizedBox(width: 10),
              Text(
                isCompressing ? 'Compressing...' : 'Start Compression',
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildProgressCard(CompressTask task) {
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
                _buildStatusChip(task.status),
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
                      if (task.status == CompressStatus.completed && task.outputPath != null) ...[
                        const SizedBox(width: 8),
                        InkWell(
                          onTap: () => _openOutputFolder(task.outputPath!),
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
                                color: const Color(0xFF8B5CF6).withOpacity(0.3),
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

  Widget _buildStatusChip(CompressStatus status) {
    Color color;
    String label;
    IconData icon;

    switch (status) {
      case CompressStatus.idle:
        color = const Color(0xFF71717A);
        label = 'Idle';
        icon = Icons.schedule_rounded;
        break;
      case CompressStatus.analyzing:
        color = const Color(0xFF3B82F6);
        label = 'Analyzing';
        icon = Icons.search_rounded;
        break;
      case CompressStatus.compressing:
        color = const Color(0xFFF59E0B);
        label = 'Compressing';
        icon = Icons.compress_rounded;
        break;
      case CompressStatus.completed:
        color = const Color(0xFF22C55E);
        label = 'Done';
        icon = Icons.check_circle_rounded;
        break;
      case CompressStatus.error:
        color = const Color(0xFFEF4444);
        label = 'Error';
        icon = Icons.error_rounded;
        break;
      case CompressStatus.unsupported:
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

  Widget _buildHistorySection(List<CompressTask> history) {
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
                    _buildStatusChip(task.status),
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
