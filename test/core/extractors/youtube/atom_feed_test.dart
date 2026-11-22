import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/extractors/youtube/youtube_list_models.dart';
import 'package:mida/core/extractors/youtube/youtube_list_parser.dart';

import 'youtube_list_support.dart';

const _atom = 'http://www.w3.org/2005/Atom';
const _yt = 'http://www.youtube.com/xml/schemas/2015';

List<(String, DateTime?, String)> _view(List<YoutubeListItem> items) => [for (final i in items) (i.id, i.published, i.title)];

Matcher _parseError() => throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'PARSE_ERROR'));

void main() {
  final expected = _view(YoutubeListParser.feed(feedXml([('QwhynRkyiYQ', '2026-11-21T20:00:40+00:00'), ('FMzaMmbtVD0', '2026-11-20T23:00:25+00:00')])));

  test('the baseline feed has the two uploads', () {
    expect(expected.map((e) => e.$1), ['QwhynRkyiYQ', 'FMzaMmbtVD0']);
    expect(expected.first.$2, DateTime.utc(2026, 11, 21, 20, 0, 40));
    expect(expected.first.$3, 't QwhynRkyiYQ');
  });

  const head = '<id>yt:channel:BR8-60-B28hp2BmDPdntcQ</id><yt:channelId>BR8-60-B28hp2BmDPdntcQ</yt:channelId>';
  String entry(String id, String at, {String open = '<entry>', String close = '</entry>', String title = ''}) =>
      '$open<id>yt:video:$id</id><yt:videoId>$id</yt:videoId><title>${title.isEmpty ? 't $id' : title}</title><published>$at</published>$close';
  const a = ('QwhynRkyiYQ', '2026-11-21T20:00:40+00:00');
  const b = ('FMzaMmbtVD0', '2026-11-20T23:00:25+00:00');
  String feed(String entries, {String open = '<feed xmlns="$_atom" xmlns:yt="$_yt">', String close = '</feed>'}) => '$open$head$entries$close';

  group('equivalent forms give identical uploads', () {
    final variants = <String, String>{
      'space in the entry tags': feed(entry(a.$1, a.$2, open: '<entry >', close: '</entry >') + entry(b.$1, b.$2, open: '<entry\n  >', close: '</entry\t>')),
      'attributes on entry': feed(entry(a.$1, a.$2, open: '<entry xml:lang="en" x=\'1\'>') + entry(b.$1, b.$2, open: '<entry  foo = "bar" >')),
      'prefixed Atom and yt names': '<a:feed xmlns:a="$_atom" xmlns:y="$_yt"><a:id>x</a:id><y:channelId>BR8-60-B28hp2BmDPdntcQ</y:channelId>'
          '<a:entry><y:videoId>QwhynRkyiYQ</y:videoId><a:title>t QwhynRkyiYQ</a:title><a:published>${a.$2}</a:published></a:entry>'
          '<a:entry><y:videoId>FMzaMmbtVD0</y:videoId><a:title>t FMzaMmbtVD0</a:title><a:published>${b.$2}</a:published></a:entry></a:feed>',
      'namespaces declared on the entries': '<feed xmlns="$_atom"><id>x</id><yt:channelId xmlns:yt="$_yt">BR8-60-B28hp2BmDPdntcQ</yt:channelId>'
          '<entry xmlns:yt="$_yt"><yt:videoId>QwhynRkyiYQ</yt:videoId><title>t QwhynRkyiYQ</title><published>${a.$2}</published></entry>'
          '<entry xmlns:yt="$_yt"><yt:videoId>FMzaMmbtVD0</yt:videoId><title>t FMzaMmbtVD0</title><published>${b.$2}</published></entry></feed>',
      'declaration, BOM, comments, CDATA, references, CRLF': '﻿<?xml version="1.0" encoding="UTF-8"?>\r\n<!-- c -->\r\n'
          '<feed xmlns=\'$_atom\' xmlns:yt=\'$_yt\'>\r\n$head<!-- c -->'
          '${entry(a.$1, a.$2, title: '<![CDATA[t QwhynRkyiYQ]]>')}\r\n${entry(b.$1, b.$2, title: 't&#32;FMzaMmbtVD0')}\r\n</feed>\r\n',
      'self-closing unrelated elements and extra children': feed('<link rel="alternate" href="x"/>${entry(a.$1, a.$2)}<author><name>n</name></author>${entry(b.$1, b.$2)}'),
    };
    variants.forEach((name, xml) {
      test(name, () => expect(_view(YoutubeListParser.feed(xml, channelId: channelUc)), expected));
    });
  });

  group('malformed documents fail closed', () {
    final bads = <String, String>{
      'mismatched end tag': feed(entry(a.$1, a.$2, close: '</entri>')),
      'entry never closed': feed(entry(a.$1, a.$2, close: '')),
      'closing tag only': feed('</entry>'),
      'entry nested in entry': feed('<entry>${entry(a.$1, a.$2)}</entry>'),
      'entry hidden inside author': feed('<author>${entry(a.$1, a.$2)}</author>'),
      'second root': '${feed(entry(a.$1, a.$2))}${feed('')}',
      'text after the root': '${feed(entry(a.$1, a.$2))} trailing',
      'unbound prefix': feed(entry(a.$1, a.$2).replaceFirst('<entry>', '<z:entry>').replaceFirst('</entry>', '</z:entry>')),
      'DOCTYPE': '<!DOCTYPE feed [<!ENTITY x "y">]>${feed(entry(a.$1, a.$2))}',
      'bare ampersand': feed(entry(a.$1, a.$2, title: 'a & b')),
      'unknown entity': feed(entry(a.$1, a.$2, title: '&nbsp;')),
      'unterminated attribute': feed(entry(a.$1, a.$2, open: '<entry x="1>')),
      'duplicate attribute': feed(entry(a.$1, a.$2, open: '<entry x="1" x="2">')),
      'wrong Atom namespace': feed(entry(a.$1, a.$2), open: '<feed xmlns="http://example.com/other" xmlns:yt="$_yt">'),
      'not a feed root': '<rss><channel/></rss>',
      'two channel ids': feed(entry(a.$1, a.$2)).replaceFirst(head, '$head<yt:channelId>BR8-60-B28hp2BmDPdntcQ</yt:channelId>'),
      'entry with two video ids': feed(entry(a.$1, a.$2).replaceFirst('<title>', '<yt:videoId>${b.$1}</yt:videoId><title>')),
      'entry without a date': feed(entry(a.$1, a.$2).replaceFirst(RegExp('<published>.*</published>'), '')),
      'cut off': feed(entry(a.$1, a.$2), close: ''),
      'empty': '',
    };
    bads.forEach((name, xml) {
      test(name, () => expect(() => YoutubeListParser.feed(xml, channelId: channelUc), _parseError()));
    });
  });
}
