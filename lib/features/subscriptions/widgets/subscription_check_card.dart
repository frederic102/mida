import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../settings/settings_service.dart';
import '../services/subscription_scheduler.dart';

/// Check interval, "Check now", and what the last check did.
class SubscriptionCheckCard extends StatelessWidget {
  const SubscriptionCheckCard({super.key});

  static const presets = [15, 30, 60, 120, 360, 720, 1440];

  static String intervalLabel(int minutes) {
    if (minutes < 60 || minutes % 60 != 0) return '$minutes minutes';
    final h = minutes ~/ 60;
    return h == 1 ? '1 hour' : '$h hours';
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    final scheduler = context.watch<SubscriptionScheduler>();
    final text = Theme.of(context).textTheme;
    final muted = text.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    final current = settings.subscriptionIntervalMinutes;
    final values = {...presets, current}.toList()..sort();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Checks', style: text.titleMedium),
            const SizedBox(height: 12),
            Wrap(
              spacing: 16,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text('Check every'),
                DropdownButton<int>(
                  key: const ValueKey('sub-interval'),
                  value: current,
                  items: [for (final m in values) DropdownMenuItem(value: m, child: Text(intervalLabel(m)))],
                  onChanged: (m) async {
                    if (m == null) return;
                    await settings.setSubscriptionIntervalMinutes(m);
                    scheduler.restartTimer();
                  },
                ),
                FilledButton.tonalIcon(
                  key: const ValueKey('sub-check-now'),
                  onPressed: scheduler.isRunning ? null : () => scheduler.runCheck(),
                  icon: const Icon(Icons.refresh, size: 18),
                  label: Text(
                    scheduler.isDraining
                        ? 'Downloading new uploads...'
                        : scheduler.isRunning
                            ? 'Checking...'
                            : 'Check now',
                  ),
                ),
              ],
            ),
            if (scheduler.isRunning) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
            ],
            if (scheduler.status != null) ...[
              const SizedBox(height: 8),
              Text(scheduler.status!, key: const ValueKey('sub-status'), style: text.bodyMedium),
            ],
            const SizedBox(height: 8),
            Text(
              'Checks run only while MiDa is open: once at start if the last check is older than '
              'the interval, then every interval. New videos go into the Download queue.',
              style: muted,
            ),
          ],
        ),
      ),
    );
  }
}
