import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/extractors/youtube/youtube_list_models.dart';
import 'package:mida/core/extractors/youtube/youtube_list_parser.dart';
import 'package:mida/core/extractors/youtube/youtube_list_target.dart';

import 'youtube_list_support.dart';

Matcher failsWith(String status) => throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', status));

Matcher parseError() => failsWith('PARSE_ERROR');

void main() {
  group('parser on captured pages', () {
    test('channel Videos tab: ids, titles, channel id, continuation', () {
      final r = YoutubeListParser.initial(fixtureJson('channel_initial.json'), kind: YoutubeListKind.channel);
      expect(r.title, 'YouTube');
      expect(r.channelId, channelUc);
      expect(r.page.items.length, 6);
      expect(r.page.items.first.id, 'dD33lDxL9K0');
      expect(r.page.items.first.title, 'Sourav Joshi drew sketches for \$5. Now he has 42 million subscribers');
      expect(r.page.items.first.url.toString(), 'https://www.youtube.com/watch?v=dD33lDxL9K0');
      expect(r.page.items.first.published, isNull);
      expect(r.page.continuation, isNotEmpty);
    });

    test('channel continuation: more items and a further token', () {
      final page = YoutubeListParser.continuation(fixtureJson('channel_continuation.json'));
      expect(page.items.map((i) => i.id).first, 'LeSkX_1w28g');
      expect(page.items.length, 6);
      expect(page.continuation, isNotEmpty);
    });

    test('real playlist page: 15 videos and a section-level continuation token', () {
      final r = YoutubeListParser.initial(fixtureJson('playlist_initial.json'), kind: YoutubeListKind.playlist);
      expect(r.title, 'Knock, knock');
      expect(r.page.items.length, 15);
      expect(r.page.items.first.id, 'mwe7AUWWa5E');
      expect(r.page.continuation, isNotEmpty, reason: 'this is the token whose answer used to fail');
    });

    test('the real answer to that token (an envelope with no actions) is an explicit end, not an error', () {
      final page = YoutubeListParser.continuation(fixtureJson('playlist_continuation_end.json'));
      expect(page.items, isEmpty);
      expect(page.continuation, isNull);
    });

    test('playlist with a continuation item view model, and its continuation', () {
      final r = YoutubeListParser.initial(fixtureJson('playlist_paged_initial.json'), kind: YoutubeListKind.playlist);
      expect(r.page.items.length, 5);
      expect(r.page.continuation, isNotEmpty);
      final more = YoutubeListParser.continuation(fixtureJson('playlist_continuation.json'));
      expect(more.items.first.id, 'MNoEtQXekBM');
      expect(more.continuation, isNotEmpty);
    });

    test('ytInitialData is found inside page HTML, strings with braces and quotes included', () {
      final data = {'a': 'x } {" \\', 'b': {'c': 1}};
      expect(YoutubeListParser.initialData(pageHtml(data)), data);
      expect(YoutubeListParser.clientVersion(pageHtml(data)), '2.20261119.07.00');
    });

    test('RSS feed: ids, titles, absolute times', () {
      final items = YoutubeListParser.feed(fixtureText('channel_feed.xml'), channelId: channelUc);
      expect(items.map((i) => i.id), ['QwhynRkyiYQ', 'FMzaMmbtVD0', '3mwmwKBb44c']);
      expect(items.first.published, DateTime.utc(2026, 11, 21, 20, 0, 40));
      expect(items.first.title, startsWith('Oprah said add to cart'));
    });
  });

  group('legitimate empty lists are recognized explicitly', () {
    test('a channel whose video grid is present and empty', () {
      final r = YoutubeListParser.initial(channelPageWith([]), kind: YoutubeListKind.channel);
      expect(r.page.items, isEmpty);
      expect(r.channelId, channelUc);
    });

    test('a grid holding only a known placeholder', () {
      final r = YoutubeListParser.initial(channelPageWith([{'richSectionRenderer': <String, dynamic>{}}]), kind: YoutubeListKind.channel);
      expect(r.page.items, isEmpty);
    });

    test('a playlist whose section holds only a message', () {
      final data = fixtureJson('playlist_initial.json');
      final tab = ((data['contents'] as Map)['twoColumnBrowseResultsRenderer']['tabs'] as List).first['tabRenderer'] as Map;
      tab['content'] = {
        'sectionListRenderer': {
          'contents': [
            {
              'itemSectionRenderer': {
                'contents': [
                  {'messageRenderer': <String, dynamic>{}},
                ],
              },
            },
          ],
        },
      };
      expect(YoutubeListParser.initial(data, kind: YoutubeListKind.playlist).page.items, isEmpty);
    });

    test('a complete feed with no entries', () {
      expect(YoutubeListParser.feed(feedXml(), channelId: channelUc), isEmpty);
    });
  });

  group('parser fails closed', () {
    test('no initial data / cut off / not JSON', () {
      expect(() => YoutubeListParser.initialData('<html>consent</html>'), parseError());
      expect(() => YoutubeListParser.initialData('var ytInitialData = {"a":{"b":1'), parseError());
      expect(() => YoutubeListParser.initialData('var ytInitialData = {nope};'), parseError());
      expect(() => YoutubeListParser.initialData('var ytInitialData = [];'), parseError());
    });

    test('a playlist page is not a channel page and the reverse', () {
      expect(() => YoutubeListParser.initial(fixtureJson('playlist_initial.json'), kind: YoutubeListKind.channel), parseError());
      expect(() => YoutubeListParser.initial(fixtureJson('channel_initial.json'), kind: YoutubeListKind.playlist), parseError());
    });

    test('a channel whose selected tab is not the video grid, or whose grid has no contents', () {
      final home = fixtureJson('channel_initial.json');
      final tabs = (home['contents'] as Map)['twoColumnBrowseResultsRenderer']['tabs'] as List;
      final selected = tabs.firstWhere((t) => t['tabRenderer']['selected'] == true)['tabRenderer'] as Map;
      selected['content'] = {'sectionListRenderer': <String, dynamic>{}};
      expect(() => YoutubeListParser.initial(home, kind: YoutubeListKind.channel), parseError());
      selected['content'] = {'richGridRenderer': <String, dynamic>{}};
      expect(() => YoutubeListParser.initial(home, kind: YoutubeListKind.channel), parseError());
    });

    test('an unknown renderer among the entries is an error, not a skipped entry', () {
      final entries = [
        ...(fixtureJson('channel_initial.json')['contents'] as Map)['twoColumnBrowseResultsRenderer']['tabs'][1]['tabRenderer']['content']
            ['richGridRenderer']['contents'] as List,
        {'someNewVideoRenderer': {'videoId': 'QwhynRkyiYQ'}},
      ];
      expect(() => YoutubeListParser.initial(channelPageWith(entries), kind: YoutubeListKind.channel), parseError());
    });

    test('a non-video lockup, an invalid id next to valid ones, and a non-object entry', () {
      Map<String, dynamic> withEntry(dynamic e) {
        final page = lastPage(['QwhynRkyiYQ']);
        (((page['onResponseReceivedActions'] as List).first as Map)['appendContinuationItemsAction']['continuationItems'] as List).add(e);
        return page;
      }

      expect(YoutubeListParser.continuation(withEntry({'richSectionRenderer': <String, dynamic>{}})).items.length, 1);
      for (final bad in [
        {'richItemRenderer': {'content': {'lockupViewModel': {'contentId': 'PLabcdefghijk', 'contentType': 'LOCKUP_CONTENT_TYPE_PLAYLIST'}}}},
        {'richItemRenderer': {'content': {'lockupViewModel': {'contentId': '../../etc/passwd', 'contentType': 'LOCKUP_CONTENT_TYPE_VIDEO'}}}},
        {'videoRenderer': {'videoId': 'a b'}},
        {'videoRenderer': 5},
        'text',
        {'a': 1, 'b': 2},
      ]) {
        expect(() => YoutubeListParser.continuation(withEntry(bad)), parseError(), reason: '$bad');
      }
    });

    test('malformed continuation tokens and two different tokens on one page', () {
      for (final token in ['', 'short', 'has space in it xxxxxxxxxxxx', 'ok_token_xxxxxxxxxxxx<script>']) {
        expect(() => YoutubeListParser.continuation(lastPage(['QwhynRkyiYQ'], token: token)), parseError(), reason: token);
      }
      final two = lastPage(['QwhynRkyiYQ'], token: tokenFor(1));
      (((two['onResponseReceivedActions'] as List).first as Map)['appendContinuationItemsAction']['continuationItems'] as List)
          .add(lastPage([], token: tokenFor(2))['onResponseReceivedActions'][0]['appendContinuationItemsAction']['continuationItems'][0]);
      expect(() => YoutubeListParser.continuation(two), parseError());
    });

    test('an API error is not an empty page; unknown envelopes are errors', () {
      expect(() => YoutubeListParser.continuation({'error': {'code': 429}}), failsWith('RATE_LIMITED'));
      expect(() => YoutubeListParser.continuation({'error': {'code': 503}}), failsWith('NETWORK'));
      expect(() => YoutubeListParser.continuation({'error': {'code': 400, 'message': 'bad'}}), parseError());
      expect(() => YoutubeListParser.continuation({'responseContext': {}, 'continuationContents': {}}), parseError());
      expect(() => YoutubeListParser.continuation({}), parseError());
      expect(() => YoutubeListParser.continuation({'onResponseReceivedActions': <dynamic>[]}), parseError());
      expect(() => YoutubeListParser.continuation({'onResponseReceivedActions': [{'reloadContinuationItemsCommand': {}}]}), parseError());
    });

    test('truncated or malformed RSS never becomes a (possibly empty) success', () {
      final full = fixtureText('channel_feed.xml');
      final firstEntryEnd = full.indexOf('</entry>') + '</entry>'.length;
      for (final bad in [
        '<html>Not found</html>',
        '<feed><entry>',
        full.substring(0, firstEntryEnd), // one complete entry, then cut off
        full.substring(0, full.length - 20),
        full.replaceFirst('</entry>', ''),
        '<feed><entry><yt:videoId>short</yt:videoId></entry></feed>',
        feedXml().replaceFirst('<yt:channelId>BR8-60-B28hp2BmDPdntcQ</yt:channelId>', ''),
        feedXml([('QwhynRkyiYQ', 'soon')]),
        feedXml([('QwhynRkyiYQ', '2026-11-21T20:00:40+00:00')]).replaceFirst('<yt:videoId>QwhynRkyiYQ</yt:videoId>', ''),
      ]) {
        expect(() => YoutubeListParser.feed(bad, channelId: channelUc), parseError(), reason: bad.length > 80 ? bad.substring(0, 80) : bad);
      }
      expect(() => YoutubeListParser.feed(full, channelId: 'UCaaaaaaaaaaaaaaaaaaaaaa'), parseError(), reason: 'another channel');
    });

    test('hostile titles are cleaned and capped', () {
      final long = lastPage(['FMzaMmbtVD0']);
      final item = (((long['onResponseReceivedActions'] as List).first as Map)['appendContinuationItemsAction']['continuationItems'] as List).first
          as Map;
      item['richItemRenderer']['content']['lockupViewModel']['metadata']['lockupMetadataViewModel']['title']['content'] =
          'a\u0000\n${'x' * 400}';
      final title = YoutubeListParser.continuation(long).items.single.title;
      expect(title.length, 300);
      expect(title.contains(RegExp(r'[\u0000-\u001f]')), isFalse);
    });
  });

  group('lister', () {
    final target = YoutubeListTarget.parse('https://www.youtube.com/@YouTube')!;
    final playlist = YoutubeListTarget.parse('https://www.youtube.com/playlist?list=PLbpi6ZahtOH4vec4VIxczjwC4pY0jAPNC')!;

    FakeTransport channelTransport({List<Map<String, dynamic>>? browse}) => FakeTransport(
          pages: {channelPath: pageHtml(fixtureJson('channel_initial.json'))},
          browse: browse ?? [fixtureJson('channel_continuation.json')],
        );

    test('follows continuations in order and sends the WEB client context and token', () async {
      final t = channelTransport(browse: [fixtureJson('channel_continuation.json'), lastPage(['AAAAAAAAAAA', 'BBBBBBBBBBB'])]);
      final listing = await listerOver(t).list(target);
      expect(listing.kind, YoutubeListKind.channel);
      expect(listing.id, channelUc);
      expect(listing.title, 'YouTube');
      expect(listing.items.length, 6 + 6 + 2);
      expect(listing.items.first.id, 'dD33lDxL9K0');
      expect(listing.items.last.id, 'BBBBBBBBBBB');
      expect(listing.truncated, isFalse);
      expect(t.closed, isTrue);
      final client = (t.posted.first['context'] as Map)['client'] as Map;
      expect(client['clientName'], 'WEB');
      expect(client['clientVersion'], '2.20261119.07.00');
      expect(client['visitorData'], 'VD');
      expect(t.posted.first['continuation'], isNotEmpty);
    });

    test('item cap trims the list and reports truncated', () async {
      final t = channelTransport();
      final listing = await listerOver(t).list(target, maxItems: 8);
      expect(listing.items.length, 8);
      expect(listing.truncated, isTrue);
      expect(t.posted.length, 1);
    });

    test('a cap met exactly on the last page is not truncated', () async {
      final t = channelTransport(browse: [lastPage(['AAAAAAAAAAA', 'BBBBBBBBBBB'])]);
      final listing = await listerOver(t).list(target, maxItems: 8);
      expect(listing.items.length, 8);
      expect(listing.truncated, isFalse);
    });

    test('page cap: distinct tokens and fresh ids keep coming, the lister stops at maxPages', () async {
      final t = channelTransport(browse: [
        for (var n = 1; n <= 10; n++) lastPage(['ABCDEFGHIJ'[n - 1] * 11], token: tokenFor(n)),
      ]);
      final listing = await listerOver(t).list(target, maxPages: 3, maxItems: 1000);
      expect(t.posted.length, 3, reason: 'without the page cap it would go on to the 10 scripted pages');
      expect(listing.items.length, 6 + 3);
      expect(listing.truncated, isTrue);
    });

    test('a repeated token with nothing new stops the walk and reports truncated', () async {
      final endless = fixtureJson('channel_continuation.json');
      final t = channelTransport(browse: [endless, endless, endless]);
      final listing = await listerOver(t).list(target, maxItems: 1000);
      expect(t.posted.length, 2);
      expect(listing.items.length, 12);
      expect(listing.truncated, isTrue);
    });

    test('a malformed continuation fails the whole listing and closes the transport', () async {
      final t = channelTransport(browse: [<String, dynamic>{}]);
      await expectLater(listerOver(t).list(target), parseError());
      expect(t.closed, isTrue);
    });

    test('real playlist: the section token is followed and its empty answer ends the list', () async {
      final t = FakeTransport(
        pages: {'/playlist': pageHtml(fixtureJson('playlist_initial.json'))},
        browse: [fixtureJson('playlist_continuation_end.json')],
      );
      final listing = await listerOver(t).list(playlist);
      expect(listing.kind, YoutubeListKind.playlist);
      expect(listing.items.length, 15);
      expect(listing.truncated, isFalse);
      expect(t.posted.length, 1);
    });

    test('multi-page playlist: page, continuation, continuation, explicit end', () async {
      final t = FakeTransport(
        pages: {'/playlist': pageHtml(fixtureJson('playlist_paged_initial.json'))},
        browse: [
          fixtureJson('playlist_continuation.json'),
          lastPage(['AAAAAAAAAAA', 'BBBBBBBBBBB'], token: tokenFor(1)),
          fixtureJson('playlist_continuation_end.json'),
        ],
      );
      final listing = await listerOver(t).list(playlist);
      expect(listing.items.length, 5 + 5 + 2);
      expect(listing.items.first.id, 'QwhynRkyiYQ');
      expect(listing.truncated, isFalse);
    });

    test('an API error answer fails the listing instead of ending it', () async {
      final t = FakeTransport(
        pages: {'/playlist': pageHtml(fixtureJson('playlist_initial.json'))},
        browse: [
          {'error': {'code': 400}},
        ],
      );
      await expectLater(listerOver(t).list(playlist), parseError());
    });

    test('an empty channel lists as empty', () async {
      final t = FakeTransport(pages: {channelPath: pageHtml(channelPageWith([]))});
      final listing = await listerOver(t).list(target);
      expect(listing.items, isEmpty);
      expect(listing.id, channelUc);
      expect(listing.truncated, isFalse);
    });

    test('latestUploads reads the feed and rejects a non-channel id', () async {
      final t = FakeTransport(pages: {'/feeds/videos.xml': fixtureText('channel_feed.xml')});
      final items = await listerOver(t).latestUploads(channelUc);
      expect(items.length, 3);
      expect(t.fetched.single.queryParameters['channel_id'], channelUc);
      await expectLater(listerOver(t).latestUploads('../x'), failsWith('UNSUPPORTED_URL'));
    });
  });
}
