import '../browser_capture/format_capabilities.dart';
import '../media_models.dart';
import 'drm_playlist_scanner.dart';
import 'facebook_efg_decoder.dart';
import 'hls_playlist_parser.dart';
import 'network_budget.dart';

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
  final Future<FetchedBody> Function(Uri url, {Map<String, String>? extraHeaders, int? maxBytes}) fetchText;

  const FormatExpander({required this.fetchText});

  /// Cap on how many of a master's emitted variants get their own DRM
  /// verification fetch (security follow-up: PlayReady/alternate Widevine
  /// key formats sometimes only show up in a variant's own `#EXT-X-KEY`,
  /// not the master's, and checking only the *first* variant missed that
  /// for any master whose first-listed rendition happened to be clean).
  /// Reuses [NetworkBudget] as a simple per-call fetch counter, capped
  /// independently of the embed-follow step's own budget.
  static const int _maxVariantChecks = 8;

  /// Per-variant-check fetch size cap: a real HLS variant/media playlist
  /// is plain text, almost always well under this even for a long-running
  /// live stream's segment list, so 1MB is generous headroom while still
  /// bounding a pathological response (tighter than the general page-body
  /// cap, since this fetch's only purpose is scanning for a `#EXT-X-KEY`
  /// tag near the top of the file).
  static const int _maxVariantCheckBytes = 1024 * 1024;

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
    FormatCapabilities? capabilities,
  }) async {
    if (container == 'mpd') {
      return _expandMpd(
        url,
        container,
        extraHeaders: extraHeaders,
        width: width,
        height: height,
        bitrate: bitrate,
        capabilities: capabilities,
      );
    }
    if (container != 'm3u8') {
      return ExpandedFormats(
        formats: [
          formatFor(
            id: url,
            url: url,
            container: container,
            width: width,
            height: height,
            bitrate: bitrate,
            capabilities: capabilities,
          ),
        ],
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
        formats: [
          formatFor(
            id: url,
            url: url,
            container: container,
            width: width,
            height: height,
            bitrate: bitrate,
            capabilities: capabilities,
          ),
        ],
      );
    }

    // Some DRM signals (PlayReady, or an alternate Widevine KEYFORMAT)
    // only show up in a variant/media playlist's own `#EXT-X-KEY`, not the
    // master's, and different renditions of the same asset occasionally
    // carry different key material - checking only the first variant
    // missed any of that whenever the first-listed rendition happened to
    // be clean. Every variant is checked, budget permitting; a variant
    // that is actually confirmed DRM is dropped individually rather than
    // discarding the whole master, so a mixed-protection master still
    // surfaces its clean renditions. Only once every variant we could
    // check (or that budget let us check) turns out encrypted is the
    // whole candidate treated as DRM-only.
    final variantBudget = NetworkBudget(maxFetches: _maxVariantChecks);
    final keptVariants = <HlsVariant>[];
    for (final variant in variants) {
      if (!variantBudget.tryConsume()) {
        // Budget exhausted: cannot verify this one, so it is trusted as
        // before (fail-open on being unable to check, not on a positive
        // DRM finding - the same posture the mpd fetch above takes on a
        // network failure).
        keptVariants.add(variant);
        continue;
      }
      if (!await _isVariantDrmProtected(variant.url, extraHeaders)) {
        keptVariants.add(variant);
      }
    }

    if (keptVariants.isEmpty) {
      return const ExpandedFormats(drmDetected: true);
    }

    return ExpandedFormats(formats: [
      for (var i = 0; i < keptVariants.length; i++)
        formatFor(
          id: '$url#$i',
          url: keptVariants[i].url,
          container: 'm3u8',
          width: keptVariants[i].width,
          height: keptVariants[i].height,
          bitrate: keptVariants[i].bandwidth,
          capabilities: capabilities,
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
    FormatCapabilities? capabilities,
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
      formats: [
        formatFor(
          id: url,
          url: url,
          container: container,
          width: width,
          height: height,
          bitrate: bitrate,
          capabilities: capabilities,
        ),
      ],
    );
  }

  /// Fail-open (returns false, i.e. "not DRM") on any fetch failure: an
  /// unreachable variant playlist isn't itself evidence of DRM, and the
  /// master already passed its own check above. Capped at
  /// [_maxVariantCheckBytes] regardless of whatever general page-body cap
  /// the injected [fetchText] would otherwise apply.
  Future<bool> _isVariantDrmProtected(String variantUrl, Map<String, String>? extraHeaders) async {
    try {
      final fetch = await fetchText(
        Uri.parse(variantUrl),
        extraHeaders: extraHeaders,
        maxBytes: _maxVariantCheckBytes,
      );
      if (fetch.statusCode < 200 || fetch.statusCode >= 300) return false;
      return DrmPlaylistScanner.isHlsDrmProtected(fetch.body);
    } catch (_) {
      return false;
    }
  }

  /// Resolves [id]/[url]'s actual video/audio capabilities and builds the
  /// [MediaFormat]. Precedence: (1) an `efg`-carrying URL is Facebook's own
  /// unambiguous rendition tag, checked first regardless of what [capabilities]
  /// says; (2) [capabilities] (a decisive sibling `mimeType`/`type`/`codecs`
  /// reading `JsonMediaWalker` attached to this candidate); (3) the
  /// `mp3`/`m4a` container itself, which is already a confident (not
  /// guessed) audio-only signal; (4) otherwise the safe muxed default,
  /// flagged [MediaFormat.capabilitiesUnknown] since nothing above actually
  /// confirmed it.
  MediaFormat formatFor({
    required String id,
    required String url,
    required String container,
    int? width,
    int? height,
    int? bitrate,
    FormatCapabilities? capabilities,
  }) {
    final resolvedBitrate = bitrate ?? 0;

    if (container == 'mp3' || container == 'm4a') {
      return MediaFormat(
        id: id,
        url: url,
        container: container,
        width: width,
        height: height,
        bitrate: resolvedBitrate,
        hasVideo: false,
        hasAudio: true,
      );
    }

    final resolvedCapabilities = FacebookEfgDecoder.capabilitiesFromUrl(url) ?? capabilities;
    if (resolvedCapabilities != null) {
      return MediaFormat(
        id: id,
        url: url,
        container: container,
        width: width,
        height: height,
        bitrate: resolvedBitrate,
        hasVideo: resolvedCapabilities.hasVideo,
        hasAudio: resolvedCapabilities.hasAudio,
      );
    }

    return MediaFormat(
      id: id,
      url: url,
      container: container,
      width: width,
      height: height,
      bitrate: resolvedBitrate,
      hasVideo: true,
      hasAudio: true,
      capabilitiesUnknown: true,
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
