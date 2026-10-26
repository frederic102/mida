import '../native_http/native_text.dart';

/// What the embed page says about the requested post.
enum TelegramEmbedState {
  /// A rendered message (`data-post` present).
  post,

  /// Telegram's own "Post not found" error box.
  notFound,

  /// The embed widget refused: a Telegram landing page instead of a message
  /// (private channel, preview disabled, nonexistent channel) or an error
  /// box naming a restriction.
  restricted,

  /// A landing page (or a restriction box that does not say "private")
  /// instead of a message: nonexistent channel, web preview disabled, or a
  /// wall. Not proof of an account wall, so it falls through to other tiers.
  noPreview,

  /// Neither of the above; the page shape is not one this parser knows.
  unknown,
}

/// One `<video>` player found in the embed page.
class TelegramEmbedVideo {
  final String url;
  final String? thumbnailUrl;
  final Duration? duration;

  /// `channel/id` taken from the player's own link (`href`), when it has
  /// one. A grouped album lists several players, each linking to its own
  /// message; this is how the requested one is told apart from its siblings.
  final String? linkedPost;

  const TelegramEmbedVideo({required this.url, this.thumbnailUrl, this.duration, this.linkedPost});
}

/// One message container: everything from its own `data-post` element up to
/// the next message's. Players, caption and author are read only from that
/// span, so nothing is ever attached to a neighbouring message.
class TelegramMessage {
  /// `channel/id` from the container's `data-post`.
  final String dataPost;
  final String? author;
  final String? text;
  final List<TelegramEmbedVideo> videos;
  final bool hasVideoPlayerWithoutSource;

  /// Number of video players in the container, with or without a source.
  final int playerCount;

  const TelegramMessage({
    required this.dataPost,
    this.author,
    this.text,
    this.videos = const [],
    this.hasVideoPlayerWithoutSource = false,
    this.playerCount = 0,
  });
}

/// Everything read from one embed page: the state and, for a rendered page,
/// each message container separately (never merged).
class TelegramEmbed {
  final TelegramEmbedState state;
  final List<TelegramMessage> messages;

  const TelegramEmbed({required this.state, this.messages = const []});
}

/// Reads the HTML of `https://t.me/<channel>/<id>?embed=1&mode=tme`, the
/// iframe Telegram's own "Embed post" widget loads. Regex based on purpose:
/// the markup is Telegram's stable server-rendered widget, not a document
/// worth a full HTML parser, and every capture is length-bounded by the
/// 5 MiB body cap upstream.
class TelegramEmbedParser {
  const TelegramEmbedParser();

  static final RegExp _dataPost = RegExp(r'''\bdata-post\s*=\s*["']([^"']+)["']''');
  static final RegExp _errorBox = RegExp(
    r'<div\b[^>]*\bclass="[^"]*\btgme_widget_message_error\b[^"]*"[^>]*>(.*?)</div>',
    dotAll: true,
  );
  static final RegExp _player = RegExp(
    r'<a\b([^>]*\bclass="[^"]*\btgme_widget_message_(?:round)?video_player\b[^"]*"[^>]*)>(.*?)</a>',
    dotAll: true,
  );
  static final RegExp _videoTag = RegExp(r'<video\b[^>]*>', caseSensitive: false);
  static final RegExp _backgroundImage = RegExp(r'''background-image\s*:\s*url\(\s*['"]?([^'")]+?)['"]?\s*\)''');
  static final RegExp _timeTag = RegExp(r'<time\b[^>]*>([^<]*)</time>');
  static final RegExp _textBox = RegExp(
    r'<div\b[^>]*\bclass="[^"]*\btgme_widget_message_text\b[^"]*"[^>]*>(.*?)</div>',
    dotAll: true,
  );
  static final RegExp _ownerName = RegExp(
    r'<a\b[^>]*\bclass="[^"]*\btgme_widget_message_owner_name\b[^"]*"[^>]*>(.*?)</a>',
    dotAll: true,
  );
  static final RegExp _linkedPost = RegExp(r'^https?://(?:www\.)?(?:t|telegram)\.(?:me|dog)/(?:s/)?([A-Za-z0-9_]+/[0-9]+)(?:[/?#].*)?$');
  static final RegExp _clock = RegExp(r'^(?:(\d{1,2}):)?(\d{1,2}):(\d{2})$');
  static final RegExp _explicitPrivate = RegExp(r'\b(?:channel|group) is private\b|\bprivate (?:channel|group)\b', caseSensitive: false);
  static final RegExp _restrictedWords = RegExp(r'private|restrict|sensitive|\bage\b|join|subscribe|unavailable', caseSensitive: false);

  TelegramEmbed parse(String html) {
    final starts = _messageStarts(html);
    final error = _errorBox.firstMatch(html);
    if (starts.isEmpty) {
      if (error != null) {
        final reason = _plain(error.group(1)!);
        if (RegExp(r'not found|does not exist', caseSensitive: false).hasMatch(reason)) {
          return const TelegramEmbed(state: TelegramEmbedState.notFound);
        }
        if (_explicitPrivate.hasMatch(reason)) return const TelegramEmbed(state: TelegramEmbedState.restricted);
        if (_restrictedWords.hasMatch(reason)) return const TelegramEmbed(state: TelegramEmbedState.noPreview);
        return const TelegramEmbed(state: TelegramEmbedState.unknown);
      }
      if (html.contains('tgme_page')) {
        // A channel landing page is what Telegram serves for a nonexistent
        // channel, a channel with web preview off and a private one alike;
        // only explicit wording proves "private".
        final landing = _plain(html);
        return TelegramEmbed(
          state: _explicitPrivate.hasMatch(landing) ? TelegramEmbedState.restricted : TelegramEmbedState.noPreview,
        );
      }
      return const TelegramEmbed(state: TelegramEmbedState.unknown);
    }

    final messages = <TelegramMessage>[];
    for (var i = 0; i < starts.length; i++) {
      final fallbackEnd = i + 1 < starts.length ? starts[i + 1].$1 : html.length;
      final end = _elementEnd(html, starts[i].$1, fallbackEnd);
      messages.add(_message(NativeText.decodeEntities(starts[i].$2), html.substring(starts[i].$1, end)));
    }
    return TelegramEmbed(state: TelegramEmbedState.post, messages: messages);
  }

  static final RegExp _tagToken = RegExp(
    r'(<!--.*?-->)|<(script|style)\b[^>]*>.*?</\2\s*>|<(/?)([a-zA-Z][a-zA-Z0-9]*)\b[^>]*?(/?)>',
    dotAll: true,
    caseSensitive: false,
  );
  static const Set<String> _voidTags = {'br', 'img', 'hr', 'input', 'meta', 'link', 'source', 'wbr', 'area', 'col'};

  /// `(offset of the attribute, value)` for each `data-post` on a real opening
  /// tag; comments and script/style bodies are skipped like in [_elementEnd].
  static List<(int, String)> _messageStarts(String html) {
    final found = <(int, String)>[];
    for (final m in _tagToken.allMatches(html)) {
      if (m.group(1) != null || m.group(2) != null || m.group(3) == '/') continue;
      final attr = _dataPost.firstMatch(m.group(0)!);
      if (attr != null) found.add((m.start + attr.start, attr.group(1)!));
    }
    return found;
  }

  /// End offset of the element that carries the `data-post` at [attrPos]:
  /// tracks tag depth from that element's start tag to its matching close, so
  /// markup after the message's own closing tag is never its content.
  /// shortcut: ignores `>` inside attribute values and unclosed non-void tags;
  /// on a never-closing element it falls back to [fallbackEnd].
  static int _elementEnd(String html, int attrPos, int fallbackEnd) {
    final open = html.lastIndexOf('<', attrPos);
    if (open < 0) return fallbackEnd;
    var depth = 0;
    for (final m in _tagToken.allMatches(html, open)) {
      if (m.start >= fallbackEnd) break;
      // Comments and script/style bodies are not structure: skip them whole.
      if (m.group(1) != null || m.group(2) != null) continue;
      final name = m.group(4)!.toLowerCase();
      if (m.group(5) == '/' || _voidTags.contains(name)) continue;
      depth += m.group(3) == '/' ? -1 : 1;
      if (depth == 0) return m.end;
    }
    return fallbackEnd;
  }

  static TelegramMessage _message(String dataPost, String span) {
    final videos = <TelegramEmbedVideo>[];
    var players = 0;
    var sourceless = false;
    for (final match in _player.allMatches(span)) {
      players++;
      final video = _video(match.group(1)!, match.group(2)!);
      if (video == null) {
        sourceless = true;
      } else {
        videos.add(video);
      }
    }
    final text = _textBox.firstMatch(span)?.group(1);
    final owner = _ownerName.firstMatch(span)?.group(1);
    return TelegramMessage(
      dataPost: dataPost,
      author: owner == null ? null : NativeText.nonEmpty(_plain(owner)),
      text: text == null ? null : NativeText.nonEmpty(_plain(text.replaceAll(RegExp(r'<br\s*/?>'), ' '))),
      videos: videos,
      hasVideoPlayerWithoutSource: sourceless,
      playerCount: players,
    );
  }

  static TelegramEmbedVideo? _video(String anchorAttributes, String inner) {
    final tag = _videoTag.firstMatch(inner)?.group(0);
    final url = tag == null ? null : NativeText.httpsUrl(NativeText.attributes(tag)['src']);
    if (url == null) return null;

    final href = NativeText.attributes('<a $anchorAttributes>')['href'];
    final linked = href == null ? null : _linkedPost.firstMatch(href)?.group(1);
    final thumb = _backgroundImage.firstMatch(inner)?.group(1);
    final clock = _timeTag.firstMatch(inner)?.group(1);
    return TelegramEmbedVideo(
      url: url,
      thumbnailUrl: thumb == null ? null : NativeText.httpsUrl(NativeText.decodeEntities(thumb)),
      duration: clock == null ? null : _duration(clock.trim()),
      linkedPost: linked,
    );
  }

  /// `0:23`, `12:05` or `1:02:03` -> Duration; anything else null.
  static Duration? _duration(String clock) {
    final m = _clock.firstMatch(clock);
    if (m == null) return null;
    final hours = int.parse(m.group(1) ?? '0');
    final minutes = int.parse(m.group(2)!);
    final seconds = int.parse(m.group(3)!);
    if (seconds > 59) return null;
    return Duration(hours: hours, minutes: minutes, seconds: seconds);
  }
}

final RegExp _anyTag = RegExp(r'<[^>]*>');
final RegExp _whitespace = RegExp(r'\s+');

/// Tags removed, entities decoded, whitespace collapsed.
String _plain(String html) => NativeText.decodeEntities(html.replaceAll(_anyTag, ' ')).replaceAll(_whitespace, ' ').trim();
