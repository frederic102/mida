import 'dart:convert';

import 'facebook_video_json_parser.dart';

/// Shape D of [FacebookVideoJsonParser]: playback fields written as object
/// literals inside inline `<script>` JavaScript (not a JSON block), e.g.
/// `v.init({"video_id":"3","playable_url":"https:\/\/..."})`.
///
/// Attribution is per object, never per page: a quote-aware scanner walks
/// each script's `{...}`/`[...]` nesting and records a `"key": value` pair
/// only on the innermost object it is written in. Every object that carries
/// playback fields becomes one node with exactly that object's own fields
/// and its own numeric `id`/`video_id` (no inheritance, no merging across
/// objects), so an HD URL from one object can never be paired with an SD
/// URL from another, and a recommendation's fields can never be credited to
/// the requested video. Shape B (`progressive_urls[]`, `dash_manifests[]`,
/// `dash_manifest_urls[]`) is read the same way, entries credited to the
/// object that owns the array.
///
/// Lexing: double-quoted strings are decoded, single-quoted strings are
/// opaque, and `//` line comments, `/* */` block comments and backtick
/// template literals are skipped entirely, so a commented-out or
/// templated playback URL never counts. An object that writes the same
/// playback or id key twice with different values is ambiguous and yields
/// no node at all. `<script type="application/json">` blocks are left to
/// the JSON walker (their id inheritance would be lost here). Best effort:
/// a construct the lexer still misreads (a regex literal containing a
/// quote, say) loses candidates; the conflict rule above keeps it from
/// silently picking a wrong value inside one object.
class FacebookRawLiteralScanner {
  const FacebookRawLiteralScanner._();


  static const int _maxNodes = 64;
  static const int _maxDepth = 256;

  /// Every object in [html]'s inline scripts that carries playback fields,
  /// in document order.
  static List<FacebookVideoNode> scan(String html) {
    final nodes = <FacebookVideoNode>[];
    for (final script in FacebookVideoJsonParser.scriptPattern.allMatches(html)) {
      if (FacebookVideoJsonParser.isJsonScript(script.group(1)!)) continue;
      _ScriptScanner(script.group(2)!, nodes).run();
      if (nodes.length >= _maxNodes) break;
    }
    return nodes;
  }

  /// The raw node for [videoId], or null when there is none or it is
  /// ambiguous. With an id: the first object whose own id is [videoId];
  /// failing that, an id-less object only when it is the ONLY raw object
  /// on the page and the page mentions [videoId]. Without an id: only a
  /// single raw object is accepted (several are ambiguous).
  ///
  /// [allowUnattributed] false (the JSON blocks already carried media,
  /// just none attributable to [videoId]) accepts only an object carrying
  /// [videoId] itself: an id-less object then could as well be the JSON
  /// video's own delivery data.
  static FacebookVideoNode? choose(
    List<FacebookVideoNode> nodes,
    String? videoId,
    String html, {
    bool allowUnattributed = true,
  }) {
    if (nodes.isEmpty) return null;
    if (videoId != null) {
      for (final node in nodes) {
        if (node.id == videoId) return node;
      }
      if (!allowUnattributed) return null;
      final single = nodes.length == 1 ? nodes.single : null;
      return single != null && single.id.isEmpty && html.contains(videoId) ? single : null;
    }
    if (!allowUnattributed) return null;
    return nodes.length == 1 ? nodes.single : null;
  }

  /// Keys whose conflicting duplicates make an object ambiguous.
  static const Set<String> _guardedKeys = {
    'id',
    'video_id',
    'browser_native_hd_url',
    'browser_native_sd_url',
    'playable_url_quality_hd',
    'playable_url',
    'dash_manifest',
    'dash_manifest_url',
    'dash_manifest_xml_string',
    'progressive_url',
    'manifest_xml',
    'manifest_url',
    'quality',
  };
}

class _Frame {
  final bool isObject;

  /// Key this container sits under in its parent object; for an element of
  /// an array, the array's own key.
  final String? key;
  final Map<String, String> values = {};
  bool conflicted = false;
  String? quality;
  final List<(String, String)> progressive = [];
  final List<String> manifestXml = [];
  final List<String> manifestUrls = [];

  _Frame(this.isObject, this.key);
}

class _ScriptScanner {
  final String source;
  final List<FacebookVideoNode> nodes;
  final List<_Frame> _stack = [];
  String? _pendingKey;
  String? _lastString;

  _ScriptScanner(this.source, this.nodes);

  void run() {
    var i = 0;
    while (i < source.length && nodes.length < FacebookRawLiteralScanner._maxNodes) {
      final c = source[i];
      final skipTo = _skipCommentOrTemplate(i);
      if (skipTo != null) {
        i = skipTo;
        continue;
      }
      if (c == '"' || c == "'") {
        final end = _stringEnd(i, c);
        if (end < 0) {
          // Not a string after all (an apostrophe in a comment, say).
          i++;
          continue;
        }
        _onString(c == '"' ? source.substring(i + 1, end) : null);
        i = end + 1;
        continue;
      }
      if (c == '{' || c == '[') {
        if (_stack.length >= FacebookRawLiteralScanner._maxDepth) return;
        final top = _stack.isEmpty ? null : _stack.last;
        final key = top == null ? null : (top.isObject ? _pendingKey : top.key);
        _stack.add(_Frame(c == '{', key));
        _pendingKey = null;
        _lastString = null;
      } else if (c == '}' || c == ']') {
        if (_stack.isNotEmpty) _pop();
        _pendingKey = null;
        _lastString = null;
      } else if (c == ':') {
        if (_stack.isNotEmpty && _stack.last.isObject && _lastString != null) _pendingKey = _lastString;
        _lastString = null;
      } else if (c == ',') {
        _pendingKey = null;
        _lastString = null;
      } else if (_isDigit(c) && _pendingKey != null) {
        var end = i;
        while (end < source.length && _isDigit(source[end])) {
          end++;
        }
        _record(source.substring(i, end));
        i = end;
        continue;
      }
      i++;
    }
  }

  /// Index just past a `//` comment, `/* */` comment or backtick template
  /// literal starting at [i], or null when none starts there. Unterminated
  /// ones run to the end of the script.
  int? _skipCommentOrTemplate(int i) {
    final c = source[i];
    final next = i + 1 < source.length ? source[i + 1] : '';
    if (c == '/' && next == '/') {
      final end = source.indexOf('\n', i + 2);
      return end < 0 ? source.length : end + 1;
    }
    if (c == '/' && next == '*') {
      final end = source.indexOf('*/', i + 2);
      return end < 0 ? source.length : end + 2;
    }
    if (c != '`') return null;
    var depth = 0;
    for (var j = i + 1; j < source.length; j++) {
      final t = source[j];
      if (t == r'\') {
        j++;
      } else if (t == r'$' && j + 1 < source.length && source[j + 1] == '{') {
        depth++;
        j++;
      } else if (t == '}' && depth > 0) {
        depth--;
      } else if (t == '`' && depth == 0) {
        return j + 1;
      }
    }
    return source.length;
  }

  static bool _isDigit(String c) => c.codeUnitAt(0) >= 0x30 && c.codeUnitAt(0) <= 0x39;

  /// Index of the quote closing the string opened at [start], or -1.
  int _stringEnd(int start, String quote) {
    for (var i = start + 1; i < source.length; i++) {
      final c = source[i];
      if (c == r'\') {
        i++;
      } else if (c == quote) {
        return i;
      } else if (c == '\n') {
        return -1;
      }
    }
    return -1;
  }

  /// [raw] is a double-quoted literal's content (null for a single-quoted
  /// one, which is skipped as opaque).
  void _onString(String? raw) {
    final decoded = raw == null ? null : _decode(raw);
    if (_pendingKey != null) {
      if (decoded != null) _record(decoded);
      _pendingKey = null;
      return;
    }
    _lastString = decoded;
  }

  void _record(String value) {
    final key = _pendingKey;
    _pendingKey = null;
    if (key == null || _stack.isEmpty || !_stack.last.isObject) return;
    final frame = _stack.last;
    final previous = frame.values[key];
    if (previous == null) {
      frame.values[key] = value;
    } else if (previous != value && FacebookRawLiteralScanner._guardedKeys.contains(key)) {
      frame.conflicted = true;
    }
  }

  static String? _decode(String raw) {
    try {
      final value = jsonDecode('"$raw"');
      return value is String ? value : null;
    } on FormatException {
      return null;
    }
  }

  void _pop() {
    final frame = _stack.removeLast();
    if (!frame.isObject) return;
    final parent = _stack.isEmpty ? null : _stack.last;
    if (parent != null && parent.isObject && frame.key == 'metadata') {
      parent.quality = frame.values['quality'];
    }
    if (parent != null && !parent.isObject) {
      final owner = _ownerOf(_stack.length - 1);
      // A conflicted entry is ambiguous: it credits nothing to its owner.
      if (owner != null && !frame.conflicted) _creditArrayEntry(owner, frame, parent.key);
    }
    final node = _nodeOf(frame);
    if (node != null) nodes.add(node);
  }

  /// Nearest object frame at or below stack index [from].
  _Frame? _ownerOf(int from) {
    for (var i = from; i >= 0; i--) {
      if (_stack[i].isObject) return _stack[i];
    }
    return null;
  }

  static void _creditArrayEntry(_Frame owner, _Frame entry, String? arrayKey) {
    switch (arrayKey) {
      case 'progressive_urls':
        final url = FacebookVideoJsonParser.httpsUrl(entry.values['progressive_url']);
        if (url != null) owner.progressive.add((url, (entry.quality ?? entry.values['quality'] ?? '').toUpperCase()));
      case 'dash_manifests':
        final xml = FacebookVideoJsonParser.mpdXml(entry.values['manifest_xml']);
        if (xml != null) owner.manifestXml.add(xml);
      case 'dash_manifest_urls':
        final url = FacebookVideoJsonParser.httpsUrl(entry.values['manifest_url']);
        if (url != null) owner.manifestUrls.add(url);
    }
  }

  static FacebookVideoNode? _nodeOf(_Frame frame) {
    if (frame.conflicted) return null;
    final id = frame.values['id'] ?? frame.values['video_id'];
    final node = FacebookVideoNode(id != null && FacebookVideoJsonParser.isNumericId(id) ? id : '');
    FacebookVideoJsonParser.applyFlatKeys(node, frame.values);
    for (final (url, quality) in frame.progressive) {
      if (quality == 'HD') {
        node.hdUrl ??= url;
      } else {
        node.sdUrl ??= url;
      }
    }
    if (frame.manifestXml.isNotEmpty) node.dashXml ??= frame.manifestXml.first;
    if (frame.manifestUrls.isNotEmpty) node.dashUrl ??= frame.manifestUrls.first;
    return node.hasMedia ? node : null;
  }
}
