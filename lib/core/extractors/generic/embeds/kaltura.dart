import '../../media_models.dart';
import 'embed_resolver.dart';
import 'js_object_literal.dart';

/// One Kaltura player embed found on a host page.
class KalturaEmbed {
  final String partnerId;
  final String entryId;

  const KalturaEmbed({required this.partnerId, required this.entryId});
}

/// Kaltura, via the same anonymous API round-trip the Kaltura web player
/// makes on load: one `api_v3` multirequest that opens a widget session
/// (`session.startWidgetSession` with widget `_{partnerId}`), then reads
/// the entry (`baseEntry.get`) and its renditions
/// (`flavorAsset.getByEntryId`) under that session. Progressive URLs and
/// the HLS manifest are the player's own `playManifest` URLs.
///
/// Detected from `kWidget.embed({...})`/`kWidget.thumbEmbed({...})` options
/// (`partner_id`/`wid`, `entry_id`), `cdnapi(sec).kaltura.com/p/{partner}/
/// ...entry_id...` URLs, and `embedIframeJs`/`mwEmbedFrame` iframes. Only
/// the Kaltura SaaS API host is ever contacted, never a host read from the
/// page.
class KalturaEmbedResolver implements EmbedResolver {
  const KalturaEmbedResolver();

  @override
  String get platform => 'Kaltura';

  static const String _apiHost = 'cdnapisec.kaltura.com';

  static final RegExp _kalturaMarker = RegExp(r'kaltura|kWidget', caseSensitive: false);
  static final RegExp _partnerPathPattern = RegExp(r'kaltura\.com/(?:[^\s"<>]*?/)?p/(\d{1,12})/', caseSensitive: false);
  static final RegExp _partnerKeyPattern = RegExp(
    r'''["']?partner_?id["']?\s*[:=/]\s*["']?(\d{1,12})''',
    caseSensitive: false,
  );
  static final RegExp _widgetPattern = RegExp(r'''["']?wid["']?\s*[:=/]\s*["']?_(\d{1,12})''', caseSensitive: false);
  static final RegExp _entryPattern = RegExp(
    r'''["']?entry_?id["']?\s*[:=/]\s*["']?(\d_[0-9a-z]{8})\b''',
    caseSensitive: false,
  );

  /// `flavorAsset` status 2 = READY; anything else is still converting,
  /// errored, or deleted and has no file behind it yet.
  static const int _flavorReady = 2;

  /// One `kWidget.<method>({...})` call: its options object is one embed.
  static final RegExp _kWidgetCallPattern = RegExp(r'kWidget\s*\.\s*\w+\s*\(\s*\{', caseSensitive: false);

  /// One opening tag that mentions Kaltura (`<iframe>`, `<script src>`, ...).
  static final RegExp _kalturaTagPattern = RegExp(r'<[a-z][a-z0-9]*\b[^>]*kaltura[^>]*>', caseSensitive: false);

  /// One Kaltura URL (up to the next quote, space or tag delimiter).
  static final RegExp _kalturaUrlPattern =
      RegExp(r'''(?:https?:)?//[^\s"'<>]*kaltura\.com/[^\s"'<>]*''', caseSensitive: false);

  static const int _maxUnits = 200;
  static const int _maxCallLength = 8000;

  @override
  bool matches(String html) => findEmbed(html) != null;

  /// The first embed whose partner id and entry id both come from the SAME
  /// embed unit, in document order. Never pairs the first entry id on the
  /// page with the first partner id anywhere: on a page with several
  /// players that would request one partner's session for another
  /// partner's entry.
  ///
  /// Units: a `kWidget.<method>({...})` call is read structurally, ONLY
  /// its options object's own top-level `entry_id`/`entryId` and
  /// `partner_id`/`partnerId`/`wid` fields count ([JsObjectLiteral.topLevelFields]); an id
  /// nested inside `plugins`, `flashvars` or any other sub-object belongs to
  /// something else (a related-videos plugin, say) and is ignored, whatever
  /// the field order. A Kaltura tag or URL outside every such call is one
  /// flat unit (`/p/{partner}/...entry_id/...`). The only page-wide pairing
  /// allowed is the unambiguous one on a page with no `kWidget` call at all
  /// (exactly one distinct entry id and one distinct partner id, e.g. a v7
  /// player configured in one call and loaded in another).
  static KalturaEmbed? findEmbed(String html) {
    if (!_kalturaMarker.hasMatch(html)) return null;
    final decoded = EmbedSupport.unescapeHtml(html);

    final units = <(int, KalturaEmbed?)>[];
    final callSpans = <(int, int)>[];
    for (final call in _kWidgetCallPattern.allMatches(decoded)) {
      final open = call.end - 1;
      callSpans.add((call.start, JsObjectLiteral.end(decoded, open, maxLength: _maxCallLength)));
      units.add((call.start, _embedFromOptions(JsObjectLiteral.topLevelFields(decoded, open, maxLength: _maxCallLength))));
    }
    bool insideCall(int index) => callSpans.any((span) => index >= span.$1 && index < span.$2);
    for (final pattern in [_kalturaTagPattern, _kalturaUrlPattern]) {
      for (final match in pattern.allMatches(decoded)) {
        if (!insideCall(match.start)) units.add((match.start, _pairWithin(match.group(0)!)));
      }
    }
    units.sort((a, b) => a.$1.compareTo(b.$1));
    for (final (_, embed) in units.take(_maxUnits)) {
      if (embed != null) return embed;
    }
    if (callSpans.isNotEmpty) return null;

    final entries = {for (final m in _entryPattern.allMatches(decoded)) m.group(1)!.toLowerCase()};
    final partners = {
      for (final pattern in [_partnerPathPattern, _partnerKeyPattern, _widgetPattern])
        for (final m in pattern.allMatches(decoded)) m.group(1)!,
    };
    if (entries.length == 1 && partners.length == 1) {
      return KalturaEmbed(partnerId: partners.single, entryId: entries.single);
    }
    return null;
  }

  static final RegExp _entryValue = RegExp(r'^\d_[0-9a-z]{8}$', caseSensitive: false);
  static final RegExp _partnerValue = RegExp(r'^\d{1,12}$');
  static final RegExp _widgetValue = RegExp(r'^_(\d{1,12})$');

  static KalturaEmbed? _embedFromOptions(Map<String, String> fields) {
    final entry = fields['entry_id'] ?? fields['entryId'];
    if (entry == null || !_entryValue.hasMatch(entry)) return null;
    var partner = fields['partner_id'] ?? fields['partnerId'];
    if (partner != null && !_partnerValue.hasMatch(partner)) partner = null;
    partner ??= _widgetValue.firstMatch(fields['wid'] ?? '')?.group(1);
    if (partner == null) return null;
    return KalturaEmbed(partnerId: partner, entryId: entry.toLowerCase());
  }

  static KalturaEmbed? _pairWithin(String unit) {
    final entry = _entryPattern.firstMatch(unit)?.group(1);
    if (entry == null) return null;
    final partner = _partnerPathPattern.firstMatch(unit)?.group(1) ??
        _partnerKeyPattern.firstMatch(unit)?.group(1) ??
        _widgetPattern.firstMatch(unit)?.group(1);
    if (partner == null) return null;
    return KalturaEmbed(partnerId: partner, entryId: entry.toLowerCase());
  }

  @override
  Future<MediaInfo?> resolve(EmbedRequest request) async {
    final embed = findEmbed(request.html);
    if (embed == null) return null;

    final response = await request.http.postJson(
      Uri.https(_apiHost, '/api_v3/service/multirequest'),
      multirequestBody(embed),
      headers: EmbedSupport.apiHeaders(request),
    );
    if (!response.isOk) return null;
    final json = EmbedSupport.tryDecodeJson(response.body);
    if (json is! List) return null;
    return parseMultirequest(json, embed: embed, request: request);
  }

  /// The request body the Kaltura player itself sends (JSON multirequest,
  /// `format: 1` = JSON response). `{1:result:ks}` is Kaltura's own
  /// back-reference syntax: requests 2 and 3 run under request 1's session.
  static Map<String, Object> multirequestBody(KalturaEmbed embed) => {
        'apiVersion': '3.3.0',
        'format': 1,
        'ks': '',
        'partnerId': int.parse(embed.partnerId),
        '1': {'service': 'session', 'action': 'startWidgetSession', 'widgetId': '_${embed.partnerId}'},
        '2': {'service': 'baseEntry', 'action': 'get', 'entryId': embed.entryId, 'ks': '{1:result:ks}'},
        '3': {'service': 'flavorAsset', 'action': 'getByEntryId', 'entryId': embed.entryId, 'ks': '{1:result:ks}'},
      };

  /// Maps the three-element multirequest response to a [MediaInfo]. Any
  /// element that is a `KalturaAPIException` (unknown entry, access
  /// control, ...) means there is nothing to offer: null. Widevine
  /// (`.wvm`) and other DRM-packaged flavors are never offered; when every
  /// ready flavor is one, the entry is reported as `DRM_PROTECTED` and no
  /// HLS manifest is offered either (it would carry the same protection).
  MediaInfo? parseMultirequest(List<dynamic> json, {required KalturaEmbed embed, required EmbedRequest request}) {
    if (json.length < 3) return null;
    final session = json[0];
    final entry = json[1];
    final flavors = json[2];
    if (_isApiError(session) || _isApiError(entry) || _isApiError(flavors)) return null;
    if (entry is! Map || flavors is! List) return null;

    final ks = session is Map ? EmbedSupport.asString(session['ks']) : null;
    final formats = <MediaFormat>[];
    var drmFlavors = 0;
    for (final flavor in flavors) {
      if (flavor is! Map) continue;
      final status = EmbedSupport.asInt(flavor['status']);
      if (status != null && status != _flavorReady) continue;
      final flavorId = EmbedSupport.asString(flavor['id']);
      if (flavorId == null || !RegExp(r'^\d_[0-9a-zA-Z]{8}$').hasMatch(flavorId)) continue;
      if (_isDrmFlavor(flavor)) {
        drmFlavors++;
        continue;
      }
      final ext = (EmbedSupport.asString(flavor['fileExt']) ?? 'mp4').toLowerCase();
      if (!const {'mp4', 'mov', 'webm', 'm4a', 'mp3', 'flv'}.contains(ext)) continue;
      final audioOnly = ext == 'm4a' || ext == 'mp3' || _isAudioOnlyFlavor(flavor);
      formats.add(MediaFormat(
        id: 'kaltura-$flavorId',
        url: _playManifest(embed, ks, '/flavorId/$flavorId/format/url/protocol/https/a.$ext'),
        container: ext == 'mov' ? 'mp4' : ext,
        width: EmbedSupport.asInt(flavor['width']),
        height: EmbedSupport.asInt(flavor['height']),
        fps: (flavor['frameRate'] is num) ? (flavor['frameRate'] as num).toDouble() : null,
        // Kaltura reports bitrate in kbit/s and size in KB.
        bitrate: (EmbedSupport.asInt(flavor['bitrate']) ?? 0) * 1000,
        contentLength: _kbToBytes(EmbedSupport.asInt(flavor['size'])),
        hasVideo: !audioOnly,
        hasAudio: true,
      ));
    }

    if (formats.isEmpty) {
      if (drmFlavors > 0) throw EmbedSupport.drmException(platform);
      return null;
    }
    formats.add(MediaFormat(
      id: 'kaltura-hls',
      url: _playManifest(embed, ks, '/format/applehttp/protocol/https/a.m3u8'),
      container: 'm3u8',
      hasVideo: true,
      hasAudio: true,
    ));

    final duration = EmbedSupport.asInt(entry['duration']);
    return MediaInfo(
      id: 'kaltura-${embed.partnerId}-${embed.entryId}',
      title: EmbedSupport.asString(entry['name']) ?? 'Kaltura video ${embed.entryId}',
      thumbnailUrl: EmbedSupport.httpUrl(entry['thumbnailUrl']),
      duration: duration != null && duration > 0 ? Duration(seconds: duration) : null,
      sourceUrl: request.pageUrl,
      formats: formats,
      requestHeaders: EmbedSupport.mediaHeaders(request),
    );
  }

  String _playManifest(KalturaEmbed embed, String? ks, String tail) {
    final p = embed.partnerId;
    // The player appends its widget-session `ks` as a path parameter; it is
    // a short-lived anonymous token, and only ever sent to Kaltura itself.
    final ksPart = ks != null && RegExp(r'^[A-Za-z0-9_\-=+/]{1,1024}$').hasMatch(ks)
        ? '/ks/${Uri.encodeComponent(ks)}'
        : '';
    return 'https://$_apiHost/p/$p/sp/${p}00/playManifest/entryId/${embed.entryId}$ksPart$tail';
  }

  static bool _isApiError(Object? value) =>
      value is Map && (value['objectType'] == 'KalturaAPIException' || value.containsKey('code') && value.containsKey('message'));

  static bool _isDrmFlavor(Map<dynamic, dynamic> flavor) {
    final ext = (EmbedSupport.asString(flavor['fileExt']) ?? '').toLowerCase();
    final container = (EmbedSupport.asString(flavor['containerFormat']) ?? '').toLowerCase();
    final tags = (EmbedSupport.asString(flavor['tags']) ?? '').toLowerCase();
    return ext == 'wvm' ||
        ext == 'ism' ||
        container == 'wvm' ||
        container == 'ism' ||
        tags.contains('widevine') ||
        tags.contains('playready') ||
        tags.contains('fairplay') ||
        EmbedSupport.hasDrmKeys(flavor);
  }

  /// An audio-only flavor (Kaltura's "audio" tag, no frame height, no
  /// video codec) in an otherwise video container.
  static bool _isAudioOnlyFlavor(Map<dynamic, dynamic> flavor) =>
      (EmbedSupport.asInt(flavor['height']) ?? 0) == 0 &&
      (EmbedSupport.asString(flavor['videoCodecId']) ?? '').isEmpty &&
      (EmbedSupport.asString(flavor['tags']) ?? '').contains('audio');

  static int? _kbToBytes(int? kb) => kb == null || kb <= 0 ? null : kb * 1024;
}
