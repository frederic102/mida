import 'dart:convert';

import '../media_models.dart';
import 'atom_xml.dart';
import 'youtube_list_models.dart';

/// Pure parsers for YouTube channel/playlist pages, browse continuations and
/// the channel RSS feed. They fail closed: every entry and every token must
/// be a shape this code knows, and anything else throws `PARSE_ERROR`
/// instead of yielding a short list that looks complete. "Nothing here" is
/// accepted only in the explicit forms described on each method.
class YoutubeListParser {
  const YoutubeListParser._();

  static final _videoId = RegExp(r'^[A-Za-z0-9_-]{11}$');
  static final _channelIdPattern = RegExp(r'^UC[A-Za-z0-9_-]{22}$');
  static final _tokenPattern = RegExp(r'^[A-Za-z0-9%_=-]{16,8000}$');
  static final _control = RegExp(r'[\u0000-\u001f\u007f]');

  static const _videoRenderers = ['videoRenderer', 'playlistVideoRenderer', 'gridVideoRenderer'];

  /// Entries that are known not to be videos (shelves, ads, "empty" notes).
  static const _placeholders = {'richSectionRenderer', 'adSlotRenderer', 'messageRenderer'};

  static MediaExtractionException _bad(String why) => MediaExtractionException('PARSE_ERROR', why);

  /// The `ytInitialData` object embedded in a page's HTML.
  static Map<String, dynamic> initialData(String html) {
    final marker = RegExp(r'ytInitialData\s*=\s*').firstMatch(html);
    if (marker == null) throw _bad('The page has no initial data.');
    final start = marker.end;
    if (start >= html.length || html[start] != '{') throw _bad('The initial data is not an object.');
    var depth = 0;
    var inString = false;
    for (var i = start; i < html.length; i++) {
      final c = html.codeUnitAt(i);
      if (inString) {
        if (c == 0x5c) {
          i++;
        } else if (c == 0x22) {
          inString = false;
        }
      } else if (c == 0x22) {
        inString = true;
      } else if (c == 0x7b) {
        depth++;
      } else if (c == 0x7d && --depth == 0) {
        return _asMap(_decode(html.substring(start, i + 1)));
      }
    }
    throw _bad('The initial data is cut off.');
  }

  /// `INNERTUBE_CONTEXT_CLIENT_VERSION` of the page, if present.
  static String? clientVersion(String html) =>
      RegExp(r'"INNERTUBE_CONTEXT_CLIENT_VERSION":"([0-9.]{3,40})"').firstMatch(html)?.group(1);

  /// First screen of a channel `/videos` tab or a playlist page, with the
  /// channel id and title (or the playlist title). A channel whose video
  /// grid, or a playlist whose section, is present but has no entries (or
  /// only [_placeholders]) is a valid empty list; a missing container is not.
  static ({String title, String? channelId, YoutubeListPage page}) initial(
    Map<String, dynamic> data, {
    required YoutubeListKind kind,
  }) {
    final channel = kind == YoutubeListKind.channel;
    final meta = _asMap(data['metadata'])[channel ? 'channelMetadataRenderer' : 'playlistMetadataRenderer'];
    if (meta is! Map) throw _bad('The page is not a ${kind.name} page.');
    final tabs = _path(data, ['contents', 'twoColumnBrowseResultsRenderer', 'tabs']);
    if (tabs is! List) throw _bad('The page has no tabs.');
    Map? content;
    for (final t in tabs) {
      final tab = t is Map ? t['tabRenderer'] : null;
      if (tab is Map && tab['selected'] == true && tab['content'] is Map) content = tab['content'] as Map;
    }
    if (content == null) throw _bad('The selected tab has no content.');
    // A channel's Home tab is a section list; only the Videos grid counts.
    final container = content[channel ? 'richGridRenderer' : 'sectionListRenderer'];
    final entries = container is Map ? container['contents'] : null;
    if (entries is! List) throw _bad('The ${channel ? 'channel page is not the Videos tab' : 'playlist has no section list'}.');
    final id = _clean(meta['externalId']);
    if (channel && !_channelIdPattern.hasMatch(id)) throw _bad('The channel page has no valid channel id.');
    return (title: _clean(meta['title']), channelId: id.isEmpty ? null : id, page: _entries(entries));
  }

  /// One browse continuation response. A response with no actions that
  /// carries only the standard envelope keys is the explicit end of a list;
  /// an `error` object is an API failure, not an empty page.
  static YoutubeListPage continuation(Map<String, dynamic> data) {
    if (data['error'] != null) throw _apiError(data['error']);
    final actions = data['onResponseReceivedActions'];
    if (actions == null) {
      final envelope = data['responseContext'] is Map && data.keys.every((k) => k == 'responseContext' || k == 'trackingParams');
      if (envelope) return const YoutubeListPage([], null);
      throw _bad('The continuation has an unknown shape.');
    }
    if (actions is! List || actions.isEmpty) throw _bad('The continuation has no actions.');
    final acc = _Acc();
    for (final a in actions) {
      if (a is! Map || a.keys.any((k) => k != 'clickTrackingParams' && k != 'appendContinuationItemsAction')) {
        throw _bad('The continuation has an unknown action.');
      }
      final append = a['appendContinuationItemsAction'];
      final items = append is Map ? append['continuationItems'] : null;
      if (items is! List) throw _bad('The continuation has no items.');
      _walk(items, acc);
    }
    return acc.page();
  }

  /// The channel RSS feed: newest first, with absolute publish times. It
  /// must be a complete Atom document (so a cut-off download is an error)
  /// whose `yt:channelId` matches [channelId]; a complete feed with no
  /// entries is a legitimate empty list.
  static List<YoutubeListItem> feed(String xml, {String? channelId}) {
    final XmlElement root;
    try {
      root = XmlReader.parse(xml);
    } on FormatException catch (e) {
      throw _bad('The feed is not well-formed (${e.message}).');
    }
    if (root.namespace != _atom || root.name != 'feed') throw _bad('The document is not an Atom feed.');
    final headIds = root.childrenNamed(_yt, 'channelId').toList();
    if (headIds.length != 1) throw _bad('The feed has no single channel id.');
    final feedChannel = headIds.single.text;
    if (channelId != null && feedChannel != channelId && 'UC$feedChannel' != channelId) {
      throw _bad('The feed belongs to another channel.');
    }
    final entries = root.childrenNamed(_atom, 'entry').toList();
    // An entry anywhere else (nested in an entry, say) means the shape is not what we parse.
    if (root.countDescendants(_atom, 'entry') != entries.length) throw _bad('The feed has a misplaced entry.');
    final items = <YoutubeListItem>[];
    for (final e in entries) {
      final ids = e.childrenNamed(_yt, 'videoId').toList();
      final dates = e.childrenNamed(_atom, 'published').toList();
      final time = dates.length == 1 ? DateTime.tryParse(dates.single.text) : null;
      if (ids.length != 1 || !_videoId.hasMatch(ids.single.text) || time == null) throw _bad('A feed entry is malformed.');
      final titles = e.childrenNamed(_atom, 'title').toList();
      items.add(YoutubeListItem(id: ids.single.text, title: _clean(titles.isEmpty ? '' : titles.first.text), published: time.toUtc()));
    }
    return items;
  }

  static const _atom = 'http://www.w3.org/2005/Atom';
  static const _yt = 'http://www.youtube.com/xml/schemas/2015';

  static YoutubeListPage _entries(List entries) {
    final acc = _Acc();
    _walk(entries, acc);
    return acc.page();
  }

  static void _walk(List entries, _Acc acc) {
    for (final e in entries) {
      if (e is! Map || e.length != 1) throw _bad('A list entry has an unexpected shape.');
      final key = e.keys.single as String;
      final value = e[key];
      if (key == 'richItemRenderer') {
        final content = value is Map ? value['content'] : null;
        if (content is! Map || content.length != 1) throw _bad('A grid item has an unexpected shape.');
        _item(content, acc);
      } else if (key == 'lockupViewModel' || key == 'shortsLockupViewModel' || _videoRenderers.contains(key)) {
        _item(e, acc);
      } else if (key == 'itemSectionRenderer') {
        final inner = value is Map ? value['contents'] : null;
        if (inner is! List) throw _bad('A section has no entries.');
        _walk(inner, acc);
      } else if (key == 'continuationItemRenderer') {
        acc.token(_path(value, ['continuationEndpoint', 'continuationCommand', 'token']));
      } else if (key == 'continuationItemViewModel') {
        acc.token(_path(value, ['continuationCommand', 'innertubeCommand', 'continuationCommand', 'token']));
      } else if (!_placeholders.contains(key)) {
        throw _bad('Unrecognized list entry "${RegExp(r'^[A-Za-z]{1,40}$').hasMatch(key) ? key : '?'}".');
      }
    }
  }

  static void _item(Map holder, _Acc acc) {
    final key = holder.keys.single as String;
    final r = holder[key];
    if (r is! Map) throw _bad('A video entry is not an object.');
    String? id;
    var title = '';
    if (key == 'lockupViewModel') {
      if (r['contentType'] != 'LOCKUP_CONTENT_TYPE_VIDEO') throw _bad('A list entry is not a video.');
      id = _str(r['contentId']);
      title = _clean(_path(r, ['metadata', 'lockupMetadataViewModel', 'title', 'content']));
    } else if (key == 'shortsLockupViewModel') {
      id = _str(_path(r, ['onTap', 'innertubeCommand', 'reelWatchEndpoint', 'videoId']));
      title = _clean(_path(r, ['overlayMetadata', 'primaryText', 'content']));
    } else {
      id = _str(r['videoId']);
      title = _clean(_text(r['title']));
    }
    if (id == null || !_videoId.hasMatch(id)) throw _bad('A video entry has an invalid id.');
    acc.items.add(YoutubeListItem(id: id, title: title));
  }

  static MediaExtractionException _apiError(Object? error) {
    final code = error is Map && error['code'] is int ? error['code'] as int : 0;
    if (code == 429) return const MediaExtractionException('RATE_LIMITED', 'YouTube is rate limiting this client.');
    if (code == 404) return const MediaExtractionException('NOT_FOUND', 'YouTube has no such list.');
    if (code >= 500) return MediaExtractionException('NETWORK', 'YouTube failed to answer (code $code).');
    return MediaExtractionException('PARSE_ERROR', 'YouTube rejected the browse request (code $code).');
  }

  static String? _str(Object? v) => v is String ? v : null;

  static Object? _text(Object? title) {
    if (title is! Map) return null;
    final runs = title['runs'];
    if (runs is List && runs.isNotEmpty && runs.first is Map) return (runs.first as Map)['text'];
    return title['simpleText'];
  }

  static Object? _path(Object? node, List<String> keys) {
    for (final k in keys) {
      if (node is! Map) return null;
      node = node[k];
    }
    return node;
  }

  static Object? _decode(String json) {
    try {
      return jsonDecode(json);
    } on FormatException {
      throw _bad('The page data is not valid JSON.');
    }
  }

  static Map<String, dynamic> _asMap(Object? v) {
    if (v is Map) return v.cast<String, dynamic>();
    throw _bad('Expected an object.');
  }

  /// Page text without control characters, capped so one hostile title
  /// cannot flood a log line.
  static String _clean(Object? v) {
    if (v is! String) return '';
    final s = v.replaceAll(_control, ' ').trim();
    return s.length > 300 ? s.substring(0, 300) : s;
  }
}

class _Acc {
  final items = <YoutubeListItem>[];
  final _tokens = <String>{};

  /// A continuation token must look like one; a page with two different
  /// tokens is ambiguous and refused.
  void token(Object? t) {
    if (t is! String || !YoutubeListParser._tokenPattern.hasMatch(t)) {
      throw YoutubeListParser._bad('A continuation token is malformed.');
    }
    _tokens.add(t);
  }

  YoutubeListPage page() {
    if (_tokens.length > 1) throw YoutubeListParser._bad('The page has more than one continuation.');
    return YoutubeListPage(items, _tokens.isEmpty ? null : _tokens.single);
  }
}
