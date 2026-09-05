import '../media_models.dart';

/// The pieces of a Reddit post JSON listing entry
/// (`www.reddit.com/r/<sub>/comments/<id>/.json`) [RedditPostParser] reads
/// out, before the DASH manifest (a second HTTP fetch,
/// [RedditDashManifestParser]) is resolved into actual [MediaFormat]s.
typedef RedditVideoInfo = ({
  String id,
  String title,
  String? author,
  String? thumbnailUrl,
  Duration? duration,
  String? dashUrl,
  String? hlsUrl,
  String? fallbackUrl,
});

/// Pure JSON -> [RedditVideoInfo] mapping for a Reddit post listing
/// response. Kept free of any I/O so it can be exercised entirely against
/// `test/fixtures/reddit_post_listing.json`.
///
/// Reddit's public `.json` API is unauthenticated and has been the stable
/// public contract every third-party Reddit client/downloader reads for
/// over a decade: `[0].data.children[0].data` is the post itself, and a
/// video post's `secure_media.reddit_video` (falling back to the
/// unprefixed `media.reddit_video` some older responses used) carries
/// `dash_url`/`hls_url`/`fallback_url` all rooted at `v.redd.it/<id>/`.
class RedditPostParser {
  const RedditPostParser();

  /// Throws [MediaExtractionException]: `NOT_FOUND` for an empty/missing
  /// listing (deleted post or bad id), and `UNSUPPORTED_MEDIA` for a post
  /// that is not a video at all (text/image/link post - no
  /// `secure_media.reddit_video`/`media.reddit_video`, including via a
  /// crosspost parent).
  ///
  /// `NOT_FOUND` here is intentionally still terminal (unlike the
  /// anti-bot-adjacent cases `BilibiliPageParser`/`DouyinRenderDataParser`/
  /// `NiconicoWatchDataParser` downgraded to fall-through eligible
  /// statuses): this parser only ever runs on a body `RedditExtractor`
  /// already confirmed was HTTP 200 and valid JSON, and this pass's live
  /// testing found Reddit's anti-bot block (3 hosts tried:
  /// `www.reddit.com`, `old.reddit.com`, `api.reddit.com`) always serves
  /// an HTML challenge shell with a non-200/non-JSON body, caught earlier
  /// by `RedditExtractor` as `CHALLENGE_FAILED`/`PARSE_ERROR` before this
  /// parser is ever reached - so by the time an empty listing gets here,
  /// there is no observed anti-bot path that produces it.
  RedditVideoInfo parse(dynamic json) {
    final listing = json is List && json.isNotEmpty ? json.first : null;
    final listingData = listing is Map ? listing['data'] : null;
    final children = listingData is Map ? listingData['children'] : null;
    final firstChild = children is List && children.isNotEmpty ? children.first : null;
    final post = firstChild is Map ? firstChild['data'] : null;

    if (post is! Map) {
      throw const MediaExtractionException(
        'NOT_FOUND',
        'This Reddit post no longer exists or the link is wrong.',
      );
    }

    final redditVideo = _redditVideoNode(post);
    if (redditVideo == null) {
      throw const MediaExtractionException(
        'UNSUPPORTED_MEDIA',
        'This Reddit post has no attached video (it looks like a text, '
            'image, or link post).',
      );
    }

    return (
      id: post['id'] as String? ?? '',
      title: post['title'] as String? ?? 'Untitled',
      author: post['author'] as String?,
      thumbnailUrl: _thumbnailUrl(post['thumbnail']),
      duration: _durationFromSeconds(redditVideo['duration']),
      dashUrl: redditVideo['dash_url'] as String?,
      hlsUrl: redditVideo['hls_url'] as String?,
      fallbackUrl: redditVideo['fallback_url'] as String?,
    );
  }

  Map? _redditVideoNode(Map post) {
    final secureMedia = post['secure_media'];
    if (secureMedia is Map && secureMedia['reddit_video'] is Map) {
      return secureMedia['reddit_video'] as Map;
    }
    final media = post['media'];
    if (media is Map && media['reddit_video'] is Map) return media['reddit_video'] as Map;

    // Crossposted video: the video lives on the crosspost parent, not
    // this post's own (absent) media node.
    final crosspostParents = post['crosspost_parent_list'];
    if (crosspostParents is List && crosspostParents.isNotEmpty) {
      return _redditVideoNode(crosspostParents.first as Map);
    }
    return null;
  }

  String? _thumbnailUrl(dynamic raw) {
    if (raw is! String) return null;
    // Reddit uses sentinel strings ("self", "default", "nsfw", "spoiler")
    // instead of omitting the field when there is no real thumbnail.
    if (raw.isEmpty || !raw.startsWith('http')) return null;
    return raw;
  }

  Duration? _durationFromSeconds(dynamic raw) {
    if (raw is int) return Duration(seconds: raw);
    if (raw is num) return Duration(seconds: raw.toInt());
    return null;
  }
}
