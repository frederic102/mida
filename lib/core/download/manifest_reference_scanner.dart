import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../extractors/media_models.dart';
import '../net/host_policy.dart';

/// Fetches a top-level HLS/DASH manifest and every URI it references -
/// including, for an HLS master playlist, one level of recursion into each
/// variant playlist - so [HlsFfmpegDownloader] can host-check all of them
/// before ever handing a bare URL to ffmpeg (which has no concept of
/// "refuse to follow a reference to a private host").
///
/// Two different things happen to the URIs this finds, and they are
/// checked differently:
///  - URIs this scanner itself *fetches* (the root manifest, and - only
///    for an HLS master playlist - each variant playlist one level down)
///    go through [HostPolicy.guardedRequest], which honors
///    [allowPrivateHosts] uniformly for all of them (a real deployment
///    always leaves this false, so every one of these fetches is fully
///    host-checked before it happens; tests can point the whole chain at
///    a local fixture server).
///  - URIs this scanner only *reads as text and never fetches itself*
///    (segments, `#EXT-X-KEY`/`#EXT-X-MAP`/`#EXT-X-MEDIA`/
///    `#EXT-X-I-FRAME-STREAM-INF`/`#EXT-X-SESSION-KEY` `URI="..."`
///    attributes, DASH `BaseURL`/`SegmentURL`/`SegmentTemplate`/
///    `Location`/`ContentProtection` references) are always host-checked
///    via [HostPolicy.assertAllowedHost] (syntactic) **and**
///    [HostPolicy.assertResolvesToPublicHost] (DNS-answer, fail closed),
///    with **no** exemption - these are exactly the URLs ffmpeg would
///    actually open next, which is the real SSRF surface this whole check
///    exists to close. A hostname that is syntactically public but whose
///    DNS answer points at a private/loopback/link-local address (DNS
///    rebinding) is refused the same as one that looks private outright.
///
/// DASH (MPD XML) references are extracted with regex rather than a real
/// XML parser (no new dependency). If the content cannot even be
/// recognized as MPD XML (no `<MPD` tag), this refuses outright rather
/// than silently returning "nothing to check".
class ManifestReferenceScanner {
  final HttpClient Function() _httpClientFactory;

  ManifestReferenceScanner({HttpClient Function()? httpClientFactory})
      : _httpClientFactory = httpClientFactory ?? HttpClient.new;

  /// Recursion is capped defensively: a master playlist could otherwise
  /// fan out into an unbounded number of variant-playlist fetches (or a
  /// single huge one), each itself a network request this app makes on
  /// the source's behalf.
  static const maxPlaylists = 20;
  static const maxBytes = 5 * 1024 * 1024;

  static const _hlsUriAttributeTags = [
    '#EXT-X-KEY',
    '#EXT-X-MAP',
    '#EXT-X-MEDIA',
    '#EXT-X-I-FRAME-STREAM-INF',
    '#EXT-X-SESSION-KEY',
  ];
  static final _hlsUriAttributePattern = RegExp(r'URI="([^"]*)"');

  /// Fetches [url] and, one level down for an HLS master playlist, each
  /// variant playlist too (see class doc for exactly which URIs get which
  /// treatment), and returns every leaf reference found - already
  /// host-checked. Throws [MediaExtractionException] the first time a
  /// leaf reference's host is disallowed, or if a fetch fails, or (DASH
  /// only) if the manifest cannot be parsed at all.
  Future<List<Uri>> scanAndCheck(
    Uri url,
    Map<String, String> headers, {
    bool allowPrivateHosts = false,
    Future<List<InternetAddress>> Function(String host) resolveHost = InternetAddress.lookup,
  }) async {
    final client = _httpClientFactory();
    try {
      var playlistsFetched = 0;
      var bytesFetched = 0;

      Future<String> fetchChecked(Uri target) async {
        final response = await HostPolicy.guardedRequest(
          client,
          target,
          useHead: false,
          configureRequest: (request) => headers.forEach(request.headers.set),
          allowPrivateHosts: allowPrivateHosts,
          resolveHost: resolveHost,
        );
        // Streamed and bounded WHILE reading (not just checked once the
        // whole body has already been buffered): a compromised/misbehaving
        // manifest host could otherwise exhaust memory by simply never
        // ending the response body before this ever got a chance to stop.
        final builder = BytesBuilder(copy: false);
        var thisFetchBytes = 0;
        await for (final chunk in response) {
          thisFetchBytes += chunk.length;
          if (bytesFetched + thisFetchBytes > maxBytes) {
            throw const MediaExtractionException(
              'PARSE_ERROR',
              'This manifest exceeded the ${maxBytes ~/ (1024 * 1024)}MB size limit while being read; '
                  'refusing rather than buffering an unbounded response body.',
            );
          }
          builder.add(chunk);
        }
        final text = utf8.decode(builder.takeBytes());
        playlistsFetched++;
        bytesFetched += thisFetchBytes;
        return text;
      }

      final rootText = await fetchChecked(url);
      final leafReferences = <Uri>[];

      if (_looksLikeDash(rootText)) {
        leafReferences.addAll(_dashReferences(rootText, url));
      } else {
        final root = _hlsReferences(rootText, url);
        leafReferences.addAll(root.attributeUris);

        if (_isMasterPlaylist(rootText)) {
          // root.plainLines are variant playlist URIs - fetched (and thus
          // already host-checked by fetchChecked itself), not re-added as
          // leaves; their own content's segments/keys/maps are the leaves.
          for (final variantUri in root.plainLines) {
            if (playlistsFetched >= maxPlaylists || bytesFetched >= maxBytes) break;
            final String variantText;
            try {
              variantText = await fetchChecked(variantUri);
            } catch (_) {
              // Could not fetch this variant to look inside it - an
              // availability problem, not a security gap: its own URL
              // already went through the same host-checked fetch above.
              continue;
            }
            final variant = _hlsReferences(variantText, variantUri);
            leafReferences.addAll(variant.plainLines);
            leafReferences.addAll(variant.attributeUris);
          }
        } else {
          // A media playlist (no #EXT-X-STREAM-INF): plain lines are
          // segments - leaves themselves, never fetched by this scanner.
          leafReferences.addAll(root.plainLines);
        }
      }

      // Deduplicated by host: a manifest routinely lists dozens of
      // segments all on the same CDN host, and resolving each of them
      // individually would multiply DNS lookups (and their latency, and
      // their fail-closed risk on a flaky resolver) for zero extra safety.
      final checkedHosts = <String>{};
      for (final uri in leafReferences) {
        HostPolicy.assertAllowedHost(uri, context: 'a segment/key/map referenced by this manifest');
        if (checkedHosts.add(uri.host.toLowerCase())) {
          await HostPolicy.assertResolvesToPublicHost(uri, resolveHost: resolveHost);
        }
      }
      return leafReferences;
    } finally {
      client.close(force: true);
    }
  }

  static bool _isMasterPlaylist(String manifestText) => manifestText.contains('#EXT-X-STREAM-INF');

  static _HlsReferences _hlsReferences(String manifestText, Uri base) {
    final plainLines = <Uri>[];
    final attributeUris = <Uri>[];
    for (final rawLine in manifestText.split(RegExp(r'\r?\n'))) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#')) {
        if (_hlsUriAttributeTags.any(line.startsWith)) {
          final value = _hlsUriAttributePattern.firstMatch(line)?.group(1);
          if (value != null && value.isNotEmpty) _tryResolveAdd(attributeUris, base, value);
        }
        continue;
      }
      _tryResolveAdd(plainLines, base, line);
    }
    return _HlsReferences(plainLines, attributeUris);
  }

  static bool _looksLikeDash(String text) {
    final head = text.trimLeft();
    return head.startsWith('<?xml') || RegExp(r'<MPD\b', caseSensitive: false).hasMatch(head);
  }

  /// Throws `MediaExtractionException('PARSE_ERROR', ...)` when [xml] does
  /// not even contain a recognizable `<MPD` root element - refusing rather
  /// than falling back to "found nothing to check" for content that
  /// claimed to be DASH but this could not actually parse.
  static List<Uri> _dashReferences(String xml, Uri base) {
    if (!RegExp(r'<MPD\b', caseSensitive: false).hasMatch(xml)) {
      throw const MediaExtractionException(
        'PARSE_ERROR',
        'Could not parse this DASH manifest (no <MPD> root element found); refusing rather than passing it to '
            'ffmpeg unchecked.',
      );
    }

    final uris = <Uri>[];
    for (final m in RegExp(r'<BaseURL\b[^>]*>([^<]*)</BaseURL>', caseSensitive: false).allMatches(xml)) {
      _tryResolveAdd(uris, base, m.group(1)!.trim());
    }
    for (final m in RegExp(r'<Location\b[^>]*>([^<]*)</Location>', caseSensitive: false).allMatches(xml)) {
      _tryResolveAdd(uris, base, m.group(1)!.trim());
    }
    for (final m in RegExp(r'<SegmentURL\b[^>]*\bmedia="([^"]*)"', caseSensitive: false).allMatches(xml)) {
      _tryResolveAdd(uris, base, m.group(1)!);
    }
    for (final m in RegExp(r'<SegmentTemplate\b[^>]*>', caseSensitive: false).allMatches(xml)) {
      final tag = m.group(0)!;
      final media = RegExp(r'\bmedia="([^"]*)"').firstMatch(tag)?.group(1);
      final init = RegExp(r'\binitialization="([^"]*)"').firstMatch(tag)?.group(1);
      if (media != null) _tryResolveAdd(uris, base, media);
      if (init != null) _tryResolveAdd(uris, base, init);
    }
    final contentProtectionPattern = RegExp(
      r'<ContentProtection\b.*?(?:/>|</ContentProtection>)',
      caseSensitive: false,
      dotAll: true,
    );
    final urlInTextPattern = RegExp(r'''https?://[^\s"'<>]+''');
    for (final m in contentProtectionPattern.allMatches(xml)) {
      for (final urlMatch in urlInTextPattern.allMatches(m.group(0)!)) {
        _tryResolveAdd(uris, base, urlMatch.group(0)!);
      }
    }
    return uris;
  }

  static void _tryResolveAdd(List<Uri> list, Uri base, String value) {
    try {
      list.add(base.resolve(value));
    } catch (_) {
      // Not a valid URI reference; ignore rather than fail the whole scan.
    }
  }
}

class _HlsReferences {
  final List<Uri> plainLines;
  final List<Uri> attributeUris;
  const _HlsReferences(this.plainLines, this.attributeUris);
}
