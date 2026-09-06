import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/extract_service.dart';

/// Start-extraction button, disabled while a task is in flight or no file
/// is selected.
class ExtractActionButton extends StatelessWidget {
  const ExtractActionButton({
    super.key,
    required this.hasSelectedFile,
    required this.onPressed,
  });

  final bool hasSelectedFile;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Consumer<ExtractService>(
      builder: (context, service, child) {
        final isExtracting =
            service.currentTask?.status == ExtractStatus.analyzing ||
                service.currentTask?.status == ExtractStatus.extracting;

        return FilledButton(
          onPressed: hasSelectedFile && !isExtracting ? onPressed : null,
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
}
