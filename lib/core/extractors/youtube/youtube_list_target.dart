import 'youtube_list_models.dart';

/// What a channel or playlist URL points at, and the one page to fetch for it.
class YoutubeListTarget {
  final YoutubeListKind kind;

  /// The page whose first screen is parsed: `<channel>/videos` or
  /// `/playlist?list=ID`. Always https on www.youtube.com.
  final Uri pageUrl;

  /// Set for a `/channel/UC...` URL and for a playlist (its `list` id).
  final String? id;

  const YoutubeListTarget(this.kind, this.pageUrl, {this.id});

  /// The channel id when the URL itself carries it (`/channel/UC...`).
  String? get channelId => kind == YoutubeListKind.channel ? id : null;

  /// Recognises channel and playlist URLs; null for everything else
  /// (single videos, other hosts, other channel tabs, mixes, private lists).
  static YoutubeListTarget? parse(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null || !(uri.scheme == 'https' || uri.scheme == 'http')) return null;
    if (uri.userInfo.isNotEmpty || (uri.hasPort && uri.port != 443 && uri.port != 80)) return null;
    final host = uri.host.toLowerCase();
    if (host == 'youtu.be') return _playlist(uri.queryParameters['list']);
    if (host != 'youtube.com' && host != 'www.youtube.com' && host != 'm.youtube.com') return null;

    final segs = [for (final s in uri.pathSegments) if (s.isNotEmpty) s];
    if (segs.isEmpty) return null;
    if (segs.first == 'playlist' || segs.first == 'watch') {
      if (segs.length != 1) return null;
      return _playlist(uri.queryParameters['list']);
    }
    if (segs.first.startsWith('@')) return _channel(segs, 0, '@', segs.first.substring(1));
    if (segs.length >= 2 && (segs.first == 'c' || segs.first == 'user')) {
      return _channel(segs, 1, '${segs.first}/', segs[1]);
    }
    if (segs.length >= 2 && segs.first == 'channel') {
      if (!_channelId.hasMatch(segs[1])) return null;
      return _channel(segs, 1, 'channel/', segs[1], id: segs[1]);
    }
    return null;
  }

  static final _channelId = RegExp(r'^UC[A-Za-z0-9_-]{22}$');
  static final _name = RegExp(r'^[^\s/?#\\]{1,100}$');
  // PL user list, UU uploads, OLAK5uy_ album, FL favourites. RD mixes and
  // WL/LL private lists are not browsable and are refused.
  static final _listId = RegExp(r'^(PL|UU|FL|OLAK5uy_)[A-Za-z0-9_-]{8,64}$');

  static YoutubeListTarget? _channel(List<String> segs, int nameIndex, String prefix, String name, {String? id}) {
    if (!_name.hasMatch(name)) return null;
    final rest = segs.sublist(nameIndex + 1);
    if (rest.isNotEmpty && !(rest.length == 1 && rest.first == 'videos')) return null;
    final path = '/$prefix${Uri.encodeComponent(name)}/videos';
    return YoutubeListTarget(YoutubeListKind.channel, Uri.parse('https://www.youtube.com$path'), id: id);
  }

  static YoutubeListTarget? _playlist(String? list) {
    if (list == null || !_listId.hasMatch(list)) return null;
    return YoutubeListTarget(
      YoutubeListKind.playlist,
      Uri.https('www.youtube.com', '/playlist', {'list': list}),
      id: list,
    );
  }
}
