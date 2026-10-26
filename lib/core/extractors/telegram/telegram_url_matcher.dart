/// What [TelegramUrlMatcher.match] recognized: the public channel username
/// and the numeric post id, both already validated, so building the embed
/// URL from them cannot smuggle anything into the path or query.
class TelegramPostRef {
  final String channel;
  final String postId;

  const TelegramPostRef({required this.channel, required this.postId});

  /// `channel/id`, the value of the embed page's own `data-post` attribute.
  String get dataPost => '$channel/$postId';

  /// The endpoint Telegram's own post-embed widget loads in its iframe.
  Uri get embedUrl => Uri.https('t.me', '/$channel/$postId', {'embed': '1', 'mode': 'tme'});
}

/// Pure, network-free URL recognition for the Telegram extractor.
///
/// Supported shapes (anything else is left to the generic and browser tiers):
/// - `t.me/<channel>/<id>`
/// - `t.me/s/<channel>/<id>` (the web preview form)
/// - the same on `www.t.me`, `telegram.me` and `telegram.dog`
///
/// `t.me/c/<numeric>/<id>` (private-channel links), `t.me/+invite` and
/// `t.me/<bot>?start=` never match: they have no public embed.
class TelegramUrlMatcher {
  const TelegramUrlMatcher._();

  static const Set<String> _hosts = {'t.me', 'www.t.me', 'telegram.me', 'www.telegram.me', 'telegram.dog'};

  /// Telegram usernames: a letter first, then letters, digits and
  /// underscores, 5 to 32 characters (4 accepted here for old channels).
  static final RegExp _channel = RegExp(r'^[A-Za-z][A-Za-z0-9_]{3,31}$');
  static final RegExp _postId = RegExp(r'^[1-9][0-9]{0,11}$');

  /// Path segments that are Telegram routes, never channel usernames.
  static const Set<String> _reserved = {'c', 's', 'joinchat', 'addstickers', 'share', 'proxy', 'socks', 'login'};

  /// True for the hosts a Telegram request may stay on (redirect allow-list).
  static bool isTelegramHost(Uri url) => _hosts.contains(url.host.toLowerCase());

  static TelegramPostRef? match(Uri url) {
    final scheme = url.scheme.toLowerCase();
    if (scheme != 'https' && scheme != 'http') return null;
    if (!_hosts.contains(url.host.toLowerCase())) return null;

    final List<String> raw;
    try {
      raw = url.pathSegments;
    } on FormatException {
      return null; // `%FF` and other undecodable bytes: not a post URL
    }
    var segments = raw;
    if (segments.isNotEmpty && segments.last.isEmpty) segments = segments.sublist(0, segments.length - 1);
    if (segments.length == 3 && segments.first == 's') segments = segments.sublist(1);
    if (segments.length != 2) return null;

    final channel = segments[0];
    final postId = segments[1];
    if (!_channel.hasMatch(channel) || _reserved.contains(channel.toLowerCase())) return null;
    if (!_postId.hasMatch(postId)) return null;
    return TelegramPostRef(channel: channel, postId: postId);
  }
}
