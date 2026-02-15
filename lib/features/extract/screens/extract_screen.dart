import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import '../services/extract_service.dart';
import '../../../core/utils/file_utils.dart';
import '../../../core/services/platform_service.dart';

class ExtractScreen extends StatefulWidget {
  const ExtractScreen({super.key});

  @override
  State<ExtractScreen> createState() => _ExtractScreenState();
}

class _ExtractScreenState extends State<ExtractScreen> {
  String? _selectedFilePath;
  String? _selectedFileName;
  int? _fileSize;

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.video,
      allowMultiple: false,
    );

    if (result != null && result.files.isNotEmpty) {
      final file = result.files.first;
      final filePath = file.path;

      if (filePath != null) {
        final fileSize = await File(filePath).length();
        setState(() {
          _selectedFilePath = filePath;
          _selectedFileName = file.name;
          _fileSize = fileSize;
        });
      }
    }
  }

  void _startExtract() {
    if (_selectedFilePath == null) return;

    final service = context.read<ExtractService>();
    service.extract(_selectedFilePath!);
  }

  @override
  Widget build(BuildContext context) {
    // Mobile not supported
    if (PlatformService.isMobile) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Extract Audio'),
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
                  'Audio extraction is only available\non Windows/macOS.',
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
        title: const Text('Extract Audio'),
      ),
      body: Consumer<ExtractService>(
        builder: (context, service, child) {
          return SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildFileSelector(),
                const SizedBox(height: 24),
                _buildInfoCard(),
                const SizedBox(height: 24),
                _buildExtractButton(),
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
            InkWell(
              onTap: _pickFile,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(40),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: _selectedFilePath != null
                        ? const Color(0xFF8B5CF6).withOpacity(0.5)
                        : const Color(0xFF27272A),
                    width: 2,
                  ),
                  borderRadius: BorderRadius.circular(12),
                  color: _selectedFilePath != null
                      ? const Color(0xFF8B5CF6).withOpacity(0.05)
                      : const Color(0xFF18181B),
                ),
                child: Column(
                  children: [
                    Icon(
                      _selectedFilePath != null
                          ? Icons.video_file_rounded
                          : Icons.upload_file_rounded,
                      size: 56,
                      color: _selectedFilePath != null
                          ? const Color(0xFF8B5CF6)
                          : const Color(0xFF71717A),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _selectedFileName ?? 'Click to select video file',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: _selectedFilePath != null
                                ? const Color(0xFFFAFAFA)
                                : const Color(0xFFA1A1AA),
                            fontWeight: FontWeight.w600,
                          ),
                      textAlign: TextAlign.center,
                    ),
                    if (_fileSize != null) ...[
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
                          'File size: ${FileUtils.formatFileSize(_fileSize!)}',
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
          ],
        ),
      ),
    );
  }

  Widget _buildInfoCard() {
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
                    Icons.settings_rounded,
                    size: 20,
                    color: Color(0xFF8B5CF6),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  'Output Format',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ],
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFF8B5CF6).withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: const Color(0xFF8B5CF6).withOpacity(0.3),
                  width: 1.5,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF8B5CF6).withOpacity(0.2),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.audiotrack_rounded,
                      size: 28,
                      color: Color(0xFF8B5CF6),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'MP3 (320kbps)',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFFFAFAFA),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'High quality MP3 audio extraction',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: const Color(0xFFA1A1AA),
                              ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: const Color(0xFF22C55E).withOpacity(0.15),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Icon(
                      Icons.check_circle_rounded,
                      color: Color(0xFF22C55E),
                      size: 20,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildExtractButton() {
    return Consumer<ExtractService>(
      builder: (context, service, child) {
        final isExtracting =
            service.currentTask?.status == ExtractStatus.analyzing ||
                service.currentTask?.status == ExtractStatus.extracting;

        return FilledButton(
          onPressed:
              _selectedFilePath != null && !isExtracting ? _startExtract : null,
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 18),
            backgroundColor: const Color(0xFF8B5CF6),
            disabledBackgroundColor: const Color(0xFF27272A),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (isExtracting)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: Colors.white,
                  ),
                )
              else
                const Icon(Icons.audiotrack_rounded, size: 20),
              const SizedBox(width: 10),
              Text(
                isExtracting ? 'Extracting...' : 'Start Extraction',
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

  Widget _buildProgressCard(ExtractTask task) {
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
                            task.outputPath!.split(Platform.pathSeparator).last,
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

  Widget _buildStatusChip(ExtractStatus status) {
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

  Widget _buildHistorySection(List<ExtractTask> history) {
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
                            task.outputPath?.split(Platform.pathSeparator).last ??
                                task.inputPath.split(Platform.pathSeparator).last,
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
