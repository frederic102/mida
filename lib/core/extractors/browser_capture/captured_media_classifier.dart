/// One media URL observed on the network while a headless browser rendered
/// a page, already classified to a container. [contentLength] (from the
/// response's `content-length` header, when present) is used only for
/// ranking candidates against each other; [mimeType] (the response's own
/// `Content-Type`, when present) is used only to decide whether the
/// resulting format has audio, video, or both - neither participates in
/// [CapturedMediaClassifier.classify]'s own accept/reject decision.
class CapturedMediaCandidate {
  final String url;
  final String container;
  final int? contentLength;
  final String? mimeType;

  const CapturedMediaCandidate({required this.url, required this.container, this.contentLength, this.mimeType});

  CapturedMediaCandidate copyWith({int? contentLength, String? mimeType}) => CapturedMediaCandidate(
        url: url,
        container: container,
        contentLength: contentLength ?? this.contentLength,
        mimeType: mimeType ?? this.mimeType,
      );

  @override
  String toString() => 'CapturedMediaCandidate($container, $url, len: $contentLength, mime: $mimeType)';

  @override
  bool operator ==(Object other) =>
      other is CapturedMediaCandidate &&
      other.url == url &&
      other.container == container &&
      other.contentLength == contentLength &&
      other.mimeType == mimeType;

  @override
  int get hashCode => Object.hash(url, container, contentLength, mimeType);
}

/// Pure classification for one `Network.responseReceived` observation:
/// (url, mimeType) -> a candidate format, or null if it should be ignored.
/// Spec: `docs/plan-browser-capture.md` "시퀀스" step 4 and "포맷 규칙".
///
/// Two independent ways a response counts as media:
///   A. `mimeType` is `video/*`, `audio/*`, or one of the HLS/DASH/generic
///      mimes AND the URL contains a recognized media extension.
///   B. The URL path or query contains `.m3u8` or `.mpd`, regardless of
///      mimeType (some CDNs serve manifests as `text/plain` or with no
///      Content-Type at all).
///
/// `.m4s` segment URLs satisfy condition A's extension check but are never
/// turned into their own candidate (they are a fragment of a manifest that
/// should already have been captured separately, not a downloadable whole).
class CapturedMediaClassifier {
  const CapturedMediaClassifier._();

  static const Set<String> _mimePrefixesRequiringExtension = {'video/', 'audio/'};

  static const Set<String> _exactMimesRequiringExtension = {
    'application/vnd.apple.mpegurl',
    'application/x-mpegurl',
    'application/dash+xml',
    'application/octet-stream',
  };

  /// `ts` (an HLS segment, `video/mp2t`) is recognized-but-excluded here
  /// for the same reason `m4s` is (see [classify]'s own `container == null`
  /// branch): matching it here, not just leaving it unrecognized, is what
  /// stops the mimeType-only fallback below from wrongly picking it up as
  /// its own whole-file candidate (guard-can-fail:
  /// `network_signal_recorder_test.dart` "a .ts segment response is
  /// tracked as a segment URL, never as its own candidate" goes red
  /// without `ts` in this list).
  static final RegExp _mediaExtensionPattern = RegExp(
    r'\.(mp4|m3u8|mpd|webm|m4s|ts)(?:[/?&#]|$)',
    caseSensitive: false,
  );

  static final RegExp _manifestExtensionPattern = RegExp(
    r'\.(m3u8|mpd)(?:[/?&#]|$)',
    caseSensitive: false,
  );

  static const Map<String, String> _extensionContainers = {
    'mp4': 'mp4',
    'm3u8': 'm3u8',
    'mpd': 'mpd',
    'webm': 'webm',
  };

  static CapturedMediaCandidate? classify(String url, String? mimeType) {
    final mime = (mimeType ?? '').toLowerCase();
    final mimeQualifies =
        _exactMimesRequiringExtension.contains(mime) || _mimePrefixesRequiringExtension.any(mime.startsWith);

    if (mimeQualifies) {
      final ext = _mediaExtensionPattern.firstMatch(url)?.group(1)?.toLowerCase();
      if (ext != null) {
        final container = _extensionContainers[ext];
        // A recognized-but-excluded extension (m4s) is a deliberate no: it
        // matched condition A but must not become its own format.
        return container == null ? null : CapturedMediaCandidate(url: url, container: container);
      }
      // No recognized extension anywhere in the URL at all - unlike the
      // ambiguous _exactMimesRequiringExtension catch-alls (which really
      // could be anything, so still require one), a real `video/*` or
      // `audio/*` Content-Type straight from the server is already about
      // as strong a media signal as exists. Some CDNs serve it from a
      // bare, extension-less signed path with no dotted extension at all
      // (docs/plan-phase5-coverage.md Lane A diagnostic, 2026-09-05:
      // vk.com's okcdn.ru video/audio segments, Bandcamp's `mp3-128` path
      // *segment* rather than a `.mp3` file extension - `.mp3` was not
      // even in [_mediaExtensionPattern] to begin with). Trust the
      // server's own mimeType instead of discarding real media traffic
      // for lacking a URL extension neither CDN happens to use.
      if (_mimePrefixesRequiringExtension.any(mime.startsWith)) {
        return CapturedMediaCandidate(url: url, container: _containerForMimeSubtype(mime));
      }
    }

    final manifestExt = _manifestExtensionPattern.firstMatch(url)?.group(1)?.toLowerCase();
    if (manifestExt != null) {
      return CapturedMediaCandidate(url: url, container: _extensionContainers[manifestExt]!);
    }

    return null;
  }

  /// Best-guess container from a `video/*`/`audio/*` mimeType's own
  /// subtype, for the extension-less fallback above - matches
  /// `SoundCloud`'s own established container vocabulary (`mp3`/`m4a`),
  /// not a made-up one.
  static String _containerForMimeSubtype(String mime) {
    final subtype = mime.contains('/') ? mime.split('/')[1] : '';
    if (subtype.contains('webm')) return 'webm';
    if (subtype.contains('mp4')) return subtype.startsWith('mp4') && mime.startsWith('audio/') ? 'm4a' : 'mp4';
    if (subtype.contains('mpeg') || subtype.contains('mp3')) return 'mp3';
    if (subtype.contains('ogg')) return 'ogg';
    if (subtype.contains('wav')) return 'wav';
    return 'mp4';
  }

  /// Classifies a URL alone, with no `Content-Type` available at all -
  /// for `Network.requestWillBeSent` (fires before any response exists)
  /// and `performance.getEntriesByType('resource')` backfill (never
  /// carries a mimeType either), both of which exist specifically to
  /// catch a media request [classify] would otherwise never see paired
  /// with a `Network.responseReceived` event (a cancelled/superseded
  /// request, or a CDP event ordering race). Unlike [classify], this
  /// trusts a `mp4`/`webm` extension in the URL on its own (not gated
  /// behind a `video/`/`audio/` mimeType prefix) - that gate exists only
  /// to protect [classify]'s otherwise-bare URL-extension check from
  /// false positives on `responseReceived`'s frequent unrelated-asset
  /// traffic; a URL observed at request time with no mimeType signal at
  /// all has nothing stronger to gate on regardless. `.m4s`/`.ts`
  /// fragment URLs are still never classified here either (same
  /// exclusion as [classify]; see [_extensionContainers] lacking an
  /// `m4s` entry).
  static CapturedMediaCandidate? classifyByUrlOnly(String url) {
    final ext = _mediaExtensionPattern.firstMatch(url)?.group(1)?.toLowerCase();
    if (ext != null) {
      final container = _extensionContainers[ext];
      if (container != null) return CapturedMediaCandidate(url: url, container: container);
    }

    final manifestExt = _manifestExtensionPattern.firstMatch(url)?.group(1)?.toLowerCase();
    if (manifestExt != null) {
      return CapturedMediaCandidate(url: url, container: _extensionContainers[manifestExt]!);
    }

    return null;
  }

  /// Container for a URL the live DOM has already confirmed is an actual
  /// `<video>`/`<source>` element's playing src (see
  /// [CapturedMediaRanker]) - unlike [classify], this never returns null.
  /// A site's real video CDN URL routinely carries no recognizable
  /// extension at all (a signed path with only query-string state, e.g.
  /// TikTok's), so a URL the browser is actually playing defaults to
  /// `mp4` rather than being dropped for "not looking like media".
  static String containerForKnownMediaUrl(String url) {
    final ext = _mediaExtensionPattern.firstMatch(url)?.group(1)?.toLowerCase();
    if (ext != null && ext != 'm4s') {
      final container = _extensionContainers[ext];
      if (container != null) return container;
    }
    return 'mp4';
  }

  /// Collapses a Range-fragmented request (`?range=0-1023` /
  /// `?bytes=0-1023`, whichever query key the CDN uses) down to the URL
  /// identifying the whole resource, so repeated byte-range GETs for the
  /// same file dedupe to one candidate.
  static String dedupeKey(String url) {
    Uri uri;
    try {
      uri = Uri.parse(url);
    } catch (_) {
      return url;
    }
    if (uri.queryParameters.isEmpty) return uri.toString();

    final filtered = Map<String, String>.from(uri.queryParameters)
      ..removeWhere((key, _) => key.toLowerCase() == 'range' || key.toLowerCase() == 'bytes');
    // `Uri.replace(queryParameters: null)` means "leave the query
    // unchanged", not "clear it" - an empty result must go through
    // `query: ''` instead, or the range/bytes param we just removed from
    // [filtered] would silently survive in the returned URL.
    return (filtered.isEmpty ? uri.replace(query: '') : uri.replace(queryParameters: filtered)).toString();
  }
}

/// Orders (and prunes) a page's captured media candidates so the real
/// playing video wins over an unrelated small asset that merely happened
/// to pass [CapturedMediaClassifier.classify] - the bug this exists to fix
/// (TikTok live probe, 2026-09): the network capture's only candidate was
/// a 0.2MB `sf16-website-login...ttwstatic.com` clip (a static site
/// asset with a real `.mp4` extension in its URL), not the post's actual
/// video (a signed CDN URL with no recognizable extension at all, so
/// [CapturedMediaClassifier.classify] never even considered it).
///
/// Three tiers, in priority order:
///   1. Candidates the live DOM confirms are an actual `<video>`/
///      `<source>` element's current URL (matched against [domVideoUrls]
///      with the query string ignored). A DOM element's URL not seen in
///      network capture at all is still trusted and synthesized into a
///      candidate here (`blob:` URLs excluded) - this is the fix for the
///      TikTok case above.
///   2. Everything else, sorted by `content-length` descending (unknown
///      length sorts last), with confirmed-tiny candidates (< 64KB)
///      dropped *once a confirmed-larger one exists* - a real video is
///      essentially never that small, but a login-page loop clip often
///      is.
///   3. Within that second tier only, hosts that look like a static-asset
///      CDN are dropped *once a non-static-host candidate exists* in the
///      same tier - a narrow tie-break, never the primary filter (it
///      never empties the list on its own).
class CapturedMediaRanker {
  const CapturedMediaRanker._();

  static const int _minBytesWhenALargerCandidateExists = 64 * 1024;

  static List<CapturedMediaCandidate> rank(List<CapturedMediaCandidate> candidates, List<String> domVideoUrls) {
    final trustedDomUrls = [
      for (final url in domVideoUrls)
        if (!url.toLowerCase().startsWith('blob:')) url,
    ];

    final byMatchKey = <String, CapturedMediaCandidate>{};
    for (final candidate in candidates) {
      byMatchKey.putIfAbsent(_stripQueryForMatch(candidate.url), () => candidate);
    }

    final domTier = <CapturedMediaCandidate>[];
    final consumedKeys = <String>{};
    for (final domUrl in trustedDomUrls) {
      final key = _stripQueryForMatch(domUrl);
      if (!consumedKeys.add(key)) continue; // A repeated <source> entry.
      domTier.add(
        byMatchKey[key] ?? CapturedMediaCandidate(url: domUrl, container: CapturedMediaClassifier.containerForKnownMediaUrl(domUrl)),
      );
    }

    var remaining = [
      for (final candidate in candidates)
        if (!consumedKeys.contains(_stripQueryForMatch(candidate.url))) candidate,
    ];

    remaining.sort((a, b) {
      final lengthA = a.contentLength;
      final lengthB = b.contentLength;
      if (lengthA == null && lengthB == null) return 0;
      if (lengthA == null) return 1; // Unknown length sorts last.
      if (lengthB == null) return -1;
      return lengthB.compareTo(lengthA); // Descending.
    });

    final hasConfirmedLargerCandidate =
        remaining.any((c) => c.contentLength != null && c.contentLength! >= _minBytesWhenALargerCandidateExists);
    if (hasConfirmedLargerCandidate) {
      remaining = remaining.where((c) => c.contentLength == null || c.contentLength! >= _minBytesWhenALargerCandidateExists).toList();
    }

    final hasNonStaticHostCandidate = remaining.any((c) => !_looksLikeStaticAssetHost(c.url));
    if (hasNonStaticHostCandidate) {
      remaining = remaining.where((c) => !_looksLikeStaticAssetHost(c.url)).toList();
    }

    return [...domTier, ...remaining];
  }

  static String _stripQueryForMatch(String url) {
    try {
      return Uri.parse(url).replace(query: '', fragment: '').toString();
    } catch (_) {
      return url;
    }
  }

  static bool _looksLikeStaticAssetHost(String url) {
    try {
      return Uri.parse(url).host.toLowerCase().contains('static');
    } catch (_) {
      return false;
    }
  }
}
