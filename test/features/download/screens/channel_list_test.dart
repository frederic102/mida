import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/extractors/youtube/youtube_list_models.dart';
import 'package:mida/features/download/screens/download_screen.dart';
import 'package:mida/features/download/services/channel_list_controller.dart';
import 'package:mida/features/download/services/download_queue_service.dart';
import 'package:mida/features/download/services/download_service.dart';
import 'package:mida/features/settings/settings_service.dart';
import 'package:provider/provider.dart';

import '../../subscriptions/subscription_test_support.dart';
import '../queue/fake_download_service.dart';

void main() {
  late SettingsService settings;
  late FakeDownloadService downloads;
  late DownloadQueueService queue;
  late FakeLister lister;

  setUp(() {
    settings = SettingsService();
    settings.downloadSettings.downloadPath = r'C:\Out';
    downloads = FakeDownloadService(settings);
    queue = DownloadQueueService(downloads: downloads, settings: settings);
    lister = FakeLister(items: [for (var n = 1; n <= 4; n++) item(n)]);
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settings),
        ChangeNotifierProvider<DownloadService>.value(value: downloads),
        ChangeNotifierProvider.value(value: queue),
      ],
      child: MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: DownloadScreen(lister: lister, listDebounce: Duration.zero),
      ),
    ));
    await tester.pump();
  }

  final field = find.byKey(const ValueKey('url-field'));
  final card = find.byKey(const ValueKey('channel-list-card'));
  final add = find.byKey(const ValueKey('channel-add-to-queue'));

  Future<void> paste(WidgetTester tester, String text) async {
    await tester.enterText(field, text);
    await tester.pump(); // the debounce timer
    await tester.pump(); // the listing future
    await tester.pump();
  }

  testWidgets('a channel link loads its list and shows a title per video', (tester) async {
    await pumpScreen(tester);
    expect(card, findsNothing);

    await paste(tester, channelUrl);

    expect(lister.listed.single.pageUrl.path, '/@YouTube/videos');
    expect(find.text('Channel: The Channel'), findsOneWidget);
    for (var n = 1; n <= 4; n++) {
      expect(find.text('Video $n'), findsOneWidget);
    }
    expect(find.text('0 of 4 selected'), findsOneWidget);
    expect(queue.items, isEmpty);
  });

  testWidgets('a playlist link is detected too', (tester) async {
    await pumpScreen(tester);
    await paste(tester, 'https://www.youtube.com/playlist?list=PLabcdefghijklmnop');
    expect(lister.listed.single.kind, YoutubeListKind.playlist);
    expect(find.text('Playlist: The Channel'), findsOneWidget);
  });

  testWidgets('a single video link, even inside a playlist, is not a list', (tester) async {
    await pumpScreen(tester);
    await paste(tester, 'https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PLabcdefghijklmnop');
    expect(lister.listed, isEmpty);
    expect(card, findsNothing);
    final start = tester.widget<FilledButton>(find.byKey(const ValueKey('start-download')));
    expect(start.onPressed, isNotNull); // it stays a normal link
  });

  testWidgets('shows loading while the list is read', (tester) async {
    final gate = Completer<void>();
    final slow = _SlowLister(gate.future, lister);
    lister = slow;
    await pumpScreen(tester);
    await paste(tester, channelUrl);
    expect(find.byKey(const ValueKey('channel-list-loading')), findsOneWidget);
    gate.complete();
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('channel-list-loading')), findsNothing);
    expect(find.text('Video 1'), findsOneWidget);
  });

  testWidgets('select all, select none and the count', (tester) async {
    await pumpScreen(tester);
    await paste(tester, channelUrl);

    await tester.tap(find.text('Select all'));
    await tester.pump();
    expect(find.text('4 of 4 selected'), findsOneWidget);
    expect(find.text('Add 4 to queue'), findsOneWidget);

    await tester.tap(find.text('Select none'));
    await tester.pump();
    expect(find.text('0 of 4 selected'), findsOneWidget);
    expect(tester.widget<FilledButton>(add).onPressed, isNull);
  });

  testWidgets('Add N to queue adds exactly the ticked videos, in list order', (tester) async {
    await pumpScreen(tester);
    await paste(tester, channelUrl);

    await tester.tap(find.byKey(ValueKey('channel-item-${vid(3)}')));
    await tester.tap(find.byKey(ValueKey('channel-item-${vid(1)}')));
    await tester.pump();
    expect(find.text('2 of 4 selected'), findsOneWidget);

    await tester.tap(add);
    await tester.pump();

    expect([for (final i in queue.items) i.url], [watchUrl(1), watchUrl(3)]);
    expect(queue.items.every((i) => i.type == DownloadType.video && i.outputDir == null), isTrue);
    expect(downloads.calls, [watchUrl(1)]); // the queue is running
    expect(find.text('0 of 4 selected'), findsOneWidget); // ticks are cleared after adding
  });

  testWidgets('a truncated listing says so', (tester) async {
    lister.truncated = true;
    await pumpScreen(tester);
    await paste(tester, channelUrl);
    expect(find.byKey(const ValueKey('channel-list-truncated')), findsOneWidget);
  });

  testWidgets('a policy refusal shows its own message, and Retry loads again', (tester) async {
    lister.listError = const MediaExtractionException('LOGIN_REQUIRED', 'This channel is only visible to signed-in viewers.');
    await pumpScreen(tester);
    await paste(tester, channelUrl);
    expect(find.text('This channel is only visible to signed-in viewers.'), findsOneWidget);
    expect(find.text('Video 1'), findsNothing);
    expect(find.text('Use browser login and retry'), findsNothing); // listing never uses the login session

    lister.listError = null;
    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Video 1'), findsOneWidget);
    expect(lister.listed, hasLength(2));
  });

  testWidgets('two playlists: the first gets the list and the second is named as not loaded', (tester) async {
    const first = 'https://www.youtube.com/playlist?list=PLaaaaaaaaaaaaaaaa';
    const second = 'https://www.youtube.com/playlist?list=PLbbbbbbbbbbbbbbbb';
    await pumpScreen(tester);
    await paste(tester, '$first\n$second');

    expect(lister.listed, hasLength(1));
    expect(lister.listed.single.id, 'PLaaaaaaaaaaaaaaaa');
    final note = find.byKey(const ValueKey('channel-list-ignored'));
    expect(note, findsOneWidget);
    expect(tester.widget<Text>(note).data, allOf(contains(second), isNot(contains(first))));

    // Removing the first link makes the second one the list.
    await tester.enterText(field, second);
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(lister.listed.last.id, 'PLbbbbbbbbbbbbbbbb');
    expect(note, findsNothing);
  });

  testWidgets('one list link shows no ignored-lists note', (tester) async {
    await pumpScreen(tester);
    await paste(tester, channelUrl);
    expect(find.byKey(const ValueKey('channel-list-ignored')), findsNothing);
  });

  testWidgets('titles lose invisible and bidirectional control characters', (tester) async {
    lister.items = [item(1).withTitle(dirtyTitle('Safe', ' title'))];
    lister.title = dirtyTitle('Chan', 'nel');
    await pumpScreen(tester);
    await paste(tester, channelUrl);
    expect(find.text('Safe title'), findsOneWidget);
    expect(find.text('Channel: Channel'), findsOneWidget);
  });

  testWidgets('a network failure uses the queue wording', (tester) async {
    lister.listError = const MediaExtractionException('NETWORK', 'down');
    await pumpScreen(tester);
    await paste(tester, channelUrl);
    expect(find.text('MiDa could not reach the site.'), findsOneWidget);
  });

  testWidgets('Enter queues the plain links and leaves the channel link and its list alone', (tester) async {
    await pumpScreen(tester);
    await paste(tester, '$channelUrl\nhttps://a.example/1');
    expect(find.text('Video 1'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect([for (final i in queue.items) i.url], ['https://a.example/1']);
    expect(tester.widget<TextField>(field).controller!.text, channelUrl);
    expect(find.text('Video 1'), findsOneWidget);
  });

  testWidgets('clearing the field hides the list', (tester) async {
    await pumpScreen(tester);
    await paste(tester, channelUrl);
    expect(card, findsOneWidget);
    await tester.enterText(field, '');
    await tester.pump();
    expect(card, findsNothing);
  });

  group('ChannelListController', () {
    test('typing a handle letter by letter lists only the last link', () async {
      final controller = ChannelListController(lister, debounce: const Duration(milliseconds: 30));
      controller.updateUrls(['https://www.youtube.com/@Yo']);
      controller.updateUrls(['https://www.youtube.com/@You']);
      controller.updateUrls(['https://www.youtube.com/@YouTube']);
      await waitUntil(() => controller.phase == ChannelListPhase.loaded);
      expect(lister.listed, hasLength(1));
      expect(lister.listed.single.pageUrl.path, '/@YouTube/videos');
      controller.dispose();
    });

    test('an answer for a link that was replaced is dropped', () async {
      final gate = Completer<void>();
      final controller = ChannelListController(_SlowLister(gate.future, lister), debounce: Duration.zero);
      controller.updateUrls([channelUrl]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      controller.updateUrls(const []);
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(controller.phase, ChannelListPhase.idle);
      expect(controller.listing, isNull);
      controller.dispose();
    });
  });
}

extension on YoutubeListItem {
  YoutubeListItem withTitle(String title) => YoutubeListItem(id: id, title: title, published: published);
}

class _SlowLister extends FakeLister {
  _SlowLister(this._wait, FakeLister from) : super(items: from.items);

  final Future<void> _wait;

  @override
  Future<YoutubeListing> list(target, {int maxItems = 500, int maxPages = 200}) async {
    await _wait;
    return super.list(target, maxItems: maxItems, maxPages: maxPages);
  }
}
