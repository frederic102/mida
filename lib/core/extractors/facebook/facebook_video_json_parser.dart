import 'dart:convert';

import '../generic/meta_tag_scanner.dart';
import 'facebook_raw_literal_scanner.dart';

/// Playback fields found for one video in a Facebook page. Every URL field
/// is an absolute `https` URL (validated on the way in); [dashXml] is an
/// inline MPD document.
class FacebookVideoNode {
  /// Numeric video id the fields were attributed to, or `''` when no id
  /// was found anywhere near them.
  final String id;
  String? hdUrl;
  String? sdUrl;
  String? dashXml;
  String? dashUrl;

  FacebookVideoNode(this.id);

  bool get hasMedia => hdUrl != null || sdUrl != null || dashXml != null || dashUrl != null;
}

/// Display metadata for the chosen video. Every field is optional.
class FacebookVideoMeta {
  String? title;
  String? author;
  String? thumbnailUrl;
  Duration? duration;
}

/// What [FacebookVideoJsonParser.parse] found: the chosen video's playback
/// fields (null when nothing attributable to the requested video was
/// found) and its metadata.
class FacebookPageData {
  final FacebookVideoNode? video;
  final FacebookVideoMeta meta;

  const FacebookPageData({required this.video, required this.meta});
}

/// Pure HTML -> [FacebookPageData] reader for the server-rendered JSON
/// Facebook's own web player bootstraps from. No I/O. Tolerant on purpose:
/// Facebook reshapes this data often, so every shape below is optional and
/// the reader takes whichever ones are present.
///
/// Where the data lives: `<script type="application/json" ...>` blocks
/// (the `ScheduledServerJS`/`__bbox` payloads). Each block is decoded and
/// walked recursively; a map anywhere in the tree contributes when it has
/// one of these keys:
///
/// - Shape A (flat video object, also used inside
///   `videoDeliveryLegacyFields`): `browser_native_hd_url`,
///   `browser_native_sd_url`, `playable_url_quality_hd` (HD),
///   `playable_url` (SD), `dash_manifest` (inline MPD XML string),
///   `dash_manifest_url`.
/// - Shape B (`videoDeliveryResponseResult`): `progressive_urls[]` of
///   `{progressive_url, metadata: {quality: "HD"|"SD"}}`,
///   `dash_manifests[]` of `{manifest_xml}`, `dash_manifest_urls[]` of
///   `{manifest_url}`.
/// - Shape C: `dash_manifest_xml_string` (inline MPD XML string).
///
/// Attribution: a map's own numeric `id`/`video_id`, else the nearest
/// ancestor's within [_idInheritDepth] levels (the delivery maps sit one or
/// two levels under the video object that carries the id). Fields for the
/// same id are merged; a map with no id at all (own or inherited) is its
/// own node and is never merged with any other id-less map. Metadata (`title`/`title.text`/`name`,
/// `owner.name`, `preferred_thumbnail.image.uri`/`thumbnailImage.uri`,
/// `playable_duration_in_ms`/`length_in_second`/`playable_duration`) is
/// read from maps whose own id matches, with `og:title`/`og:image`/
/// `<title>` as the fallback.
///
/// Shape D (fallback whenever the JSON blocks yield no ATTRIBUTABLE video,
/// e.g. only a recommendation's): the same Shape A and Shape B keys as
/// object literals in inline `<script>` JS, read per object by
/// [FacebookRawLiteralScanner] (object-level attribution, no merging
/// across objects, ambiguous matches rejected; see
/// [FacebookRawLiteralScanner.choose]). When the JSON blocks did carry
/// media, only a raw object with the requested id itself is accepted.
///
/// Choosing the video: a page also carries related/recommended videos, so
/// when the URL named an id only the node with that id is accepted; an
/// unattributed node is accepted only if it is the only node and the page
/// mentions the id at all; two id-less nodes are ambiguous and rejected.
/// With no id (short link that did not resolve to an id URL): the only
/// node, else the first id-carrying node in document order, else nothing.
class FacebookVideoJsonParser {
  const FacebookVideoJsonParser();

  static const int _maxDepth = 96;
  static const int _idInheritDepth = 3;

  /// Every `<script>` element: group 1 its attributes, group 2 its body.
  /// Shared with `FacebookRawLiteralScanner` so a block is either JSON
  /// (walked here) or JS (scanned there), never both and never neither.
  static final RegExp scriptPattern = RegExp(r'<script\b([^>]*)>(.*?)</script>', dotAll: true, caseSensitive: false);
  static final RegExp _typeAttribute =
      RegExp(r'''\btype\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))''', caseSensitive: false);

  /// True when [attributes] declare `type` = `application/json`, however
  /// the attribute is quoted or spaced.
  static bool isJsonScript(String attributes) {
    final match = _typeAttribute.firstMatch(attributes);
    final value = match == null ? null : (match.group(1) ?? match.group(2) ?? match.group(3));
    return value != null && value.trim().toLowerCase() == 'application/json';
  }

  static final RegExp _titleTagPattern = RegExp(r'<title\b[^>]*>(.*?)</title>', dotAll: true, caseSensitive: false);
  static final RegExp _facebookTitleSuffix = RegExp(r'\s*\|\s*Facebook\s*$');
  static final RegExp _numericPattern = RegExp(r'^\d+$');
  FacebookPageData parse(String html, {String? videoId}) {
    final walker = _Walker();
    for (final match in scriptPattern.allMatches(html)) {
      if (!isJsonScript(match.group(1)!)) continue;
      final Object? decoded;
      try {
        decoded = jsonDecode(match.group(2)!);
      } on FormatException {
        continue;
      }
      walker.walk(decoded, null, 0, 0);
    }
    final chosen = _choose(walker.ordered, videoId, html) ??
        FacebookRawLiteralScanner.choose(
          FacebookRawLiteralScanner.scan(html),
          videoId,
          html,
          allowUnattributed: walker.ordered.isEmpty,
        );
    final known = chosen != null && chosen.id.isNotEmpty ? walker.metaById[chosen.id] : null;
    final meta = known ?? FacebookVideoMeta();
    _fillFromHtml(meta, html);
    return FacebookPageData(video: chosen, meta: meta);
  }

  /// [nodes] in document order, each with media; id-less ones one per map.
  static FacebookVideoNode? _choose(List<FacebookVideoNode> nodes, String? videoId, String html) {
    if (nodes.isEmpty) return null;
    if (nodes.length == 1 && (videoId == null || nodes.single.id == videoId || nodes.single.id.isEmpty)) {
      final single = nodes.single;
      return videoId == null || single.id == videoId || html.contains(videoId) ? single : null;
    }
    for (final node in nodes) {
      if (videoId == null ? node.id.isNotEmpty : node.id == videoId) return node;
    }
    return null;
  }

  /// Shape A/C keys from [map] (a decoded JSON map or the raw-literal map)
  /// onto [node], never overwriting a value already found.
  static void applyFlatKeys(FacebookVideoNode node, Map<dynamic, dynamic> map) {
    node.hdUrl ??= httpsUrl(map['browser_native_hd_url']) ?? httpsUrl(map['playable_url_quality_hd']);
    node.sdUrl ??= httpsUrl(map['browser_native_sd_url']) ?? httpsUrl(map['playable_url']);
    node.dashXml ??= mpdXml(map['dash_manifest']) ?? mpdXml(map['dash_manifest_xml_string']);
    node.dashUrl ??= httpsUrl(map['dash_manifest_url']);
  }

  static void _fillFromHtml(FacebookVideoMeta meta, String html) {
    final tags = <String, String>{};
    for (final entry in MetaTagScanner.scan(html)) {
      tags.putIfAbsent(entry.key, () => unescapeHtml(entry.value));
    }
    meta.title ??= _nonEmpty(tags['og:title']);
    if (meta.title == null) {
      final titleTag = _titleTagPattern.firstMatch(html)?.group(1);
      meta.title = _nonEmpty(titleTag == null ? null : unescapeHtml(titleTag).replaceAll(_facebookTitleSuffix, ''));
    }
    meta.thumbnailUrl ??= httpsUrl(tags['og:image']);
  }

  /// [value] trimmed when it is an absolute `https` URL with a host, else
  /// null. Every playback URL passes through here.
  static String? httpsUrl(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null || uri.scheme.toLowerCase() != 'https' || uri.host.isEmpty) return null;
    return trimmed;
  }

  static String? mpdXml(Object? value) => value is String && value.toLowerCase().contains('<mpd') ? value : null;

  static String? _nonEmpty(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  /// The handful of entities Facebook's meta/title text and MPD
  /// `<BaseURL>` text actually use. `&amp;` last so `&amp;lt;` stays `&lt;`.
  static String unescapeHtml(String value) => value
      .replaceAll('&quot;', '"')
      .replaceAll('&#039;', "'")
      .replaceAll('&#x27;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&');

  static bool isNumericId(String value) => _numericPattern.hasMatch(value);
}

/// Recursive collector behind [FacebookVideoJsonParser.parse].
class _Walker {
  /// Id-carrying nodes, merged per id.
  final Map<String, FacebookVideoNode> nodes = {};

  /// Every node with media in first-seen order; an id-less map is added as
  /// its own node, never merged with another id-less map.
  final List<FacebookVideoNode> ordered = [];
  final Map<String, FacebookVideoMeta> metaById = {};

  void walk(Object? value, String? contextId, int contextAge, int depth) {
    if (depth > FacebookVideoJsonParser._maxDepth) return;
    if (value is Map) {
      final ownId = _numericId(value['id']) ?? _numericId(value['video_id']);
      final inherited = contextAge < FacebookVideoJsonParser._idInheritDepth ? contextId : null;
      final id = ownId ?? inherited;
      _collectMedia(value, id ?? '');
      if (ownId != null) _collectMeta(value, ownId);
      final childAge = ownId != null ? 1 : contextAge + 1;
      for (final child in value.values) {
        walk(child, id, childAge, depth + 1);
      }
    } else if (value is List) {
      for (final child in value) {
        walk(child, contextId, contextAge, depth + 1);
      }
    }
  }

  void _collectMedia(Map<dynamic, dynamic> map, String id) {
    final probe = FacebookVideoNode(id);
    FacebookVideoJsonParser.applyFlatKeys(probe, map);

    final progressive = map['progressive_urls'];
    if (progressive is List) {
      for (final entry in progressive.whereType<Map<dynamic, dynamic>>()) {
        final url = FacebookVideoJsonParser.httpsUrl(entry['progressive_url']);
        if (url == null) continue;
        final metadata = entry['metadata'];
        final quality = metadata is Map ? '${metadata['quality']}'.toUpperCase() : '';
        if (quality == 'HD') {
          probe.hdUrl ??= url;
        } else {
          probe.sdUrl ??= url;
        }
      }
    }
    final manifests = map['dash_manifests'];
    if (manifests is List) {
      for (final entry in manifests.whereType<Map<dynamic, dynamic>>()) {
        probe.dashXml ??= FacebookVideoJsonParser.mpdXml(entry['manifest_xml']);
      }
    }
    final manifestUrls = map['dash_manifest_urls'];
    if (manifestUrls is List) {
      for (final entry in manifestUrls.whereType<Map<dynamic, dynamic>>()) {
        probe.dashUrl ??= FacebookVideoJsonParser.httpsUrl(entry['manifest_url']);
      }
    }
    if (!probe.hasMedia) return;

    if (id.isEmpty) {
      ordered.add(probe);
      return;
    }
    final node = nodes.putIfAbsent(id, () {
      final created = FacebookVideoNode(id);
      ordered.add(created);
      return created;
    });
    node.hdUrl ??= probe.hdUrl;
    node.sdUrl ??= probe.sdUrl;
    node.dashXml ??= probe.dashXml;
    node.dashUrl ??= probe.dashUrl;
  }

  void _collectMeta(Map<dynamic, dynamic> map, String id) {
    final meta = metaById.putIfAbsent(id, FacebookVideoMeta.new);
    final title = map['title'];
    meta.title ??= _text(title is Map ? title['text'] : title) ?? _text(map['name']);
    final owner = map['owner'] ?? map['video_owner'];
    if (owner is Map) meta.author ??= _text(owner['name']);
    final preferred = map['preferred_thumbnail'];
    final preferredImage = preferred is Map ? preferred['image'] : null;
    final thumbnailImage = map['thumbnailImage'];
    meta.thumbnailUrl ??= FacebookVideoJsonParser.httpsUrl(preferredImage is Map ? preferredImage['uri'] : null) ??
        FacebookVideoJsonParser.httpsUrl(thumbnailImage is Map ? thumbnailImage['uri'] : null);
    meta.duration ??= _duration(map);
  }

  static Duration? _duration(Map<dynamic, dynamic> map) {
    final ms = map['playable_duration_in_ms'];
    if (ms is num && ms > 0) return Duration(milliseconds: ms.round());
    for (final key in const ['length_in_second', 'playable_duration']) {
      final seconds = map[key];
      if (seconds is num && seconds > 0) return Duration(milliseconds: (seconds * 1000).round());
    }
    return null;
  }

  static String? _text(Object? value) => value is String && value.trim().isNotEmpty ? value.trim() : null;

  static String? _numericId(Object? value) {
    final text = value is int ? '$value' : value;
    return text is String && FacebookVideoJsonParser.isNumericId(text) ? text : null;
  }
}
