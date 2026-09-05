/// Pure (no network) scanner for encryption signals inside an
/// already-fetched HLS or DASH manifest body, per the coordinator's Lane B
/// security follow-up: the existing DRM check
/// (`HtmlMediaSniffer._looksLikeDrmUrl`) only looks at the candidate URL's
/// own text (`/drm/`, `cbcs`, `widevine`, ...), so a clean-looking `.mpd`
/// or `.m3u8` URL whose actual manifest body carries real DRM key material
/// would previously sail straight through as a normal, downloadable
/// format. `FormatExpander` calls this on manifest bodies it already
/// fetches for other reasons (HLS master/variant expansion, and now an
/// explicit fetch for `.mpd` too - see its own doc).
class DrmPlaylistScanner {
  const DrmPlaylistScanner._();

  static final RegExp _extXKeyPattern = RegExp(r'#EXT-X-(?:SESSION-)?KEY:([^\r\n]*)', caseSensitive: false);
  static final RegExp _methodPattern = RegExp(r'METHOD=([A-Za-z0-9\-]+)', caseSensitive: false);
  static final RegExp _keyFormatPattern = RegExp(r'''KEYFORMAT="([^"]*)"''', caseSensitive: false);

  /// `METHOD` values that mean the segments are DRM-encrypted (Apple
  /// FairPlay's usual HLS encryption schemes). `AES-128` is deliberately
  /// NOT in this set: ffmpeg decrypts a plain AES-128 HLS stream natively
  /// given the `URI=` key URL in the same tag, so that stays a normal,
  /// downloadable format rather than being treated as DRM.
  static const Set<String> _drmMethods = {'sample-aes', 'sample-aes-ctr'};

  /// `KEYFORMAT` substrings that name a known DRM system regardless of
  /// `METHOD`: FairPlay's streaming key delivery format, Widevine's system
  /// UUID (`edef8ba9-79d6-4ace-a3c8-27dcd51d21ed`), PlayReady's system UUID
  /// (`9a04f079-9840-4286-ab92-e65be0885f95`), and PlayReady's bare scheme
  /// name - each commonly written as `urn:uuid:<uuid>` in a KEYFORMAT
  /// value.
  static const List<String> _drmKeyFormatMarkers = [
    'com.apple.streamingkeydelivery',
    'urn:uuid:edef8ba9', // Widevine system ID
    'urn:uuid:9a04f079', // PlayReady system ID
    'com.microsoft.playready',
  ];

  /// True when [playlistText] (an HLS master, media, or variant playlist)
  /// carries an `#EXT-X-KEY`/`#EXT-X-SESSION-KEY` tag whose `METHOD` is
  /// `SAMPLE-AES`/`SAMPLE-AES-CTR`, or whose `KEYFORMAT` names a known DRM
  /// system (FairPlay, Widevine, or PlayReady).
  static bool isHlsDrmProtected(String playlistText) {
    for (final match in _extXKeyPattern.allMatches(playlistText)) {
      final attrs = match.group(1) ?? '';
      final method = _methodPattern.firstMatch(attrs)?.group(1)?.toLowerCase();
      if (method != null && _drmMethods.contains(method)) return true;
      final keyFormat = _keyFormatPattern.firstMatch(attrs)?.group(1)?.toLowerCase();
      if (keyFormat != null && _drmKeyFormatMarkers.any(keyFormat.contains)) return true;
    }
    return false;
  }

  /// True when [manifestText] (a DASH `.mpd` body) carries a
  /// `ContentProtection` element (including one whose `schemeIdUri` names
  /// the Widevine or PlayReady system UUID directly), a `cenc:pssh` box, a
  /// `cenc:default_KID`/`default_KID` attribute, or a `KEYFORMAT` value -
  /// any of which mean the referenced segments use common encryption
  /// (Widevine/PlayReady DASH DRM).
  static bool isMpdDrmProtected(String manifestText) {
    final lower = manifestText.toLowerCase();
    return lower.contains('contentprotection') ||
        lower.contains('cenc:pssh') ||
        lower.contains('default_kid') ||
        lower.contains('keyformat') ||
        lower.contains('urn:uuid:edef8ba9') ||
        lower.contains('urn:uuid:9a04f079');
  }
}
