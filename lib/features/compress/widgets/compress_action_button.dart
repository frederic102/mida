import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/compress_service.dart';

/// Start-compression button, disabled while a task is in flight or the
/// current selection is invalid.
class CompressActionButton extends StatelessWidget {
  const CompressActionButton({
    super.key,
    required this.isValid,
    required this.onPressed,
  });

  final bool isValid;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Consumer<CompressService>(
      builder: (context, service, child) {
        final isCompressing =
            service.currentTask?.status == CompressStatus.analyzing ||
                service.currentTask?.status == CompressStatus.compressing;

        return FilledButton(
          onPressed: isValid && !isCompressing ? onPressed : null,
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
}
