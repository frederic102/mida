import 'dart:convert';

import '../browser_capture/format_capabilities.dart';

/// Decodes Facebook's `efg` query parameter, split out of `FormatExpander`
/// to keep that file under the project's 400-line cap.
///
/// Live-probe follow-up: a Facebook video (`NatGeoAnimals`) resolved 6
/// formats and every single one failed post-download with "Output is
/// missing its audio track" - Facebook exposes separate video-only and
/// audio-only DASH renditions as flat `.mp4` URLs distinguished only by
/// this parameter (base64-encoded JSON whose `vencode_tag` names the
/// rendition, e.g. `dash_ln_heaac_vbr3_audio` for audio-only or
/// `..._gen2_720p` for video-only), so every "format" `FormatExpander`
/// used to hand back for one of these URLs was actually half of a pair,
/// not the muxed file its container/extension alone implied.
class FacebookEfgDecoder {
  const FacebookEfgDecoder._();

  /// `vencode_tag` substrings naming an audio-only rendition.
  static const List<String> _audioOnlyMarkers = ['audio'];

  /// `vencode_tag` substrings/patterns naming a video-only rendition: a
  /// `gen<N>` generation tag, the literal word `video`, or a resolution
  /// suffix like `720p`.
  static const List<String> _videoOnlyMarkers = ['gen', 'video'];
  static final RegExp _resolutionSuffixPattern = RegExp(r'\d{3,4}p\b');

  /// Returns the video/audio capabilities [url]'s `efg` param implies, or
  /// null when [url] carries no `efg` param, or that param does not decode
  /// to a JSON object with a string `vencode_tag` - callers fall back to
  /// whatever other capability hint they have, or the safe muxed default,
  /// in that case.
  static FormatCapabilities? capabilitiesFromUrl(String url) {
    Uri uri;
    try {
      uri = Uri.parse(url);
    } catch (_) {
      return null;
    }
    final efg = uri.queryParameters['efg'];
    if (efg == null || efg.isEmpty) return null;

    final decodedJson = _tryDecodeBase64Json(efg);
    if (decodedJson == null) return null;
    dynamic parsed;
    try {
      parsed = jsonDecode(decodedJson);
    } catch (_) {
      return null;
    }
    if (parsed is! Map) return null;
    final vencodeTag = parsed['vencode_tag'];
    if (vencodeTag is! String) return null;

    final tag = vencodeTag.toLowerCase();
    if (_audioOnlyMarkers.any(tag.contains)) {
      return const FormatCapabilities(hasVideo: false, hasAudio: true);
    }
    if (_videoOnlyMarkers.any(tag.contains) || _resolutionSuffixPattern.hasMatch(tag)) {
      return const FormatCapabilities(hasVideo: true, hasAudio: false);
    }
    return null;
  }

  /// `efg`'s base64 is sometimes URL-safe, sometimes standard, and often
  /// arrives with its `=` padding stripped (common for a value embedded in
  /// a URL query string) - tries both alphabets, padding out to a multiple
  /// of 4 first, and gives up (returns null) rather than throwing if
  /// neither decodes.
  static String? _tryDecodeBase64Json(String raw) {
    for (final decoder in [base64Url, base64]) {
      try {
        var padded = raw.trim();
        final remainder = padded.length % 4;
        if (remainder != 0) padded += '=' * (4 - remainder);
        return utf8.decode(decoder.decode(padded));
      } catch (_) {
        continue;
      }
    }
    return null;
  }
}
