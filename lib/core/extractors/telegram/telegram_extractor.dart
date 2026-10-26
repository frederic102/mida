import '../media_extractor.dart';
import '../media_models.dart';
import '../native_http/native_host_list.dart';
import '../native_http/native_http_client.dart';
import '../native_http/native_text.dart';
import 'telegram_embed_parser.dart';
import 'telegram_url_matcher.dart';

/// Native extractor for videos in public Telegram channel posts
/// (`t.me/<channel>/<id>`, `t.me/s/<channel>/<id>`; see [TelegramUrlMatcher]).
///
/// Technique, per `docs/supported-sites.md` Policy: the one plain HTTPS GET
/// Telegram's own "Embed post" widget makes,
/// `https://t.me/<channel>/<id>?embed=1&mode=tme`, then reading the
/// `<video src>` the widget renders ([TelegramEmbedParser]). No cookies, no
/// Telegram API or login, no MTProto.
///
/// Several videos: a post that is part of an album lists every member's
/// player in one embed. Only the player whose own link names the requested
/// `channel/id` is returned; when the embed carries no per-player link (the
/// usual single-video post) its single/first player is used. A post with two
/// videos therefore yields the first one. The title and caption are only
/// used when the embed's `data-post` is the requested post.
///
/// Outcomes:
/// - video found -> [MediaInfo] (one muxed-unknown mp4 format).
/// - Telegram's "Post not found" box, or HTTP 404/410 -> `NOT_FOUND`.
/// - a landing page instead of a message (private channel, web preview
///   disabled, nonexistent channel) -> `LOGIN_REQUIRED`.
/// - a message without a playable `<video src>` (text/photo post, or a
///   player Telegram renders without a source because the file is too large
///   for the web widget) -> `NO_MEDIA_FOUND`.
/// - HTTP 429 -> `RATE_LIMITED`; 401/403 -> `CHALLENGE_FAILED`; unrecognized
///   page -> `PARSE_ERROR`; network -> `NETWORK`.
class TelegramExtractor implements MediaExtractor {
  static const Map<String, String> _downloadHeaders = {'User-Agent': NativeHttpClient.userAgent};

  /// Where Telegram media may live (`cdn1.cdn-telegram.org`, `cdn4.telesco.pe`,
  /// `*.telegram-cdn.org`, Telegram's own hosts). The embed page naming a file
  /// anywhere else gets no request and no format.
  static const NativeHostList _mediaHosts =
      NativeHostList(['cdn-telegram.org', 'telesco.pe', 'telegram-cdn.org', 'telegram.org', 't.me']);

  final NativeHttpClient _http;
  final TelegramEmbedParser _parser;

  TelegramExtractor({NativeHttpClient? httpClient, TelegramEmbedParser? parser})
      : _http = (httpClient ?? NativeHttpClient(service: 'Telegram')).withMediaHosts(_mediaHosts),
        _parser = parser ?? const TelegramEmbedParser();

  @override
  bool canHandle(Uri url) => TelegramUrlMatcher.match(url) != null;

  @override
  Future<MediaInfo> extract(Uri url) async {
    final ref = TelegramUrlMatcher.match(url);
    if (ref == null) {
      throw const MediaExtractionException('UNSUPPORTED_URL', 'Not a recognizable public Telegram post URL.');
    }

    final response = await _http.get(ref.embedUrl, acceptHop: TelegramUrlMatcher.isTelegramHost);
    NativeHttpClient.throwForStatus(response.statusCode, 'Telegram');
    final embed = _parser.parse(response.body);

    switch (embed.state) {
      case TelegramEmbedState.notFound:
        throw const MediaExtractionException(
          'NOT_FOUND',
          'This Telegram post was not found. It may have been deleted or the link is wrong.',
        );
      case TelegramEmbedState.restricted:
        throw const MediaExtractionException(
          'LOGIN_REQUIRED',
          'Telegram says this channel is private. MiDa does not sign in to Telegram.',
        );
      case TelegramEmbedState.noPreview:
        throw const MediaExtractionException(
          'CHALLENGE_FAILED',
          'Telegram showed a channel page instead of the post (no such channel, web preview disabled, or '
              'a restriction); trying another method.',
        );
      case TelegramEmbedState.unknown:
        throw MediaExtractionException(
          'PARSE_ERROR',
          'MiDa could not read this Telegram embed page'
          '${response.truncated ? ' (page larger than the read limit)' : ''}; trying another method.',
        );
      case TelegramEmbedState.post:
        break;
    }

    final picked = _pick(embed, ref);
    if (picked == null) {
      final own = _ownMessage(embed, ref);
      throw MediaExtractionException(
        'NO_MEDIA_FOUND',
        own != null && own.hasVideoPlayerWithoutSource
            ? 'Telegram shows a video player for this post but gives the web widget no file to play '
                '(usually a file too large for the embed).'
            : 'This Telegram post has no video the embed widget can play.',
      );
    }
    final (message, video) = picked;
    if (!_http.mediaUrlAllowed(video.url)) {
      throw const MediaExtractionException(
        'PARSE_ERROR',
        'The Telegram embed pointed at a video host MiDa does not trust; trying another method.',
      );
    }

    final caption = message.dataPost.toLowerCase() == ref.dataPost.toLowerCase() ? message.text : null;
    final id = '${ref.channel}_${ref.postId}';
    return MediaInfo(
      id: id,
      title: caption == null ? 'Telegram video ${ref.dataPost}' : NativeText.clip(caption, 100),
      author: message.author,
      thumbnailUrl: video.thumbnailUrl != null && _http.mediaUrlAllowed(video.thumbnailUrl!) ? video.thumbnailUrl : null,
      duration: video.duration,
      formats: [
        MediaFormat(
          id: 'mp4',
          url: video.url,
          container: 'mp4',
          hasVideo: true,
          hasAudio: true,
          capabilitiesUnknown: true,
        ),
      ],
      sourceUrl: url,
      requestHeaders: _downloadHeaders,
    );
  }

  static TelegramMessage? _ownMessage(TelegramEmbed embed, TelegramPostRef ref) {
    final wanted = ref.dataPost.toLowerCase();
    for (final message in embed.messages) {
      if (message.dataPost.toLowerCase() == wanted) return message;
    }
    return null;
  }

  /// The player that belongs to the requested post, with the message
  /// container it was read from; never a sibling's or a neighbour's.
  ///
  /// 1. A player whose own link names the requested `channel/id` (an album
  ///    member), wherever its container is.
  /// 2. Otherwise the requested message's own container, and only when it
  ///    holds exactly one player and that player is unlinked (a plain
  ///    single-video post). With several players, or a player linked to
  ///    another post, ownership is ambiguous and nothing is returned.
  static (TelegramMessage, TelegramEmbedVideo)? _pick(TelegramEmbed embed, TelegramPostRef ref) {
    final wanted = ref.dataPost.toLowerCase();
    for (final message in embed.messages) {
      for (final video in message.videos) {
        if (video.linkedPost?.toLowerCase() == wanted) return (message, video);
      }
    }
    final own = _ownMessage(embed, ref);
    if (own != null && own.playerCount == 1 && own.videos.length == 1 && own.videos.single.linkedPost == null) {
      return (own, own.videos.single);
    }
    return null;
  }
}
