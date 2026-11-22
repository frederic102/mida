import '../media_models.dart';
import 'youtube_list_models.dart';
import 'youtube_list_parser.dart';
import 'youtube_list_target.dart';
import 'youtube_list_transport.dart';
import 'youtube_session.dart';

/// Lists a YouTube channel's uploads or a playlist through YouTube's own
/// public web endpoints: the page's embedded data for the first screen, the
/// browse continuation for the rest, and the channel RSS feed for the cheap
/// "latest uploads" check. No login, no cookies of the user.
class YoutubeLister {
  static const defaultMaxItems = 500;
  static const _fallbackClientVersion = '2.20261119.07.00';

  final YoutubeListTransport Function() _transportFactory;
  final Future<void> Function(Duration) _pause;
  final Duration _pageDelay;

  YoutubeLister({
    YoutubeListTransport Function()? transportFactory,
    Future<void> Function(Duration)? pause,
    Duration pageDelay = const Duration(milliseconds: 400),
  })  : _transportFactory = transportFactory ?? YoutubeHttpTransport.new,
        _pause = pause ?? Future<void>.delayed,
        _pageDelay = pageDelay;

  /// The full listing, newest first for a channel, playlist order for a
  /// playlist. Stops at [maxItems] items or [maxPages] continuation pages
  /// and then reports `truncated`. A malformed page throws `PARSE_ERROR`.
  Future<YoutubeListing> list(
    YoutubeListTarget target, {
    int maxItems = defaultMaxItems,
    int maxPages = 200,
  }) async {
    if (maxItems < 1) throw ArgumentError.value(maxItems, 'maxItems');
    final transport = _transportFactory();
    try {
      final html = await transport.getText(target.pageUrl);
      final first = YoutubeListParser.initial(YoutubeListParser.initialData(html), kind: target.kind);
      final channelId = first.channelId;
      if (target.kind == YoutubeListKind.channel && channelId == null) {
        throw const MediaExtractionException('PARSE_ERROR', 'The channel page has no channel id.');
      }
      final seen = <String>{};
      final items = [
        for (final i in first.page.items)
          if (seen.add(i.id)) i,
      ];
      var next = first.page.continuation;
      var pages = 0;
      var stale = 0;
      final tokens = <String>{};
      final visitorData = YoutubeSession.extractVisitorData(html);
      final context = {
        'client': {
          'clientName': 'WEB',
          'clientVersion': YoutubeListParser.clientVersion(html) ?? _fallbackClientVersion,
          'hl': 'en',
          'timeZone': 'UTC',
          'utcOffsetMinutes': 0,
          if (visitorData != null) 'visitorData': visitorData,
        },
      };

      while (items.length < maxItems && next != null && pages < maxPages && tokens.add(next) && stale < 3) {
        await _pause(_pageDelay);
        pages++;
        final page = YoutubeListParser.continuation(await transport.postBrowse({'context': context, 'continuation': next}));
        final before = items.length;
        for (final item in page.items) {
          if (seen.add(item.id)) items.add(item);
        }
        stale = items.length == before ? stale + 1 : 0;
        next = page.continuation;
      }
      final more = items.length > maxItems || next != null;
      return YoutubeListing(
        kind: target.kind,
        id: channelId ?? target.id!,
        title: first.title,
        items: items.length > maxItems ? items.sublist(0, maxItems) : items,
        truncated: more,
      );
    } finally {
      transport.close();
    }
  }

  /// The channel's latest uploads (the feed holds about 15) with absolute
  /// publish times, newest first.
  Future<List<YoutubeListItem>> latestUploads(String channelId) async {
    if (!RegExp(r'^UC[A-Za-z0-9_-]{22}$').hasMatch(channelId)) {
      throw const MediaExtractionException('UNSUPPORTED_URL', 'Not a YouTube channel id.');
    }
    final transport = _transportFactory();
    try {
      final xml = await transport.getText(Uri.https('www.youtube.com', '/feeds/videos.xml', {'channel_id': channelId}));
      return YoutubeListParser.feed(xml, channelId: channelId);
    } finally {
      transport.close();
    }
  }
}
