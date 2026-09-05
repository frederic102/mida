/// One media URL found while walking a decoded inline-JSON blob
/// (`__NEXT_DATA__`, `window.__INITIAL_STATE__`, a Video.js `data-setup`
/// config, etc), plus whatever resolution/bitrate metadata sat in the same
/// JSON object. [url] is exactly as written in the JSON (may be relative or
/// protocol-relative; `jsonDecode` has already unescaped any `\/`/`\uXXXX`)
/// - resolving/classifying it against the page URL and filtering DRM
/// markers is the caller's job (`HtmlMediaSniffer`), same as every other
/// candidate source, so nothing here bypasses those existing guards.
///
/// [contextBacked] is the false-positive guard (security follow-up): true
/// only when this candidate sat next to player-shaped metadata (a
/// width/height/bitrate/quality/duration/label/type sibling) or inside a
/// recognized player-config container (`sources`, `playlist`, `hls`,
/// `dash`, ...). A bare URL-shaped string with neither - the shape an ad
/// creative, tracker beacon, or unrelated preview clip's JSON just as
/// easily has - is still returned (a caller with network access can still
/// accept it via a cheap reachability probe), just with this false, so
/// `HtmlMediaSniffer`/`GenericExtractor` know not to trust it outright.
class JsonMediaCandidate {
  final String url;
  final int? width;
  final int? height;
  final int? bitrate;
  final bool contextBacked;

  const JsonMediaCandidate({
    required this.url,
    this.width,
    this.height,
    this.bitrate,
    this.contextBacked = false,
  });

  @override
  String toString() =>
      'JsonMediaCandidate($url, ${width}x$height, bitrate: $bitrate, contextBacked: $contextBacked)';
}

/// Walks an already-decoded JSON tree (whatever `jsonDecode` produced, so
/// any nesting of `Map`/`List`/`String`/etc) looking for media URLs,
/// matching the same 4 extensions the plan calls out: `.m3u8`, `.mpd`,
/// `.mp4`, `.webm`. This, not a denylist, is what keeps arbitrary JSON
/// strings (analytics ids, image thumbnails, ...) out - mirrors
/// `HtmlMediaSniffer`'s own extension-allowlist guard for the same reason.
///
/// Iterative (explicit stack, not recursion): a JSON blob nested tens of
/// thousands of levels deep (whether adversarial or just a buggy page)
/// would overflow the Dart call stack with a naive recursive walk; this
/// pushes work items onto a `List` instead. [_maxDepth], [_maxVisitedNodes],
/// and [_maxCandidates] additionally bound the total work a single call to
/// [walk] can do, so a pathologically deep or wide blob cannot turn one
/// page sniff into an unbounded amount of CPU/memory work.
class JsonMediaWalker {
  const JsonMediaWalker._();

  static const Set<String> _mediaExtensions = {'m3u8', 'mpd', 'mp4', 'webm'};

  static const Set<String> _urlKeys = {
    'url',
    'src',
    'file',
    'source',
    'contenturl',
    'videourl',
    'video_url',
    'hls',
    'mp4',
    'href',
    'playbackurl',
    'streamurl',
    'manifesturl',
  };
  static const Set<String> _widthKeys = {'width', 'w'};
  static const Set<String> _heightKeys = {'height', 'h'};
  static const Set<String> _bitrateKeys = {'bitrate', 'bandwidth', 'bit_rate'};
  static const Set<String> _qualityKeys = {'quality', 'label', 'resolution'};

  /// Sibling keys (alongside a URL-shaped value, in the same JSON object)
  /// whose mere presence marks that object as describing one specific
  /// playable rendition, even when none of the numeric ones above happen
  /// to be populated for it - the false-positive guard: an ad/tracker
  /// payload that just happens to carry a `.mp4` string under a generic
  /// `url`/`src` key essentially never also carries any of these.
  static const Set<String> _metadataSiblingKeys = {
    'width',
    'w',
    'height',
    'h',
    'bitrate',
    'bandwidth',
    'bit_rate',
    'quality',
    'label',
    'resolution',
    'duration',
    'type',
    'mimetype',
    'mime_type',
  };

  /// Map keys whose *value* (an object or array) is treated as a player's
  /// own source list for the remainder of that subtree: any string found
  /// while walking inside it is accepted as context-backed even without
  /// its own metadata siblings, since the container itself already says
  /// "this is where the player's video sources live".
  static const Set<String> _playerContainerKeys = {
    'sources',
    'source',
    'playlist',
    'renditions',
    'formats',
    'qualities',
    'videos',
    'streams',
    'files',
    'media',
    'variants',
    'manifests',
    'hls',
    'dash',
  };

  static final RegExp _qualityHeightPattern = RegExp(r'(\d{3,4})\s*p\b', caseSensitive: false);

  /// Hard caps against resource exhaustion (security follow-up): a 10k+
  /// deep JSON array must not overflow the walk, a very large flat
  /// structure must not turn one page sniff into unbounded CPU work, and
  /// a single blob producing hundreds of candidates must not balloon the
  /// number of downstream format-expansion/reachability-probe calls.
  static const int _maxDepth = 64;
  static const int _maxVisitedNodes = 200000;
  static const int _maxCandidates = 200;

  static List<JsonMediaCandidate> walk(dynamic node) {
    final results = <JsonMediaCandidate>[];
    final stack = <_WalkFrame>[_WalkFrame(node, 0, false)];
    var visited = 0;

    while (stack.isNotEmpty) {
      if (visited >= _maxVisitedNodes || results.length >= _maxCandidates) break;
      final frame = stack.removeLast();
      visited++;
      if (frame.depth > _maxDepth) continue;
      _visitOne(frame, stack, results);
    }
    return results;
  }

  static void _visitOne(_WalkFrame frame, List<_WalkFrame> stack, List<JsonMediaCandidate> out) {
    final node = frame.node;
    final depth = frame.depth;
    final inheritedPlayerish = frame.playerish;

    if (node is Map) {
      final playerish = inheritedPlayerish || _hasMetadataSibling(node);
      String? directUrl;
      for (final entry in node.entries) {
        final key = entry.key.toString().toLowerCase();
        final value = entry.value;
        if (value is String && _urlKeys.contains(key) && _looksLikeMediaUrl(value)) {
          directUrl = value;
          break;
        }
      }
      if (directUrl != null) {
        out.add(JsonMediaCandidate(
          url: directUrl,
          width: _readInt(node, _widthKeys),
          height: _readInt(node, _heightKeys) ?? _heightFromQuality(node),
          bitrate: _readInt(node, _bitrateKeys),
          contextBacked: playerish,
        ));
      }
      for (final entry in node.entries) {
        final key = entry.key.toString().toLowerCase();
        final value = entry.value;
        final childPlayerish = playerish || _playerContainerKeys.contains(key);
        if (value is String) {
          if (value != directUrl && _looksLikeMediaUrl(value) && childPlayerish) {
            out.add(JsonMediaCandidate(url: value, contextBacked: true));
          }
        } else {
          stack.add(_WalkFrame(value, depth + 1, childPlayerish));
        }
      }
      return;
    }
    if (node is List) {
      for (final item in node) {
        stack.add(_WalkFrame(item, depth + 1, inheritedPlayerish));
      }
      return;
    }
    if (node is String && _looksLikeMediaUrl(node)) {
      out.add(JsonMediaCandidate(url: node, contextBacked: inheritedPlayerish));
    }
  }

  static bool _hasMetadataSibling(Map node) {
    for (final key in node.keys) {
      if (_metadataSiblingKeys.contains(key.toString().toLowerCase())) return true;
    }
    return false;
  }

  /// Guard: only a recognized media extension (ignoring the query string)
  /// makes a JSON string a candidate at all. See the class doc and the
  /// walker test's guard-can-fail case for what leaks through without it.
  static bool _looksLikeMediaUrl(String value) {
    if (value.isEmpty || value.length > 2000) return false;
    final withoutQuery = value.split('?').first;
    final dot = withoutQuery.lastIndexOf('.');
    if (dot == -1 || dot == withoutQuery.length - 1) return false;
    return _mediaExtensions.contains(withoutQuery.substring(dot + 1).toLowerCase());
  }

  static int? _readInt(Map node, Set<String> keys) {
    for (final entry in node.entries) {
      final key = entry.key.toString().toLowerCase();
      if (!keys.contains(key)) continue;
      final value = entry.value;
      if (value is int) return value;
      if (value is double) return value.round();
      if (value is String) {
        final parsed = int.tryParse(value);
        if (parsed != null) return parsed;
      }
    }
    return null;
  }

  static int? _heightFromQuality(Map node) {
    for (final entry in node.entries) {
      final key = entry.key.toString().toLowerCase();
      if (!_qualityKeys.contains(key)) continue;
      final value = entry.value;
      if (value is! String) continue;
      final match = _qualityHeightPattern.firstMatch(value);
      if (match != null) return int.tryParse(match.group(1)!);
    }
    return null;
  }
}

/// One pending work item for [JsonMediaWalker.walk]'s explicit stack:
/// [node] to visit, its nesting [depth] (root is 0), and whether it is
/// already inside a recognized player-config container ([playerish]).
class _WalkFrame {
  final dynamic node;
  final int depth;
  final bool playerish;

  const _WalkFrame(this.node, this.depth, this.playerish);
}
