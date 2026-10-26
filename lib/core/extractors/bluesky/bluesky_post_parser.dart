import '../media_models.dart';
import '../native_http/native_text.dart';

/// The video of one post, as the AppView describes it.
class BlueskyVideo {
  /// HLS master playlist (`https://video.bsky.app/watch/<did>/<cid>/playlist.m3u8`).
  final String playlistUrl;
  final String? thumbnailUrl;

  const BlueskyVideo({required this.playlistUrl, this.thumbnailUrl});
}

/// The post that was asked for. [video] is null for a post without one.
class BlueskyPost {
  final String? author;
  final String handle;
  final String? text;
  final BlueskyVideo? video;

  const BlueskyPost({this.author, required this.handle, this.text, this.video});
}

/// Reads the `app.bsky.feed.getPostThread` answer (depth 0).
///
/// Only the requested post itself is read: `thread.post.uri` must equal the
/// `at://` URI that was asked for, and only that post's own `embed` is
/// considered (a quoted post or a reply, which live elsewhere in the tree,
/// are never looked at). The embed is either `app.bsky.embed.video#view` or
/// the `media` half of `app.bsky.embed.recordWithMedia#view`.
class BlueskyPostParser {
  const BlueskyPostParser();

  // Exact lexicon identifiers; a look-alike such as `x.evil#blockedPost` or
  // `...#threadViewPostX` is not one of these and is a PARSE_ERROR.
  static const String _threadViewPost = 'app.bsky.feed.defs#threadViewPost';
  static const String _notFoundPost = 'app.bsky.feed.defs#notFoundPost';
  static const String _blockedPost = 'app.bsky.feed.defs#blockedPost';

  static const String _videoView ='app.bsky.embed.video#view';
  static const String _recordWithMediaView = 'app.bsky.embed.recordWithMedia#view';

  /// Authors can opt out of being shown to signed-out viewers with this
  /// self-label; the public AppView still returns the post, labeled.
  static const String _signedInOnlyLabel = '!no-unauthenticated';

  BlueskyPost parse(Map<String, dynamic> json, {required String expectedUri}) {
    final thread = NativeText.asMap(json['thread']);
    final type = thread?[r'$type'];
    if (thread == null || type is! String) {
      throw const MediaExtractionException(
        'PARSE_ERROR',
        'Bluesky returned a thread MiDa does not recognize; trying another method.',
      );
    }
    if (type == _notFoundPost) {
      throw const MediaExtractionException('NOT_FOUND', 'This Bluesky post was not found. It may have been deleted.');
    }
    if (type == _blockedPost) {
      // A block is an access restriction between accounts, not evidence the
      // post is gone. LOGIN_REQUIRED is the non-terminal access status: the
      // registry still offers the URL to the browser tier, where the user's
      // own signed-in session (a different viewer relationship) may see it.
      throw const MediaExtractionException(
        'LOGIN_REQUIRED',
        'Bluesky reports this post as blocked for the public viewer. It exists but is not visible without '
            'signing in; MiDa does not sign in to Bluesky.',
      );
    }
    final post = NativeText.asMap(thread['post']);
    if (type != _threadViewPost || post == null || post['uri'] != expectedUri) {
      throw const MediaExtractionException(
        'PARSE_ERROR',
        'Bluesky returned a different post than the one asked for; trying another method.',
      );
    }

    final author = NativeText.asMap(post['author']);
    if (_hasSignedInOnlyLabel(post['labels']) || _hasSignedInOnlyLabel(author?['labels'])) {
      throw const MediaExtractionException(
        'LOGIN_REQUIRED',
        'This Bluesky account only shows its posts to signed-in users. MiDa does not sign in to Bluesky.',
      );
    }

    final record = NativeText.asMap(post['record']);
    return BlueskyPost(
      author: NativeText.nonEmpty(author?['displayName']),
      handle: NativeText.nonEmpty(author?['handle']) ?? 'unknown',
      text: NativeText.nonEmpty(record?['text']),
      video: _video(NativeText.asMap(post['embed'])),
    );
  }

  static BlueskyVideo? _video(Map<String, dynamic>? embed) {
    if (embed == null) return null;
    final type = embed[r'$type'];
    final view = type == _recordWithMediaView ? NativeText.asMap(embed['media']) : embed;
    if (view == null || view[r'$type'] != _videoView) return null;

    final playlist = NativeText.httpsUrl(view['playlist']);
    if (playlist == null) return null;
    return BlueskyVideo(
      playlistUrl: playlist,
      thumbnailUrl: NativeText.httpsUrl(view['thumbnail']),
    );
  }

  static bool _hasSignedInOnlyLabel(Object? labels) {
    for (final label in NativeText.asList(labels)) {
      final map = NativeText.asMap(label);
      if (map != null && map['val'] == _signedInOnlyLabel) return true;
    }
    return false;
  }
}
