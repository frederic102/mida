import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'app.dart';
import 'core/utils/mida_log.dart';
import 'features/settings/settings_service.dart';
import 'features/download/services/download_service.dart';
import 'features/compress/services/compress_service.dart';
import 'features/extract/services/extract_service.dart';
import 'features/subscriptions/services/subscription_paths.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final settingsService = SettingsService();
  await settingsService.init();

  final downloadService = DownloadService(settingsService);

  SubscriptionPaths subscriptionPaths;
  try {
    subscriptionPaths = await SubscriptionPaths.appSupport();
  } catch (e) {
    // No per-user data folder: keep the app usable, subscriptions then live in temp.
    midaLog('No application support folder: $e');
    subscriptionPaths = SubscriptionPaths.temporaryFallback();
  }

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settingsService),
        ChangeNotifierProvider.value(value: downloadService),
        ChangeNotifierProvider(
          create: (_) => CompressService(settingsService),
        ),
        ChangeNotifierProvider(
          create: (_) => ExtractService(settingsService),
        ),
      ],
      child: MiDaApp(subscriptionPaths: subscriptionPaths),
    ),
  );
}
