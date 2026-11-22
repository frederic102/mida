import 'dart:convert';
import 'dart:io';

import 'package:mida/core/extractors/youtube/youtube_list_transport.dart';
import 'package:mida/core/extractors/youtube/youtube_lister.dart';

const _dir = 'test/fixtures/youtube_list';

String fixtureText(String name) => File('$_dir/$name').readAsStringSync();

Map<String, dynamic> fixtureJson(String name) => jsonDecode(fixtureText(name)) as Map<String, dynamic>;

/// A page the way YouTube serves it: the data object inside a script.
String pageHtml(Map<String, dynamic> data) =>
    '<html><head><title>x</title></head><body><script>var ytInitialData = ${jsonEncode(data)};</script>'
    '<script>ytcfg.set({"INNERTUBE_CONTEXT_CLIENT_VERSION":"2.20261119.07.00","visitorData":"VD"});</script></body></html>';

/// Scripted transport: [pages] by URL path+query, [browse] answers in order.
class FakeTransport implements YoutubeListTransport {
  final Map<String, String> pages;
  final List<Map<String, dynamic>> browse;
  final List<Map<String, dynamic>> posted = [];
  final List<Uri> fetched = [];
  var closed = false;

  FakeTransport({this.pages = const {}, this.browse = const []});

  @override
  Future<String> getText(Uri url) async {
    fetched.add(url);
    return pages[url.path] ?? pages[url.toString()] ?? (throw StateError('Unscripted GET $url'));
  }

  @override
  Future<Map<String, dynamic>> postBrowse(Map<String, dynamic> body) async {
    posted.add(body);
    if (posted.length > browse.length) throw StateError('Unscripted browse call ${posted.length}');
    return browse[posted.length - 1];
  }

  @override
  void close() => closed = true;
}

/// Every read fails with [error] (a feed that answers 429, say).
class FailingFeed extends FakeTransport {
  final Object error;

  FailingFeed(this.error);

  @override
  Future<String> getText(Uri url) async => throw error;
}

YoutubeLister listerOver(FakeTransport t) =>
    YoutubeLister(transportFactory: () => t, pause: (_) async {}, pageDelay: Duration.zero);

/// A token that passes the parser's shape check.
String tokenFor(int n) => 'TOKEN$n'.padRight(24, 'x');

/// A continuation response of [ids]; [token] adds a "next page" entry.
Map<String, dynamic> lastPage(List<String> ids, {String? token}) => {
      'onResponseReceivedActions': [
        {
          'appendContinuationItemsAction': {
            'continuationItems': <dynamic>[
              if (token != null)
                {
                  'continuationItemRenderer': {
                    'continuationEndpoint': {
                      'continuationCommand': {'token': token},
                    },
                  },
                },
              for (final id in ids)
                {
                  'richItemRenderer': {
                    'content': {
                      'lockupViewModel': {
                        'contentId': id,
                        'contentType': 'LOCKUP_CONTENT_TYPE_VIDEO',
                        'metadata': {
                          'lockupMetadataViewModel': {
                            'title': {'content': 'Title $id'},
                          },
                        },
                      },
                    },
                  },
                },
            ],
          },
        },
      ],
    };

/// A complete Atom feed for [channelUc] with the given (id, published) entries.
String feedXml([List<(String, String)> entries = const []]) =>
    '<?xml version="1.0" encoding="UTF-8"?>\n<feed xmlns:yt="http://www.youtube.com/xml/schemas/2015" xmlns="http://www.w3.org/2005/Atom">\n'
    ' <id>yt:channel:BR8-60-B28hp2BmDPdntcQ</id>\n <yt:channelId>BR8-60-B28hp2BmDPdntcQ</yt:channelId>\n <title>YouTube</title>\n'
    '${[for (final (id, at) in entries) ' <entry>\n  <id>yt:video:$id</id>\n  <yt:videoId>$id</yt:videoId>\n  <title>t $id</title>\n  <published>$at</published>\n </entry>\n'].join()}'
    '</feed>\n';

/// The captured channel page with the Videos grid replaced by [entries].
Map<String, dynamic> channelPageWith(List<dynamic> entries) {
  final data = fixtureJson('channel_initial.json');
  final tabs = (data['contents'] as Map)['twoColumnBrowseResultsRenderer']['tabs'] as List;
  final selected = tabs.firstWhere((t) => t['tabRenderer']['selected'] == true)['tabRenderer'] as Map;
  selected['content'] = {
    'richGridRenderer': {'contents': entries},
  };
  return data;
}

const channelPath = '/@YouTube/videos';
const channelUc = 'UCBR8-60-B28hp2BmDPdntcQ';
