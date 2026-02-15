import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'app.dart';
import 'core/services/settings_service.dart';
import 'features/download/services/download_service.dart';
import 'features/compress/services/compress_service.dart';
import 'features/extract/services/extract_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final settingsService = SettingsService();
  await settingsService.init();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settingsService),
        ChangeNotifierProvider(
          create: (_) => DownloadService(settingsService),
        ),
        ChangeNotifierProvider(
          create: (_) => CompressService(settingsService),
        ),
        ChangeNotifierProvider(
          create: (_) => ExtractService(settingsService),
        ),
      ],
      child: const MiDaApp(),
    ),
  );
}
