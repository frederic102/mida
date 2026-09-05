import 'dart:convert';

import 'json_media_walker.dart';

/// Finds inline-JSON blobs in a page's raw HTML/script text and hands each
/// one, decoded, to [JsonMediaWalker]. Three shapes are recognized (per the
/// plan's Lane B item 1):
///
///   1. `window.__NEXT_DATA__ = {...}` / `__INITIAL_STATE__` /
///      `__NUXT__` / `__APOLLO_STATE__` - a plain object-literal
///      assignment. Extracted with a balanced-brace scan (not a regex
///      `.*?}`, which desyncs on the first nested `}`), then `jsonDecode`d.
///      Next.js in practice ships `__NEXT_DATA__` as a
///      `<script type="application/json">` tag rather than a `window.`
///      assignment; that shape is covered by rule 2 below, so this rule
///      mainly catches the older/alternate `window.__NEXT_DATA__ =` form
///      plus `__INITIAL_STATE__`/`__APOLLO_STATE__`. `__NUXT__` is often a
///      function-wrapped literal (`(function(a,b){return {...}}(1,2))`)
///      whose object body references the wrapper's bare parameter names,
///      which is not valid JSON; `jsonDecode` throws and that blob is
///      silently skipped (documented limitation, not a crash).
///   2. Any `<script type="application/json">...</script>` tag body
///      (this is what modern Next.js's `__NEXT_DATA__` actually is).
///   3. A Video.js `data-setup="{...}"` attribute (JSON config; usually
///      single-quoted in source so its own JSON double-quotes don't need
///      escaping, but the HTML-entity-escaped double-quoted form is
///      decoded too).
///
/// Pure (no network); [HtmlMediaSniffer] resolves/classifies/DRM-filters
/// whatever candidates come back exactly like every other source.
class InlineJsonScanner {
  const InlineJsonScanner._();

  static final RegExp _windowAssignmentPattern = RegExp(
    r'window\.(?:__NEXT_DATA__|__INITIAL_STATE__|__NUXT__|__APOLLO_STATE__)\s*=\s*',
  );

  static final RegExp _jsonScriptPattern = RegExp(
    '<script\\b[^>]*\\btype\\s*=\\s*(?:"application/json"|' r"'application/json')" '[^>]*>(.*?)</script>',
    caseSensitive: false,
    dotAll: true,
  );

  static final RegExp _dataSetupPattern = RegExp(
    '''data-setup\\s*=\\s*"([^"]*)"|data-setup\\s*=\\s*''' r"'([^']*)'",
    caseSensitive: false,
  );

  /// Per-blob size cap (resource-exhaustion guard): a page could embed a
  /// pathologically large `<script type="application/json">` (or
  /// `window.__NEXT_DATA__ = {...}`) blob, and `jsonDecode` on a
  /// multi-hundred-MB string is exactly the kind of unbounded work a
  /// single hostile/broken page must not be able to force. Measured in
  /// UTF-16 code units (`String.length`), so "2MB" here is an
  /// approximation of the actual byte size, not exact - fine for a safety
  /// ceiling, not meant to be a precise byte accountant.
  static const int _maxBlobChars = 2 * 1024 * 1024;

  static List<JsonMediaCandidate> scanAll(String html) {
    final results = <JsonMediaCandidate>[];

    for (final match in _windowAssignmentPattern.allMatches(html)) {
      final blob = _extractBalancedObject(html, match.end);
      if (blob == null) continue;
      _decodeAndWalk(blob, results);
    }

    for (final match in _jsonScriptPattern.allMatches(html)) {
      final body = (match.group(1) ?? '').trim();
      if (body.isEmpty) continue;
      _decodeAndWalk(body, results);
    }

    for (final match in _dataSetupPattern.allMatches(html)) {
      final raw = match.group(1) ?? match.group(2) ?? '';
      if (raw.isEmpty) continue;
      _decodeAndWalk(_decodeHtmlEntities(raw), results);
    }

    return results;
  }

  static void _decodeAndWalk(String jsonText, List<JsonMediaCandidate> out) {
    if (jsonText.length > _maxBlobChars) return;
    dynamic decoded;
    try {
      decoded = jsonDecode(jsonText);
    } catch (_) {
      return;
    }
    out.addAll(JsonMediaWalker.walk(decoded));
  }

  static String _decodeHtmlEntities(String text) => text
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>');

  /// Returns the substring starting at the first `{` at/after [from]
  /// through its matching closing `}`, tracking string-literal state (with
  /// backslash escapes) so a `{`/`}` inside a JSON string does not desync
  /// the depth counter. Returns null when there is no `{` or the braces
  /// never balance before the text ends (a truncated/malformed blob, or a
  /// `window.X = someFunctionCall(...)` assignment with no object literal
  /// at all).
  static String? _extractBalancedObject(String text, int from) {
    final start = text.indexOf('{', from);
    if (start == -1) return null;
    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var i = start; i < text.length; i++) {
      final ch = text[i];
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (ch == '\\') {
          escaped = true;
        } else if (ch == '"') {
          inString = false;
        }
        continue;
      }
      if (ch == '"') {
        inString = true;
      } else if (ch == '{') {
        depth++;
      } else if (ch == '}') {
        depth--;
        if (depth == 0) return text.substring(start, i + 1);
      }
    }
    return null;
  }
}
