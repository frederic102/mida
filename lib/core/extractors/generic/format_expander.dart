import '../media_models.dart';
import 'drm_playlist_scanner.dart';
import 'hls_playlist_parser.dart';

/// A fetched body plus the HTTP status it came with, so callers that need
/// to distinguish "200 with real content" from "some error page" (the HLS
/// master-playlist expansion path) can. Public (unlike the rest of this
/// file's collaborators) because `GenericExtractor` constructs one of
/// these to hand to [FormatExpander.fetchText].
class FetchedBody {
  final int statusCode;
  final String body;

  const FetchedBody({required this.statusCode, required this.body});
}

/// Result of [FormatExpander.expandFormats]: the formats found (possibly
/// empty), plus whether this candidate was dropped specifically because
/// its manifest body carried DRM key material (see [DrmPlaylistScanner]).
/// [GenericExtractor] needs this distinction to throw `DRM_PROTECTED`
/// rather than `NO_MEDIA_FOUND` when every candidate on a page turns out
/// to be encrypted, even though the URL itself looked clean (the existing,
/// separate URL-substring DRM check in `HtmlMediaSniffer` cannot catch
/// that case - it never looks at the manifest body).
class ExpandedFormats {
  final List<MediaFormat> formats;
  final bool drmDetected;

  const ExpandedFormats({this.formats = const [], this.drmDetected = false});
}

/// Turns discovered candidate media URLs into [MediaFormat]s (HLS
/// master-playlist expansion, per-container defaults) and orders the
/// result so the most trustworthy metadata comes first. Split out of
/// `GenericExtractor` to keep that file under the project's 400-line cap.
///
/// The actual network fetch is injected via [fetchText] rather than owned
/// here, so this class stays free of `HostPolicy`/`HttpClient` wiring -
/// that stays in `GenericExtractor`, the single place SSRF guarding is
/// owned (every fetch, including this one, must go through
/// `HostPolicy.guardedRequest`).
class FormatExpander {
  final Future<FetchedBody> Function(Uri url, {Map<String, String>? extraHeaders}) fetchText;

  const FormatExpander({required this.fetchText});

  /// Turns one candidate media URL into zero or more [MediaFormat]s. An
  /// `m3u8` URL is fetched and, if it turns out to be a master playlist,
  /// expanded into one format per `#EXT-X-STREAM-INF` variant (per the
  /// plan's format model); a media-playlist `m3u8` (no stream-inf tags,
  /// but a genuine `#EXTM3U` body) is exposed as a single format; DASH
  /// `mpd` is now also fetched (size-capped by whatever cap `fetchText`'s
  /// implementation applies) purely to scan it for DRM signals - see
  /// [_expandMpd]; any other container is exposed as a single format
  /// unconditionally, with no fetch.
  ///
  /// [width]/[height]/[bitrate] come from an inline-JSON-derived
  /// `SniffedMedia` (see `HtmlMediaSniffer`/`JsonMediaWalker`) when the
  /// page exposed them; they are only ever used for the single-format
  /// paths (a real HLS variant's own `#EXT-X-STREAM-INF` metadata is
  /// always more trustworthy than page-JSON metadata for the *master*
  /// URL, so the expanded-variant path below ignores them).
  ///
  /// If the master-playlist fetch itself fails (network error, non-2xx
  /// status, or a body that is not actually an HLS playlist at all, e.g.
  /// an error page returned in place of a DRM-blocked manifest) this
  /// candidate contributes **no** format at all rather than falling back
  /// to a format pointing at a URL already known to be unusable (a live
  /// probe hit exactly this: a placeholder format for an inaccessible
  /// playlist reached ffmpeg and failed with "Invalid data found when
  /// processing input").
  Future<ExpandedFormats> expandFormats(
    String url,
    String container, {
    Map<String, String>? extraHeaders,
    int? width,
    int? height,
    int? bitrate,
  }) async {
    if (container == 'mpd') {
      return _expandMpd(url, container, extraHeaders: extraHeaders, width: width, height: height, bitrate: bitrate);
    }
    if (container != 'm3u8') {
      return ExpandedFormats(
        formats: [formatFor(id: url, url: url, container: container, width: width, height: height, bitrate: bitrate)],
      );
    }

    FetchedBody fetch;
    try {
      fetch = await fetchText(Uri.parse(url), extraHeaders: extraHeaders);
    } catch (_) {
      return const ExpandedFormats();
    }

    final looksLikePlaylist = fetch.body.trimLeft().startsWith('#EXTM3U');
    final isSuccessStatus = fetch.statusCode >= 200 && fetch.statusCode < 300;
    if (!isSuccessStatus || !looksLikePlaylist) {
      return const ExpandedFormats();
    }

    if (DrmPlaylistScanner.isHlsDrmProtected(fetch.body)) {
      return const ExpandedFormats(drmDetected: true);
    }

    final variants = HlsPlaylistParser.parseMasterVariants(fetch.body, Uri.parse(url));
    if (variants.isEmpty) {
      return ExpandedFormats(
        formats: [formatFor(id: url, url: url, container: container, width: width, height: height, bitrate: bitrate)],
      );
    }

    // Some DRM signals only show up in the variant/media playlist's own
    // `#EXT-X-KEY`, not the master's - check the first variant too (one
    // extra fetch, not one per variant).
    if (await _isVariantDrmProtected(variants.first.url, extraHeaders)) {
      return const ExpandedFormats(drmDetected: true);
    }

    return ExpandedFormats(formats: [
      for (var i = 0; i < variants.length; i++)
        formatFor(
          id: '$url#$i',
          url: variants[i].url,
          container: 'm3u8',
          width: variants[i].width,
          height: variants[i].height,
          bitrate: variants[i].bandwidth,
        ),
    ]);
  }

  /// Fetches a DASH `.mpd` manifest purely to scan it for DRM signals
  /// (`ContentProtection`/`cenc:pssh`/`default_KID`/`KEYFORMAT` - variant
  /// parsing itself stays out of scope, as before: a single opaque format
  /// is still exposed). A fetch failure (network error, non-2xx) is
  /// fail-open here, unlike the HLS master path above: we cannot positively
  /// confirm the manifest is *clean* either way, and dropping a
  /// legitimate, reachable-by-ffmpeg mpd just because our own verification
  /// fetch had a transient problem would be a worse regression than
  /// occasionally forwarding an unverified one (same as today's status quo
  /// for every mpd, since this fetch is net-new).
  Future<ExpandedFormats> _expandMpd(
    String url,
    String container, {
    Map<String, String>? extraHeaders,
    int? width,
    int? height,
    int? bitrate,
  }) async {
    try {
      final fetch = await fetchText(Uri.parse(url), extraHeaders: extraHeaders);
      final isSuccessStatus = fetch.statusCode >= 200 && fetch.statusCode < 300;
      if (isSuccessStatus && DrmPlaylistScanner.isMpdDrmProtected(fetch.body)) {
        return const ExpandedFormats(drmDetected: true);
      }
    } catch (_) {
      // Fail-open: see doc above.
    }
    return ExpandedFormats(
      formats: [formatFor(id: url, url: url, container: container, width: width, height: height, bitrate: bitrate)],
    );
  }

  /// Fail-open (returns false, i.e. "not DRM") on any fetch failure: an
  /// unreachable variant playlist isn't itself evidence of DRM, and the
  /// master already passed its own check above.
  Future<bool> _isVariantDrmProtected(String variantUrl, Map<String, String>? extraHeaders) async {
    try {
      final fetch = await fetchText(Uri.parse(variantUrl), extraHeaders: extraHeaders);
      if (fetch.statusCode < 200 || fetch.statusCode >= 300) return false;
      return DrmPlaylistScanner.isHlsDrmProtected(fetch.body);
    } catch (_) {
      return false;
    }
  }

  MediaFormat formatFor({
    required String id,
    required String url,
    required String container,
    int? width,
    int? height,
    int? bitrate,
  }) {
    final isAudioOnly = container == 'mp3' || container == 'm4a';
    return MediaFormat(
      id: id,
      url: url,
      container: container,
      width: width,
      height: height,
      bitrate: bitrate ?? 0,
      hasVideo: !isAudioOnly,
      hasAudio: true,
    );
  }

  /// Orders formats so the ones with the most (and most trustworthy)
  /// metadata come first: an expanded HLS master's per-variant formats
  /// (real height/bitrate from `#EXT-X-STREAM-INF`), then DASH `.mpd`
  /// (single opaque format, variant parsing out of scope), then anything
  /// else (a plain file, or an m3u8 media playlist we could not expand).
  /// Stable within each tier (a plain loop, not `List.sort`, which Dart
  /// does not guarantee is stable) so dedupe/discovery order survives -
  /// which is also how a caller's own context-backed-first ordering of the
  /// *candidates* it expanded (see `GenericExtractor`) carries through to
  /// same-tier formats here.
  List<MediaFormat> orderFormats(List<MediaFormat> formats) {
    final hlsWithHeight = <MediaFormat>[];
    final mpd = <MediaFormat>[];
    final rest = <MediaFormat>[];
    for (final format in formats) {
      if (format.container == 'm3u8' && format.height != null) {
        hlsWithHeight.add(format);
      } else if (format.container == 'mpd') {
        mpd.add(format);
      } else {
        rest.add(format);
      }
    }
    return [...hlsWithHeight, ...mpd, ...rest];
  }
}
