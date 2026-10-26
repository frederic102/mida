import 'dart:convert';

import '../generic/meta_tag_scanner.dart';
import '../media_models.dart';
import '../native_http/native_text.dart';
import 'linkedin_url_matcher.dart';

/// One `{src, type, bitrate}` entry of a `<video data-sources>` list.
class LinkedInSource {
  final String url;

  /// `m3u8` (HLS) or `mp4`.
  final String container;

  /// As given by the source's `data-bitrate`, else `bitrate`, or null.
  final int? bitrate;

  const LinkedInSource({required this.url, required this.container, this.bitrate});
}

/// What was read from one public post page.
class LinkedInPost {
  final String title;
  final String? author;
  final String? thumbnailUrl;
  final List<LinkedInSource> sources;

  const LinkedInPost({required this.title, this.author, this.thumbnailUrl, required this.sources});
}

/// One `<video data-sources>` element and the post it sits in.
class _VideoCandidate {
  final String dataSources;
  final String? poster;

  /// Numeric id of the innermost enclosing element that carries an exact
  /// `urn:li:(activity|ugcPost|share):<id>` attribute value (or the video
  /// element itself), else null.
  final String? ownerId;

  const _VideoCandidate({required this.dataSources, required this.poster, required this.ownerId});
}

/// Reads the server-rendered video of a public LinkedIn post page:
/// `<video data-sources='[{"src":"...","type":"application/x-mpegURL"},
/// {"src":"...","type":"video/mp4","bitrate":...}]' data-poster-url="...">`
/// (the attribute is HTML-entity encoded in a real page; both quote styles
/// are read). The title is `og:title`; when it has LinkedIn's "<Name> on
/// LinkedIn: <text>" shape the name becomes the author.
///
/// **Ownership is structural, never textual.** The page is walked as a tag
/// stream (comments, scripts and styles removed) and every video gets the
/// id of its innermost enclosing element carrying an exact
/// `urn:li:...:<id>` attribute value. A video is the requested post's when
/// that id equals the id the URL names (digit-for-digit: a longer id that
/// merely starts with it is a different post). Rules, in order:
/// 1. Videos owned by the requested id; more than one distinct source list
///    among them is `PARSE_ERROR`.
/// 2. Else, videos not inside any post container, but only when the page's
///    own `canonical`/`og:url` names this post (the exact id, or for a slug
///    URL without an id the exact requested path) and exactly one distinct
///    source list exists.
/// 3. Else `PARSE_ERROR`: a video is never guessed, and a video inside
///    another post's container is never taken.
/// The poster comes from the chosen video; `og:title`/`og:image` are the
/// page's own, which rules 1 and 2 have tied to the requested post.
class LinkedInPostParser {
  const LinkedInPostParser();

  static final RegExp _noise = RegExp(
    r'<!--.*?-->|<script\b.*?</script\s*>|<style\b.*?</style\s*>',
    caseSensitive: false,
    dotAll: true,
  );
  static final RegExp _tag = RegExp(r'''<(/?)([A-Za-z][A-Za-z0-9]*)((?:[^>"']|"[^"]*"|'[^']*')*)>''');
  static final RegExp _urn = RegExp(r'^urn:li:(?:activity|ugcPost|share):(\d{15,25})$');
  static final RegExp _titleShape = RegExp(r'^(.+?)\s+on LinkedIn:\s*(.+)$', dotAll: true);
  static const Set<String> _voidTags = {
    'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'param', 'source', 'track', 'wbr',
  };

  /// Null when the page holds no `<video data-sources>` at all.
  /// [requestedPath] is the path of the fetched post URL (slug rule).
  LinkedInPost? parse(String html, {String? postId, required String requestedPath}) {
    final candidates = <_VideoCandidate>[];
    final proofUrls = <String>[];
    _walk(html.replaceAll(_noise, ' '), candidates, proofUrls);
    if (candidates.isEmpty) return null;

    final chosen = _choose(candidates, proofUrls, postId, requestedPath);
    final sources = _sources(chosen.dataSources);
    if (sources.isEmpty) {
      throw const MediaExtractionException('PARSE_ERROR', 'This LinkedIn post lists its video in a shape MiDa does not understand; trying another method.');
    }

    final meta = {for (final entry in MetaTagScanner.scan(html)) entry.key: NativeText.decodeEntities(entry.value)};
    final ogTitle = NativeText.nonEmpty(meta['og:title']);
    final shape = ogTitle == null ? null : _titleShape.firstMatch(ogTitle);
    return LinkedInPost(
      title: shape == null ? (ogTitle ?? 'LinkedIn video') : NativeText.clip(shape.group(2)!.trim(), 200),
      author: shape?.group(1)?.trim(),
      thumbnailUrl: NativeText.httpsUrl(chosen.poster) ?? NativeText.httpsUrl(meta['og:image']),
      sources: sources,
    );
  }

  /// Single pass over the tags: tracks the open elements that carry a post
  /// URN, records every `<video data-sources>` with its owner, and collects
  /// the page's `canonical`/`og:url` URLs.
  static void _walk(String html, List<_VideoCandidate> candidates, List<String> proofUrls) {
    final stack = <({String name, String? urnId})>[];
    for (final match in _tag.allMatches(html)) {
      final closing = match.group(1) == '/';
      final name = match.group(2)!.toLowerCase();
      if (closing) {
        final at = stack.lastIndexWhere((e) => e.name == name);
        if (at != -1) stack.removeRange(at, stack.length);
        continue;
      }
      final attrs = NativeText.attributes(match.group(0)!);
      final ownUrn = _urnIn(attrs.values);

      if (name == 'video') {
        final sources = attrs['data-sources'];
        if (sources != null && sources.trim().isNotEmpty) {
          final inherited = stack.lastWhere((e) => e.urnId != null, orElse: () => (name: '', urnId: null)).urnId;
          candidates.add(_VideoCandidate(dataSources: sources, poster: attrs['data-poster-url'], ownerId: ownUrn ?? inherited));
        }
        continue;
      }
      if (name == 'link' && attrs['rel']?.toLowerCase() == 'canonical' && attrs['href'] != null) proofUrls.add(attrs['href']!);
      if (name == 'meta' && (attrs['property'] ?? attrs['name'])?.toLowerCase() == 'og:url' && attrs['content'] != null) {
        proofUrls.add(attrs['content']!);
      }
      if (_voidTags.contains(name) || (match.group(3) ?? '').trimRight().endsWith('/')) continue;
      stack.add((name: name, urnId: ownUrn));
    }
  }

  static String? _urnIn(Iterable<String> values) {
    for (final value in values) {
      final id = _urn.firstMatch(value.trim())?.group(1);
      if (id != null) return id;
    }
    return null;
  }

  static _VideoCandidate _choose(
    List<_VideoCandidate> candidates,
    List<String> proofUrls,
    String? postId,
    String requestedPath,
  ) {
    final owned = postId == null ? <_VideoCandidate>[] : [for (final c in candidates) if (c.ownerId == postId) c];
    if (owned.isNotEmpty) return _single(owned);

    final unowned = [for (final c in candidates) if (c.ownerId == null) c];
    if (unowned.isNotEmpty && proofUrls.any((url) => _namesThisPost(url, postId, requestedPath))) return _single(unowned);

    throw const MediaExtractionException(
      'PARSE_ERROR',
      'MiDa could not tell which video on this LinkedIn page belongs to the post the link names; trying another method.',
    );
  }

  /// The one candidate, or `PARSE_ERROR` when the group holds several
  /// different source lists.
  static _VideoCandidate _single(List<_VideoCandidate> group) {
    final distinct = <String>{for (final c in group) c.dataSources.trim()};
    if (distinct.length != 1) {
      throw const MediaExtractionException(
        'PARSE_ERROR',
        'This LinkedIn post holds several different videos and MiDa could not pick one; trying another method.',
      );
    }
    return group.first;
  }

  /// True when a page-declared canonical URL is this post: a LinkedIn host
  /// and either the exact id as a whole digit run in the path, or (no id in
  /// the link) the exact requested path.
  static bool _namesThisPost(String url, String? postId, String requestedPath) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !LinkedInUrlMatcher.isLinkedInHost(uri.host)) return false;
    if (postId != null) return RegExp('(?<![0-9])$postId(?![0-9])').hasMatch(uri.path);
    return _normalizePath(uri.path) == _normalizePath(requestedPath);
  }

  /// No trailing slash, percent-escapes upper-cased (`%ed` == `%ED`).
  static String _normalizePath(String path) {
    final trimmed = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
    return trimmed.replaceAllMapped(RegExp('%[0-9a-fA-F]{2}'), (m) => m.group(0)!.toUpperCase());
  }

  static List<LinkedInSource> _sources(String dataSources) {
    final Object? decoded;
    try {
      decoded = jsonDecode(dataSources);
    } on FormatException {
      return const [];
    }
    final result = <LinkedInSource>[];
    final seen = <String>{};
    for (final entry in NativeText.asList(decoded)) {
      final map = NativeText.asMap(entry);
      final url = NativeText.httpsUrl(map?['src']);
      if (map == null || url == null) continue;
      final type = '${map['type'] ?? ''}'.toLowerCase();
      final container = type.contains('mpegurl')
          ? 'm3u8'
          : type == 'video/mp4'
              ? 'mp4'
              : null;
      if (container == null || !seen.add(url)) continue;
      result.add(LinkedInSource(url: url, container: container, bitrate: NativeText.positiveInt(map['data-bitrate']) ?? NativeText.positiveInt(map['bitrate'])));
    }
    return result;
  }
}
