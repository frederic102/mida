import 'dart:convert';

import '../media_models.dart';
import '../native_http/native_text.dart';
import 'rumble_url_matcher.dart';

/// Finds the player (embed) id of a Rumble video page, the one value the
/// embedJS call needs. Order, strictest first; each step returns only when
/// its candidates agree on ONE id, and throws `PARSE_ERROR` when they do not
/// (a page can list related videos, and one of those must never be taken
/// for the requested one):
///
/// 1. JSON-LD nodes whose `url` path is the requested slug.
/// 2. JSON-LD nodes with no `url` at all.
/// 3. Raw `"embedUrl":"https://rumble.com/embed/<id>/"` values outside JSON-LD.
/// 4. The page's oEmbed `<link>` values (`.../embed/<id>/` inside `href`).
///
/// Every candidate id is checked against [RumbleUrlMatcher.embedId] before
/// it is returned.
class RumblePageParser {
  const RumblePageParser();

  // Quote-aware open tag: an attribute value may contain `>`.
  static final RegExp _script = RegExp(
    r'''<script\b((?:[^>"']|"[^"]*"|'[^']*')*)>(.*?)</script\s*>''',
    dotAll: true,
    caseSensitive: false,
  );
  static final RegExp _ldType = RegExp(r'^application/ld\+json$', caseSensitive: false);

  static bool _isLd(Match m) => _ldType.hasMatch((NativeText.attributes('<script ${m.group(1)}>')['type'] ?? '').trim()) ||
      RegExp(r'\btype\s*=\s*application/ld\+json(?=[\s>/]|$)', caseSensitive: false).hasMatch(m.group(1)!);

  static Iterable<Match> _ldBlocks(String html) => _script.allMatches(html).where(_isLd);

  static String _withoutLd(String html) => html.replaceAllMapped(_script, (m) => _isLd(m) ? ' ' : m.group(0)!);

  static final RegExp _embedUrlValue = RegExp(r'^https?://(?:www\.)?rumble\.com/embed/([0-9A-Za-z]{3,16})/?(?:[?#].*)?$');
  static final RegExp _rawEmbedUrl = RegExp(
    r'"embedUrl"\s*:\s*"https?:(?:\\?/){2}(?:www\.)?rumble\.com(?:\\?/)embed(?:\\?/)([0-9A-Za-z]{3,16})(?![0-9A-Za-z])',
  );
  static final RegExp _oembedLink = RegExp(r'<link\b[^>]*oembed[^>]*>', caseSensitive: false);
  static final RegExp _oembedEmbed = RegExp(r'embed(?:/|%2[Ff])([0-9A-Za-z]{3,16})(?:/|%2[Ff]|$|[?&#])');

  /// The embed id of the page for [slug], or null when the page names none.
  /// Throws `PARSE_ERROR` when the page names several different ids and no
  /// signal says which one is the requested video's: a related video must
  /// never be returned in its place.
  String? embedId(String html, {required String slug}) {
    final owned = <String>{};
    final unlinked = <String>{};
    for (final block in _ldBlocks(html)) {
      final Object? decoded;
      try {
        decoded = jsonDecode(block.group(2)!);
      } on FormatException {
        continue;
      }
      for (final node in _videoNodes(decoded)) {
        final id = _idFromEmbedUrl(node['embedUrl']);
        if (id == null) continue;
        final url = node['url'];
        if (url is String) {
          if (_pathOf(url) == '/$slug.html') owned.add(id);
        } else {
          unlinked.add(id);
        }
      }
    }
    // Ownership signal 1: a node whose own url is this page.
    if (owned.isNotEmpty) return _only(owned);
    // Ownership signal 2 (weaker): the page names exactly one url-less
    // candidate. Two or more different ones are ambiguous.
    if (unlinked.isNotEmpty) return _only(unlinked);

    // JSON-LD was judged above; a raw scan must not resurrect a node it
    // rejected, so it only sees the rest. Same rule: one distinct id or nothing.
    final rawIds = <String>{
      for (final m in _rawEmbedUrl.allMatches(_withoutLd(html)))
        if (RumbleUrlMatcher.embedId.hasMatch(m.group(1)!)) m.group(1)!,
    };
    if (rawIds.isNotEmpty) return _only(rawIds);

    final linkIds = <String>{};
    for (final link in _oembedLink.allMatches(html)) {
      final href = NativeText.attributes(link.group(0)!)['href'];
      final id = href == null ? null : _oembedEmbed.firstMatch(href)?.group(1);
      if (id != null && RumbleUrlMatcher.embedId.hasMatch(id)) linkIds.add(id);
    }
    return linkIds.isEmpty ? null : _only(linkIds);
  }

  static String _only(Set<String> ids) {
    if (ids.length == 1) return ids.single;
    throw const MediaExtractionException(
      'PARSE_ERROR',
      'This Rumble page names several videos and MiDa cannot tell which one is the requested one; trying another method.',
    );
  }

  static String? _idFromEmbedUrl(Object? value) {
    if (value is! String) return null;
    return _embedUrlValue.firstMatch(value.trim())?.group(1);
  }

  static String? _pathOf(String url) {
    final uri = Uri.tryParse(url);
    return uri?.path;
  }

  /// Every map under [decoded] (a list, an `@graph`, or one object) that has
  /// an `embedUrl`.
  static Iterable<Map<String, dynamic>> _videoNodes(Object? decoded) sync* {
    if (decoded is List) {
      for (final item in decoded) {
        yield* _videoNodes(item);
      }
    } else if (decoded is Map<String, dynamic>) {
      if (decoded['embedUrl'] != null) yield decoded;
      final graph = decoded['@graph'];
      if (graph != null) yield* _videoNodes(graph);
    }
  }
}
