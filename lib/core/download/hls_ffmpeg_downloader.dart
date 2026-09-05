import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../extractors/media_models.dart';
import '../net/cookie_scope.dart';
import '../services/ffmpeg_locator.dart';
import 'manifest_reference_scanner.dart';
import 'media_merger.dart';

/// Thrown by [HlsFfmpegDownloader.buildArgs] when a header name or value
/// carries a CR or LF: passed through unchecked, either could break out of
/// the intended `-headers`/`-user_agent` value and inject an arbitrary
/// extra HTTP header (or, depending on how ffmpeg's arg splitting treats
/// the resulting string, additional ffmpeg options) into the request
/// ffmpeg sends to fetch the manifest/segments. Header values here often
/// come from a remote page's own response (`Set-Cookie`, `Referer` chains
/// forwarded by `BrowserCaptureExtractor`), so they are attacker
/// influenced, not just our own code's literals.
class HeaderInjectionException implements Exception {
  final String message;
  const HeaderInjectionException(this.message);

  @override
  String toString() => 'HeaderInjectionException: $message';
}

/// Downloads an HLS (`MediaFormat.protocol == 'hls'`) or DASH (`'dash'`)
/// format directly through ffmpeg, which reads the manifest and remuxes the
/// stream in one step. Unlike `StreamDownloader` (plain ranged GETs of a
/// single file), it cannot fetch these: the "file" is a playlist/manifest
/// that references many segment URLs. Per `docs/plan-generic-extractor.md`:
/// `-user_agent`/`-headers` carry the format's request headers, `-c copy`
/// keeps the original codecs, and `-bsf:a aac_adtstoasc` remuxes the ADTS
/// AAC audio HLS segments carry into the ASC framing an mp4-family
/// container expects - only applied when [outputPath]'s extension is
/// actually mp4-family ([_mp4FamilyContainers]); a webm/mkv output does not
/// need or want it (a non-AAC HLS/DASH source is still out of scope for
/// this pass, see `docs/plan-phase2b-wiring.md` follow-ups).
class HlsFfmpegDownloader {
  final Future<String> Function() _ffmpegPathResolver;
  final ManifestReferenceScanner _scanner;

  /// Exempts only the manifest URL's own host from
  /// [downloadVerified]'s private-host check - lets tests serve a
  /// manifest from a local `http://127.0.0.1` fixture server. Every URI
  /// the manifest itself references (variant playlists, segments, keys,
  /// maps, ... - see [ManifestReferenceScanner]) is always checked
  /// regardless, so a manifest that references a private host is still
  /// refused even in a test that sets this. Production code must never
  /// set this to true.
  final bool allowPrivateHosts;

  HlsFfmpegDownloader({
    Future<String> Function()? ffmpegPathResolver,
    HttpClient Function()? httpClientFactory,
    ManifestReferenceScanner? scanner,
    this.allowPrivateHosts = false,
  })  : _ffmpegPathResolver = ffmpegPathResolver ?? FfmpegLocator.ffmpegPath,
        _scanner = scanner ?? ManifestReferenceScanner(httpClientFactory: httpClientFactory);

  static const _mp4FamilyContainers = {'mp4', 'm4a', 'mov'};

  /// Every other control character besides CR/LF (which
  /// [_sanitizeHeader] rejects outright): stripped rather than rejected,
  /// since these cannot break out of the header block the way CR/LF can,
  /// but still have no legitimate place in an HTTP header.
  static final _otherControlChars = RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]');

  /// Pure argument builder (unit tested without a real ffmpeg binary).
  /// [audioOnly] switches from `-c copy` (keep both streams as-is) to
  /// `-vn` + an explicit audio codec (for an audio-only download request,
  /// including the "extract audio from a muxed/HLS source because no
  /// dedicated audio-only stream exists" fallback -
  /// `FormatSelector.needsAudioExtraction`). `-protocol_whitelist` locks
  /// ffmpeg's demuxer down to `https,tcp,tls,crypto` (plus `http` only
  /// when [url] itself is a plain-http manifest - never unconditionally,
  /// so an https manifest cannot have a referenced segment silently
  /// downgrade the connection) - never `file`/`concat`/`subfile`, so a
  /// malicious manifest cannot redirect a referenced segment through
  /// those to read or assemble local files. Does not itself verify the
  /// manifest or what it references resolve to an allowed host - callers
  /// must go through [downloadVerified], not `buildArgs`+`run` directly,
  /// for that.
  List<String> buildArgs({
    required String url,
    required String outputPath,
    Map<String, String> headers = const {},
    bool audioOnly = false,
    List<String> audioCodecArgs = const ['-c:a', 'aac'],
  }) {
    final scheme = Uri.tryParse(url)?.scheme.toLowerCase();
    final allowedProtocols = ['https', 'tcp', 'tls', 'crypto'];
    if (scheme == 'http') {
      allowedProtocols.insert(0, 'http');
      debugPrint('HlsFfmpegDownloader: manifest URL is plain http; allowing "http" in -protocol_whitelist: $url');
    }
    final args = <String>['-y', '-protocol_whitelist', allowedProtocols.join(',')];

    final userAgent = headers['User-Agent'];
    if (userAgent != null) args.addAll(['-user_agent', _sanitizeHeader('User-Agent', userAgent)]);

    final headerLines = headers.entries
        .where((e) => e.key.toLowerCase() != 'user-agent')
        .map((e) => '${_sanitizeHeader('header name', e.key)}: ${_sanitizeHeader(e.key, e.value)}')
        .join('\r\n');
    if (headerLines.isNotEmpty) args.addAll(['-headers', '$headerLines\r\n']);

    args.addAll(['-i', url]);
    if (audioOnly) {
      args.addAll(['-vn', ...audioCodecArgs]);
    } else {
      args.addAll(['-c', 'copy']);
      if (_mp4FamilyContainers.contains(_extensionOf(outputPath))) {
        args.addAll(['-bsf:a', 'aac_adtstoasc']);
      }
    }
    args.addAll(['-progress', 'pipe:1', '-nostats', '-loglevel', 'error', outputPath]);
    return args;
  }

  /// Rejects a header [label]'s [value] outright if it contains a CR or
  /// LF (would break out of the intended header line entirely), and
  /// strips any other control character (has no legitimate use in a
  /// header but cannot by itself inject a new one).
  static String _sanitizeHeader(String label, String value) {
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

  /// Verifies [url] and everything it (as a manifest) references resolve
  /// to an allowed host, builds ffmpeg's args, and runs it - the entry
  /// point `MediaDownloadPipeline` must use instead of calling
  /// [buildArgs]+[run] directly. Fetching the manifest ourselves first
  /// (rather than handing the bare URL straight to ffmpeg) is what makes
  /// the check possible at all: ffmpeg has no concept of "refuse to
  /// follow a reference to a private host", so by the time ffmpeg itself
  /// opened a bad segment URL it would already be too late.
  Future<void> downloadVerified({
    required String url,
    required String outputPath,
    Map<String, String> headers = const {},
    bool audioOnly = false,
    List<String> audioCodecArgs = const ['-c:a', 'aac'],
    Duration? totalDuration,
    void Function(double progress)? onProgress,
    Map<String, List<CookieEntry>>? cookiesByDomain,
  }) async {
    await _assertManifestSafe(url, headers);
    final args = buildArgs(
      url: url,
      outputPath: outputPath,
      headers: _withScopedCookie(url, headers, cookiesByDomain),
      audioOnly: audioOnly,
      audioCodecArgs: audioCodecArgs,
    );
    await run(args, totalDuration: totalDuration, onProgress: onProgress);
  }

  /// ffmpeg's own `-headers` applies identically to every request it makes
  /// for this one manifest and every segment/key/init URL it references
  /// (ffmpeg has no per-request-host header concept at all), so this can
  /// only scope to the manifest [url]'s own host - a partial mitigation,
  /// not the full per-request scoping `StreamDownloader` can do: it still
  /// stops a cookie for a *different, unrelated* domain in
  /// [cookiesByDomain] from riding along onto this manifest's own request,
  /// which a flattened header would not have stopped.
  Map<String, String> _withScopedCookie(
    String url,
    Map<String, String> headers,
    Map<String, List<CookieEntry>>? cookiesByDomain,
  ) {
    if (cookiesByDomain == null) return headers;
    final uri = Uri.tryParse(url);
    if (uri == null) return headers;
    final scoped = CookieScope.headerFor(uri, cookiesByDomain);
    return scoped.isEmpty ? headers : {...headers, 'Cookie': scoped};
  }

  /// Delegates the actual fetch-and-check work to
  /// [ManifestReferenceScanner]: fetches [url] (honoring
  /// [allowPrivateHosts] for that one hop only), and - for an HLS master
  /// playlist - recurses one level into each variant playlist too,
  /// host-checking every reference it finds (segments, encryption keys,
  /// init segments/maps, alternate renditions, DASH `BaseURL`/
  /// `SegmentTemplate`/`ContentProtection`, ...) before this method
  /// returns successfully.
  Future<void> _assertManifestSafe(String url, Map<String, String> headers) async {
    await _scanner.scanAndCheck(Uri.parse(url), headers, allowPrivateHosts: allowPrivateHosts);
  }

  /// Parses one line of ffmpeg's `-progress pipe:1` machine-readable
  /// output. `out_time_ms` is, despite the name, microseconds (a
  /// long-standing ffmpeg quirk); returns null for every other line
  /// (`frame=`, `fps=`, `progress=continue`, ...).
  static Duration? parseOutTime(String line) {
    final match = RegExp(r'^out_time_ms=(\d+)$').firstMatch(line.trim());
    if (match == null) return null;
    return Duration(microseconds: int.parse(match.group(1)!));
  }

  /// Runs ffmpeg with [args]. [onProgress] receives a 0.0-1.0 fraction
  /// computed from `out_time_ms` against [totalDuration]; omitted (never
  /// called) when [totalDuration] is null or zero, since the fraction is
  /// meaningless without a known total (e.g. the source did not report a
  /// duration).
  Future<void> run(
    List<String> args, {
    Duration? totalDuration,
    void Function(double progress)? onProgress,
  }) async {
    final ffmpegPath = await _ffmpegPathResolver();
    final process = await Process.start(ffmpegPath, args);
    final stderrBuffer = StringBuffer();

    final stdoutSub = process.stdout
        .transform(const SystemEncoding().decoder)
        .transform(const LineSplitter())
        .listen((line) {
      final elapsed = parseOutTime(line);
      if (elapsed == null || totalDuration == null || totalDuration.inMicroseconds <= 0) return;
      onProgress?.call((elapsed.inMicroseconds / totalDuration.inMicroseconds).clamp(0.0, 1.0));
    });
    final stderrSub =
        process.stderr.transform(const SystemEncoding().decoder).listen(stderrBuffer.write);

    final exitCode = await process.exitCode;
    await stdoutSub.cancel();
    await stderrSub.cancel();
    if (exitCode != 0) {
      throw MediaMergeException.fromStderr(stderrBuffer.toString());
    }
  }
}
