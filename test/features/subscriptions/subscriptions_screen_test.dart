import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/subscriptions/subscription.dart';
import 'package:mida/features/download/services/download_queue_service.dart';
import 'package:mida/features/settings/settings_service.dart';
import 'package:mida/features/subscriptions/screens/subscriptions_screen.dart';
import 'package:mida/features/subscriptions/services/subscription_list.dart';
import 'package:mida/features/subscriptions/services/subscription_paths.dart';
import 'package:mida/features/subscriptions/services/subscription_scheduler.dart';
import 'package:mida/features/subscriptions/widgets/subscription_tile.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../download/queue/fake_download_service.dart';
import 'subscription_test_support.dart';

void main() {
  late Directory dir;
  late SubscriptionPaths paths;
  late SettingsService settings;
  late FakeLister lister;
  late FakeDownloadService downloads;
  late SubscriptionList list;
  late SubscriptionScheduler scheduler;
  late DateTime clock;
  String? picked;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('mida_subs_ui_');
    paths = SubscriptionPaths.inDir(dir);
    clock = DateTime.utc(2026, 11, 22, 12);
    picked = null;
    SharedPreferences.setMockInitialValues({'download_path': r'C:\Out'});
    settings = SettingsService();
    await settings.init();
    lister = FakeLister();
    downloads = FakeDownloadService(settings);
    final queue = DownloadQueueService(downloads: downloads, settings: settings);
    list = SubscriptionList(store: SubscriptionStore(paths.subscriptions), lister: lister, now: () => clock);
    scheduler = SubscriptionScheduler(
      subscriptions: list,
      archiveFile: paths.archive,
      lister: lister,
      queue: queue,
      interval: () => Duration(minutes: settings.subscriptionIntervalMinutes),
      now: () => clock,
      lockWait: const Duration(milliseconds: 50),
    );
  });

  tearDown(() {
    scheduler.dispose();
    list.dispose();
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // a lock file handle may linger for a moment on Windows
    }
  });

  Future<void> pumpScreen(WidgetTester tester, {SubscriptionList? shownList, SubscriptionScheduler? shownScheduler}) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final shown = shownList ?? list;
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settings),
        ChangeNotifierProvider.value(value: shown),
        ChangeNotifierProvider.value(value: shownScheduler ?? scheduler),
      ],
      child: MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: SubscriptionsScreen(pickFolder: () async => picked),
      ),
    ));
    await tester.runAsync(shown.load);
    await tester.pump();
  }

  /// File IO needs real event-loop turns; pump between them.
  Future<void> until(WidgetTester tester, bool Function() condition) async {
    for (var i = 0; i < 300; i++) {
      if (condition()) return;
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    fail('Timed out waiting for the screen to settle');
  }

  Future<List<Subscription>> stored(WidgetTester tester) async =>
      (await tester.runAsync(() => SubscriptionStore(paths.subscriptions).load()))!;

  final urlField = find.byKey(const ValueKey('sub-url-field'));
  final subscribe = find.byKey(const ValueKey('sub-add'));

  Future<void> addChannel(WidgetTester tester, [String link = channelUrl]) async {
    final before = list.items.length;
    await tester.enterText(urlField, link);
    await tester.tap(subscribe);
    await until(tester, () => list.items.length > before);
  }

  testWidgets('adding a channel reads its title and saves it through SubscriptionStore', (tester) async {
    await pumpScreen(tester);
    expect(find.text('No subscriptions yet.'), findsOneWidget);

    await addChannel(tester);

    expect(find.text('The Channel'), findsOneWidget);
    final row = (await stored(tester)).single;
    expect(row.source, channelUrl);
    expect(row.channelId, channelUc);
    expect(row.title, 'The Channel');
    expect(row.createdAt, clock);
    expect(row.outputDir, isNull);
    expect(row.lastChecked, isNull);
    expect(find.text('Not checked yet'), findsOneWidget);
    expect(tester.widget<TextField>(urlField).controller!.text, isEmpty);
  });

  testWidgets('the folder chosen before adding is stored with the channel', (tester) async {
    await pumpScreen(tester);
    picked = r'D:\Videos\Channel';
    await tester.tap(find.byKey(const ValueKey('sub-add-folder')));
    await tester.pump();
    await tester.pump();
    expect(find.text(r'D:\Videos\Channel'), findsOneWidget);

    await addChannel(tester);

    expect((await stored(tester)).single.outputDir, r'D:\Videos\Channel');
  });

  testWidgets('subscriptions survive a restart: a new list over the same file shows them', (tester) async {
    await pumpScreen(tester);
    await addChannel(tester);

    final again = SubscriptionList(store: SubscriptionStore(paths.subscriptions), lister: lister);
    await tester.runAsync(again.load);
    expect(again.items.single.title, 'The Channel');
    again.dispose();
  });

  testWidgets('remove deletes the row from the file', (tester) async {
    await pumpScreen(tester);
    await addChannel(tester);

    await tester.tap(find.byTooltip('Remove subscription'));
    await until(tester, () => list.items.isEmpty);

    expect(await stored(tester), isEmpty);
    expect(find.text('No subscriptions yet.'), findsOneWidget);
  });

  testWidgets('rename keeps the row and changes only the title', (tester) async {
    await pumpScreen(tester);
    await addChannel(tester);

    await tester.tap(find.byTooltip('Rename'));
    await tester.pump();
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('sub-rename-field')), 'My favourite');
    await tester.tap(find.text('Save'));
    await until(tester, () => list.items.single.title == 'My favourite');

    final row = (await stored(tester)).single;
    expect(row.title, 'My favourite');
    expect(row.channelId, channelUc);
    expect(row.createdAt, clock);
  });

  testWidgets('a per-channel folder can be set and cleared', (tester) async {
    await pumpScreen(tester);
    await addChannel(tester);

    picked = r'E:\Music videos';
    await tester.tap(find.text('Change folder'));
    await until(tester, () => list.items.single.outputDir == r'E:\Music videos');
    expect((await stored(tester)).single.outputDir, r'E:\Music videos');

    await tester.tap(find.text('Use default'));
    await until(tester, () => list.items.single.outputDir == null);
    expect((await stored(tester)).single.outputDir, isNull);
  });

  testWidgets('a bad link, a playlist and a duplicate are refused without touching the file', (tester) async {
    await pumpScreen(tester);

    await tester.enterText(urlField, 'https://example.com/not-youtube');
    await tester.tap(subscribe);
    await until(tester, () => find.byKey(const ValueKey('sub-add-error')).evaluate().isNotEmpty);
    expect(find.textContaining('Paste a YouTube channel link'), findsOneWidget);

    await tester.enterText(urlField, 'https://www.youtube.com/playlist?list=PLabcdefghijklmnop');
    await tester.tap(subscribe);
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Playlists and single videos'), findsOneWidget);
    expect(paths.subscriptions.existsSync(), isFalse);

    await addChannel(tester);
    await tester.enterText(urlField, 'https://www.youtube.com/channel/$channelUc');
    await tester.tap(subscribe);
    await until(tester, () => find.textContaining('already subscribed').evaluate().isNotEmpty);
    expect(await stored(tester), hasLength(1));
  });

  testWidgets('a channel that cannot be read is not added, and says why', (tester) async {
    await pumpScreen(tester);
    lister.listError = StateError('boom');
    await tester.enterText(urlField, channelUrl);
    await tester.tap(subscribe);
    await until(tester, () => find.byKey(const ValueKey('sub-add-error')).evaluate().isNotEmpty);
    expect(find.textContaining('The list could not be loaded.'), findsOneWidget);
    expect(paths.subscriptions.existsSync(), isFalse);
  });

  testWidgets('a subscriptions file this build cannot read is shown and left as it is', (tester) async {
    paths.subscriptions.writeAsStringSync('{"version": 99, "subscriptions": []}');
    await pumpScreen(tester);
    expect(find.byKey(const ValueKey('sub-load-error')), findsOneWidget);

    await tester.enterText(urlField, channelUrl);
    await tester.tap(subscribe);
    await until(tester, () => find.byKey(const ValueKey('sub-add-error')).evaluate().isNotEmpty);
    expect(paths.subscriptions.readAsStringSync(), '{"version": 99, "subscriptions": []}');
  });

  testWidgets('Check now runs a pass and shows the status and the last checked time', (tester) async {
    await pumpScreen(tester);
    await addChannel(tester);

    await tester.tap(find.byKey(const ValueKey('sub-check-now')));
    await until(tester, () => scheduler.status != null && !scheduler.isRunning);

    expect(find.text('Checked 1 of 1 channel, no new uploads.'), findsOneWidget);
    expect(find.text('Last checked ${formatChecked(clock)}'), findsOneWidget);
  });

  testWidgets('a title with invisible and bidirectional control characters is cleaned, shown and stored', (tester) async {
    lister.title = dirtyTitle('Good', ' title');
    await pumpScreen(tester);
    await addChannel(tester);
    expect(find.text('Good title'), findsOneWidget);
    expect((await stored(tester)).single.title, 'Good title');
  });

  testWidgets('the sync command is quoted as the queue quotes its commands', (tester) async {
    await pumpScreen(tester);
    final text = tester.widget<SelectableText>(find.byKey(const ValueKey('sub-cli-command'))).data!;
    expect(text, "Run the same data from a script with: mida-cli sync --subscriptions '${paths.subscriptions.path}' --archive '${paths.archive.path}'");
  });

  testWidgets('a data path with a single quote gets no command, only the reason', (tester) async {
    final odd = SubscriptionPaths.inDir(Directory("${dir.path}${Platform.pathSeparator}it's here"));
    final oddList = SubscriptionList(store: SubscriptionStore(odd.subscriptions), lister: lister);
    final oddScheduler = SubscriptionScheduler(
      subscriptions: oddList,
      archiveFile: odd.archive,
      lister: lister,
      queue: DownloadQueueService(downloads: downloads, settings: settings),
      interval: () => const Duration(minutes: 60),
    );
    addTearDown(oddScheduler.dispose);
    addTearDown(oddList.dispose);
    await pumpScreen(tester, shownList: oddList, shownScheduler: oddScheduler);

    final text = tester.widget<SelectableText>(find.byKey(const ValueKey('sub-cli-command'))).data!;
    expect(text, 'No mida-cli command is shown: A data file path contains a single quote.');
    expect(text, isNot(contains('mida-cli sync')));
  });

  testWidgets('when the data folder is the temp fallback the screen warns about it', (tester) async {
    expect(SubscriptionPaths.temporaryFallback().temporary, isTrue);
    expect(SubscriptionPaths.inDir(dir).temporary, isFalse);
    final warned = SubscriptionList(
      store: SubscriptionStore(paths.subscriptions),
      lister: lister,
      storageWarning: SubscriptionPaths.temporaryWarning,
    );
    addTearDown(warned.dispose);
    await pumpScreen(tester, shownList: warned);
    expect(find.byKey(const ValueKey('sub-storage-warning')), findsOneWidget);
    expect(find.textContaining('temporary folder'), findsOneWidget);
  });

  testWidgets('no warning when the data folder is the normal one', (tester) async {
    await pumpScreen(tester);
    expect(find.byKey(const ValueKey('sub-storage-warning')), findsNothing);
  });

  testWidgets('waiting for downloads reads "Downloading new uploads...", not "Checking..."', (tester) async {
    await pumpScreen(tester);
    await addChannel(tester);
    lister.latest = [item(1, published: clock.add(const Duration(hours: 1)))];

    await tester.tap(find.byKey(const ValueKey('sub-check-now')));
    await until(tester, () => scheduler.isDraining && downloads.pending.isNotEmpty);
    expect(find.text('Downloading new uploads...'), findsOneWidget);
    expect(find.text('Checking...'), findsNothing);

    downloads.last.succeed('a.mp4');
    await until(tester, () => !scheduler.isRunning);
    expect(find.text('Check now'), findsOneWidget);
  });

  testWidgets('the interval defaults to 60 minutes and a change is stored in the settings', (tester) async {
    await pumpScreen(tester);
    expect(settings.subscriptionIntervalMinutes, 60);
    expect(find.text('1 hour'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('sub-interval')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('15 minutes').last);
    await until(tester, () => settings.subscriptionIntervalMinutes == 15);

    final prefs = await tester.runAsync(SharedPreferences.getInstance);
    expect(prefs!.getInt(SettingsService.keySubscriptionInterval), 15);
  });
}
