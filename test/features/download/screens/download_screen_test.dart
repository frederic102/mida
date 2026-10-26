import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mida/features/settings/settings_service.dart';
import 'package:mida/core/utils/file_utils.dart';
import 'package:mida/features/download/screens/download_screen.dart';
import 'package:mida/features/download/services/download_queue_service.dart';
import 'package:mida/features/download/services/download_service.dart';
import 'package:provider/provider.dart';

import '../queue/fake_download_service.dart';

void main() {
  late SettingsService settings;
  late FakeDownloadService downloads;
  late DownloadQueueService queue;
  String? clipboard;

  setUp(() {
    settings = SettingsService();
    settings.downloadSettings.downloadPath = r'C:\Out';
    downloads = FakeDownloadService(settings);
    queue = DownloadQueueService(downloads: downloads, settings: settings);
    clipboard = null;
    FileUtils.folderOpenerOverride = (_) async {};
  });

  tearDown(() => FileUtils.folderOpenerOverride = null);

  Future<void> pumpScreen(WidgetTester tester, {ThemeData? theme}) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') return clipboard == null ? null : {'text': clipboard};
      if (call.method == 'Clipboard.setData') {
        clipboard = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settings),
        ChangeNotifierProvider<DownloadService>.value(value: downloads),
        ChangeNotifierProvider.value(value: queue),
      ],
      child: MaterialApp(theme: theme ?? ThemeData.dark(useMaterial3: true), home: const DownloadScreen()),
    ));
    await tester.pump(); // post-frame clipboard check
    await tester.pump();
  }

  Future<void> windowRefocused(WidgetTester tester) async {
    // Same channel the desktop embedder uses for window focus changes.
    for (final state in [AppLifecycleState.inactive, AppLifecycleState.resumed]) {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        SystemChannels.lifecycle.name,
        SystemChannels.lifecycle.codec.encodeMessage(state.toString()),
        (_) {},
      );
    }
    await tester.pump();
    await tester.pump();
  }

  final field = find.byKey(const ValueKey('url-field'));
  final chip = find.byKey(const ValueKey('clipboard-suggestion'));

  String fieldText(WidgetTester tester) => tester.widget<TextField>(field).controller!.text;

  testWidgets('clipboard chip offers an https link and inserts it without starting', (tester) async {
    clipboard = 'https://www.youtube.com/watch?v=abc';
    await pumpScreen(tester);
    expect(find.text('Paste youtube.com'), findsOneWidget);

    await tester.tap(chip);
    await tester.pump();
    expect(fieldText(tester), 'https://www.youtube.com/watch?v=abc');
    expect(downloads.calls, isEmpty);
    expect(queue.items, isEmpty);
    expect(chip, findsNothing); // now in the field, so no longer offered
  });

  testWidgets('clipboard chip stays hidden for non-http text and for links already queued', (tester) async {
    clipboard = 'ftp://files.example/movie.mp4';
    await pumpScreen(tester);
    expect(chip, findsNothing);

    queue.enqueueAll(['https://a.example/1'], type: DownloadType.video, options: const DownloadOptions());
    clipboard = 'https://a.example/1';
    await windowRefocused(tester);
    expect(chip, findsNothing);

    clipboard = 'https://b.example/2';
    await windowRefocused(tester);
    expect(find.text('Paste b.example'), findsOneWidget);
  });

  testWidgets('Enter queues every link in the field and clears it; Shift+Enter does not', (tester) async {
    await pumpScreen(tester);
    await tester.enterText(field, 'https://a.example/1\nhttps://b.example/2');
    await tester.pump();
    expect(find.text('Download 2 links'), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(queue.items, isEmpty);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect([for (final i in queue.items) i.url], ['https://a.example/1', 'https://b.example/2']);
    expect(downloads.calls, ['https://a.example/1']);
    expect(fieldText(tester), isEmpty);
  });

  testWidgets('Esc clears the field', (tester) async {
    await pumpScreen(tester);
    await tester.enterText(field, 'https://a.example/1');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(fieldText(tester), isEmpty);
    expect(queue.items, isEmpty);
  });

  testWidgets('LOGIN_REQUIRED failure turns on browser login and retries from its button', (tester) async {
    await pumpScreen(tester);
    await tester.enterText(field, 'https://a.example/1');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    downloads.last.fail('Could not fetch this video (status: LOGIN_REQUIRED). Check the URL and try again later.');
    await tester.pump();
    await tester.pump();

    expect(find.text('This video is only available to signed-in viewers.'), findsOneWidget);
    expect(settings.useBrowserLoginSession, isFalse);
    await tester.tap(find.text('Use browser login and retry'));
    await tester.pump();
    await tester.pump();
    expect(settings.useBrowserLoginSession, isTrue);
    expect(downloads.calls, ['https://a.example/1', 'https://a.example/1']);
  });

  for (final brightness in Brightness.values) {
    testWidgets('done and failed rows render in ${brightness.name} theme, copy CLI works', (tester) async {
      await pumpScreen(tester, theme: ThemeData(useMaterial3: true, brightness: brightness));
      queue.enqueueAll(['https://a.example/1', 'https://b.example/2'],
          type: DownloadType.video, options: const DownloadOptions());
      await tester.pump();
      downloads.last.startDownloading(title: 'First clip', progress: 0.4);
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      downloads.last.succeed(r'C:\Out\First clip.mp4');
      await tester.pump();
      await tester.pump();
      downloads.last.fail('This video is protected by DRM (Widevine, PlayReady, or FairPlay).');
      await tester.pump();
      await tester.pump();

      expect(find.text('First clip'), findsOneWidget);
      expect(find.text('1 of 2 done · 1 failed'), findsOneWidget);
      expect(find.text('This video is DRM-protected, so MiDa cannot save it.'), findsOneWidget);

      await tester.tap(find.byTooltip('Copy command (PowerShell or bash)'));
      await tester.pump();
      expect(clipboard, r"mida-cli download 'https://a.example/1' --out 'C:\Out'");
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Clear finished'));
      await tester.pump();
      expect(queue.items, isEmpty);
    });
  }
}
