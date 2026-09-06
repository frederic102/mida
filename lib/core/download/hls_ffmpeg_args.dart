import 'package:flutter/foundation.dart';

/// Thrown by [HlsFfmpegArgs.build] when a header name is not a valid RFC
/// 7230 token, or when a header value carries a CR or LF: passed through
/// unchecked, either could break out of the intended `-headers`/
/// `-user_agent` value and inject an arbitrary extra HTTP header (or,
/// depending on how ffmpeg's arg splitting treats the resulting string,
/// additional ffmpeg options) into the request ffmpeg sends to fetch the
/// manifest/segments. Header names and values here often come from a
/// remote page's own response (`Set-Cookie`, `Referer` chains forwarded
/// by `BrowserCaptureExtractor`), so they are attacker influenced, not
/// just our own code's literals.
class HeaderInjectionException implements Exception {
  final String message;
  const HeaderInjectionException(this.message);

  @override
  String toString() => 'HeaderInjectionException: $message';
}

/// The pure ffmpeg argument builder for `HlsFfmpegDownloader`, split out
/// of that file so both stay under this project's 400-line cap. Nothing
/// here does I/O, spawns a process, or checks a host: it turns a URL, an
/// output path and a header map into an argv list, and refuses input it
/// cannot express safely.
class HlsFfmpegArgs {
  const HlsFfmpegArgs._();

  static const _mp4FamilyContainers = {'mp4', 'm4a', 'mov'};

  /// `sourceAudioCodec` prefixes that are definitely not AAC - `-bsf:a
  /// aac_adtstoasc` only ever makes sense for an ADTS AAC bitstream, so a
  /// stream confirmed to carry one of these must never get it (phase 6,
  /// `docs/plan-phase6-av-pairing.md` trap 2: applying it to a non-AAC
  /// stream, or to AAC that is already ISO-BMFF-framed rather than
  /// ADTS-framed, makes ffmpeg fail outright rather than no-op).
  static const _nonAacAudioCodecPrefixes = ['ec-3', 'ac-3', 'opus', 'vorbis', 'flac', 'alac'];

  /// Every other control character besides CR/LF (which [sanitizeHeader]
  /// rejects outright): stripped rather than rejected, since these cannot
  /// break out of the header block the way CR/LF can, but still have no
  /// legitimate place in an HTTP header. Applies to header *values* only.
  static final _otherControlChars = RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]');

  /// RFC 7230 section 3.2.6 `token` - the complete grammar a header field
  /// name must match. Phase 6 B-R5: a name is never repaired by stripping
  /// characters out of it (the old behavior), because a stripped name
  /// silently becomes a *different* header than the one the source asked
  /// for - `X-Auth\x00: v` quietly turning into `X-Auth: v` is a header
  /// this app invented. Anything outside the grammar (a space, a colon, a
  /// quote, a control character, an empty name) is refused outright.
  static final _headerNameToken = RegExp(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$");

  /// Builds ffmpeg's argv. [audioOnly] switches from `-c copy` (keep both
  /// streams as-is) to `-vn` + an explicit audio codec (for an audio-only
  /// download request, including the "extract audio from a muxed/HLS
  /// source because no dedicated audio-only stream exists" fallback -
  /// `FormatSelector.needsAudioExtraction`). `-protocol_whitelist` locks
  /// ffmpeg's demuxer down to `https,tcp,tls,crypto` (plus `http` only
  /// when [url] itself is a plain-http manifest - never unconditionally,
  /// so an https manifest cannot have a referenced segment silently
  /// downgrade the connection) - never `file`/`concat`/`subfile`, so a
  /// malicious manifest cannot redirect a referenced segment through
  /// those to read or assemble local files. Does not itself verify the
  /// manifest or what it references resolve to an allowed host - callers
  /// must go through `HlsFfmpegDownloader.downloadVerified` for that.
  static List<String> build({
    required String url,
    required String outputPath,
    Map<String, String> headers = const {},
    bool audioOnly = false,
    List<String> audioCodecArgs = const ['-c:a', 'aac'],
    // Phase 6 trap 2: null (the default) means "unknown, assume the
    // legacy shape this bsf exists for" (a `.ts`-segmented HLS source
    // with ADTS AAC audio) - preserves the pre-phase-6 behavior for every
    // existing caller that does not pass these.
    String? sourceAudioCodec,
    bool? segmentsAreTransportStream,
  }) {
    final scheme = Uri.tryParse(url)?.scheme.toLowerCase();
    final allowedProtocols = ['https', 'tcp', 'tls', 'crypto'];
    if (scheme == 'http') {
      allowedProtocols.insert(0, 'http');
      debugPrint('HlsFfmpegDownloader: manifest URL is plain http; allowing "http" in -protocol_whitelist: $url');
    }
    final args = <String>['-y', '-protocol_whitelist', allowedProtocols.join(',')];

    // Every name is validated before anything is emitted, so a bad name
    // anywhere in the map fails the whole call rather than producing a
    // partially-built header blob.
    headers.keys.forEach(assertValidHeaderName);

    final userAgent = headers['User-Agent'];
    if (userAgent != null) args.addAll(['-user_agent', sanitizeHeader('User-Agent', userAgent)]);

    final headerLines = headers.entries
        .where((e) => e.key.toLowerCase() != 'user-agent')
        .map((e) => '${e.key}: ${sanitizeHeader(e.key, e.value)}')
        .join('\r\n');
    if (headerLines.isNotEmpty) args.addAll(['-headers', '$headerLines\r\n']);

    args.addAll(['-i', url]);
    if (audioOnly) {
      args.addAll(['-vn', ...audioCodecArgs]);
    } else {
      args.addAll(['-c', 'copy']);
      if (shouldApplyAdtsToAsc(
        outputPath: outputPath,
        sourceAudioCodec: sourceAudioCodec,
        segmentsAreTransportStream: segmentsAreTransportStream,
      )) {
        args.addAll(['-bsf:a', 'aac_adtstoasc']);
      }
    }
    args.addAll(['-progress', 'pipe:1', '-nostats', '-loglevel', 'error', outputPath]);
    return args;
  }

  /// Phase 6 B-R5: refuses a header field [name] that is not a valid RFC
  /// 7230 token (see [_headerNameToken]). Never edits the name.
  static void assertValidHeaderName(String name) {
    if (_headerNameToken.hasMatch(name)) return;
    throw HeaderInjectionException(
      'Refusing header name "$name": it is not a valid RFC 7230 header field name (token). Header names are '
      'rejected rather than repaired, because silently stripping characters out of one turns it into a '
      'different header than the source actually asked for.',
    );
  }

  /// Rejects a header [label]'s [value] outright if it contains a CR or
  /// LF (would break out of the intended header line entirely), and
  /// strips any other control character (has no legitimate use in a
  /// header but cannot by itself inject a new one).
  static String sanitizeHeader(String label, String value) {
    if (value.contains('\r') || value.contains('\n')) {
      throw HeaderInjectionException(
        'Refusing header "$label": its value contains a CR or LF, which could inject an extra header.',
      );
    }
    return value.replaceAll(_otherControlChars, '');
  }

  static String _extensionOf(String path) {
    final dot = path.lastIndexOf('.');
    return dot == -1 || dot == path.length - 1 ? '' : path.substring(dot + 1).toLowerCase();
  }

  /// Phase 6 trap 2: `-bsf:a aac_adtstoasc` only ever makes sense for an
  /// ADTS-framed AAC bitstream (real for `.ts`-segmented HLS audio),
  /// never for a codec that plainly is not AAC at all ([sourceAudioCodec]
  /// starts with one of [_nonAacAudioCodecPrefixes]) or for audio known
  /// to already be ISO-BMFF-framed ([segmentsAreTransportStream]
  /// explicitly `false` - fMP4/CMAF segments) - either would make ffmpeg
  /// fail outright ("Error parsing ADTS frame header") rather than
  /// harmlessly no-op. Everything else keeps the pre-phase-6 default of
  /// applying it for any mp4-family output.
  static bool shouldApplyAdtsToAsc({
    required String outputPath,
    String? sourceAudioCodec,
    bool? segmentsAreTransportStream,
  }) {
    if (!_mp4FamilyContainers.contains(_extensionOf(outputPath))) return false;
    final codec = sourceAudioCodec?.toLowerCase();
    if (codec != null && _nonAacAudioCodecPrefixes.any(codec.startsWith)) return false;
    if (segmentsAreTransportStream == false) return false;
    return true;
  }
}
