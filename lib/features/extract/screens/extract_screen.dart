import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import '../services/extract_service.dart';
import '../../../core/services/platform_service.dart';
import '../widgets/extract_file_selector_card.dart';
import '../widgets/extract_info_card.dart';
import '../widgets/extract_action_button.dart';
import '../widgets/extract_progress_card.dart';
import '../widgets/extract_history_section.dart';

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
                ExtractFileSelectorCard(
                  selectedFilePath: _selectedFilePath,
                  selectedFileName: _selectedFileName,
                  fileSize: _fileSize,
                  onPickFile: _pickFile,
                ),
                const SizedBox(height: 24),
                const ExtractInfoCard(),
                const SizedBox(height: 24),
                ExtractActionButton(
                  hasSelectedFile: _selectedFilePath != null,
                  onPressed: _startExtract,
                ),
                if (service.currentTask != null) ...[
                  const SizedBox(height: 32),
                  ExtractProgressCard(task: service.currentTask!),
                ],
                if (service.history.isNotEmpty) ...[
                  const SizedBox(height: 32),
                  ExtractHistorySection(history: service.history),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}
