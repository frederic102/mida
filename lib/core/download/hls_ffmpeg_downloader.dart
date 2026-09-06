import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../extractors/media_models.dart';
import '../net/cookie_scope.dart';
import '../net/per_hop_credentials.dart';
import '../services/ffmpeg_locator.dart';
import 'hls_ffmpeg_args.dart';
import 'manifest_reference_scanner.dart';
import 'media_merger.dart';

export 'hls_ffmpeg_args.dart' show HeaderInjectionException;

/// Downloads an HLS (`MediaFormat.protocol == 'hls'`) or DASH (`'dash'`)
/// format directly through ffmpeg, which reads the manifest and remuxes the
/// stream in one step. Unlike `StreamDownloader` (plain ranged GETs of a
/// single file), it cannot fetch these: the "file" is a playlist/manifest
/// that references many segment URLs. Per `docs/plan-generic-extractor.md`:
/// `-user_agent`/`-headers` carry the format's request headers, `-c copy`
/// keeps the original codecs, and `-bsf:a aac_adtstoasc` remuxes the ADTS
/// AAC audio HLS segments carry into the ASC framing an mp4-family
/// container expects. The argument building itself lives in
/// [HlsFfmpegArgs]; this class owns the pre-flight manifest scan, the
/// credential decisions that scan informs, and the process run.
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

  /// Forwarded to [ManifestReferenceScanner.scanAndCheck]'s own DNS-answer
  /// (rebinding) check for every host it references - defaults to the real
  /// `InternetAddress.lookup`; tests inject a fake resolver so a fixture
  /// hostname's DNS answer never depends on this sandbox's real network.
  final Future<List<InternetAddress>> Function(String host) resolveHost;

  HlsFfmpegDownloader({
    Future<String> Function()? ffmpegPathResolver,
    HttpClient Function()? httpClientFactory,
    ManifestReferenceScanner? scanner,
    this.allowPrivateHosts = false,
    this.resolveHost = InternetAddress.lookup,
  })  : _ffmpegPathResolver = ffmpegPathResolver ?? FfmpegLocator.ffmpegPath,
        _scanner = scanner ?? ManifestReferenceScanner(httpClientFactory: httpClientFactory);

  /// Pure argument builder (unit tested without a real ffmpeg binary).
  /// Delegates to [HlsFfmpegArgs.build]; kept as an instance method
  /// because every existing caller and test reaches it through a
  /// downloader instance.
  List<String> buildArgs({
    required String url,
    required String outputPath,
    Map<String, String> headers = const {},
    bool audioOnly = false,
    List<String> audioCodecArgs = const ['-c:a', 'aac'],
    String? sourceAudioCodec,
    bool? segmentsAreTransportStream,
  }) =>
      HlsFfmpegArgs.build(
        url: url,
        outputPath: outputPath,
        headers: headers,
        audioOnly: audioOnly,
        audioCodecArgs: audioCodecArgs,
        sourceAudioCodec: sourceAudioCodec,
        segmentsAreTransportStream: segmentsAreTransportStream,
      );

  /// Verifies [url] and everything it (as a manifest) references resolve
  /// to an allowed host, builds ffmpeg's args, and runs it - the entry
  /// point `MediaDownloadPipeline` must use instead of calling
  /// [buildArgs]+[run] directly. Fetching the manifest ourselves first
  /// (rather than handing the bare URL straight to ffmpeg) is what makes
  /// the check possible at all: ffmpeg has no concept of "refuse to
  /// follow a reference to a private host", so by the time ffmpeg itself
  /// opened a bad segment URL it would already be too late.
  ///
  /// Returns the duration the manifest chain DECLARED (phase 6 B-R3-7):
  /// the `#EXTINF` sum of the first media playlist that carries one, or
  /// the MPD's `mediaPresentationDuration`, and null when the manifest
  /// said nothing. The caller passes it to `DownloadOutcomeVerifier` as
  /// the expected duration when the format list has none of its own,
  /// which is what catches a download that ffmpeg truncated but still
  /// exited 0 on.
  Future<Duration?> downloadVerified({
    required String url,
    required String outputPath,
    Map<String, String> headers = const {},
    bool audioOnly = false,
    List<String> audioCodecArgs = const ['-c:a', 'aac'],
    Duration? totalDuration,
    void Function(double progress)? onProgress,
    Map<String, List<CookieEntry>>? cookiesByDomain,
    String? sourceAudioCodec,
    bool? segmentsAreTransportStream,
    Duration? processTimeout,
    // Phase 6 B-R4-8 (Gadfly round 3): a caller (eventually the pipeline -
    // wiring that call site is a follow-up, not this lane's fence) can
    // learn a credential got stripped from what ffmpeg receives without
    // scraping debug logs. Optional and defaulted to null so no existing
    // caller is affected.
    void Function(String message)? onStatus,
  }) async {
    // Computed once and used for the manifest scan (phase 6 fix): the
    // scan used to run against the raw, unscoped [headers] only, so an
    // authenticated manifest requiring a domain-scoped cookie 403'd
    // during the scan even though the *download* right after it - which
    // already received the scoped cookie - would have succeeded and
    // reached real, possibly-unsafe segment references ffmpeg would then
    // follow unchecked.
    final scopedHeaders = _withScopedCookie(url, headers, cookiesByDomain);
    final scan = await _assertManifestSafe(url, scopedHeaders, cookiesByDomain);
    final args = buildArgs(
      url: url,
      outputPath: outputPath,
      headers: _headersForFfmpeg(scopedHeaders, scan, onStatus),
      audioOnly: audioOnly,
      audioCodecArgs: audioCodecArgs,
      sourceAudioCodec: sourceAudioCodec,
      // Phase 6 B-R4: a caller that knows the answer still wins; when it
      // does not (null - the common case, since a format's segment shape
      // is not visible from the format list), the scan we just did
      // already read the media playlists and can say. Only a manifest
      // that carried no signal at all falls through to buildArgs'
      // pre-phase-6 default.
      segmentsAreTransportStream: segmentsAreTransportStream ?? scan.segmentsAreTransportStream,
    );
    await run(args, totalDuration: totalDuration, onProgress: onProgress, processTimeout: processTimeout);
    return scan.declaredDuration;
  }

  /// Phase 6 B-R3-5, extended by B-R4-3. ffmpeg applies one `-headers`
  /// blob to the manifest AND to every segment, key, init map, rendition
  /// playlist and redirect hop it goes through, so any credential in that
  /// blob reaches every host the manifest touches. When the scan found a
  /// reference or redirect hop outside that credential's own scope,
  /// [PerHopCredentials.isCredentialHeader] decides what gets removed from
  /// what ffmpeg gets: not just `Cookie` (a session cookie) but also
  /// `Authorization` and `Proxy-Authorization` (a bearer/basic token or
  /// proxy credential, each just as capable of authenticating this app's
  /// own session to an attacker-controlled host as a cookie is) - the
  /// download proceeds without them rather than being refused.
  ///
  /// Why this replaced the refusal: streams whose segments legitimately
  /// live on a partner CDN were being blocked outright, and dropping the
  /// credential closes the leak just as completely. If the manifest
  /// genuinely needed a credential on those hosts, ffmpeg now fails
  /// honestly on a 401/403 instead of this app pretending the content is
  /// unsupported. The scanner's own manifest request keeps every
  /// credential (it is per-host scoped there), so the scan still sees the
  /// real manifest rather than a login wall.
  Map<String, String> _headersForFfmpeg(
    Map<String, String> headers,
    ManifestScanResult scan,
    void Function(String message)? onStatus,
  ) {
    if (scan.hostsOutsideCookieScope.isEmpty) return headers;
    final withoutCredentials = Map<String, String>.from(headers)
      ..removeWhere((name, _) => PerHopCredentials.isCredentialHeader(name));
    if (withoutCredentials.length == headers.length) return headers;
    final message =
        'HlsFfmpegDownloader: not sending your session credentials to ffmpeg for this download. This manifest '
        'references ${scan.hostsOutsideCookieScope.join(', ')}, which they do not belong to, and ffmpeg applies '
        'the same Cookie/Authorization headers to every host a manifest points at. If the download now fails '
        'with a 401/403, this source needs a credential on those hosts and cannot be fetched safely this way.';
    // B-R4-8: reported through the caller-supplied channel, not only the
    // debug log, so a UI can surface it to the person who started this
    // download instead of it being visible only in a console nobody reads.
    onStatus?.call(message);
    debugPrint(message);
    return withoutCredentials;
  }

  /// ffmpeg's own `-headers` applies identically to every request it makes
  /// for this one manifest and every segment/key/init URL it references
  /// (ffmpeg has no per-request-host header concept at all), so this can
  /// only scope to the manifest [url]'s own host - a partial mitigation,
  /// not the full per-request scoping `StreamDownloader` can do: it still
  /// stops a cookie for a *different, unrelated* domain in
  /// [cookiesByDomain] from riding along onto this manifest's own request,
  /// which a flattened header would not have stopped. [_headersForFfmpeg]
  /// then removes even this cookie when the scan proved the manifest
  /// points outside its scope.
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
  /// [allowPrivateHosts] only for the manifest's own origin), walks every
  /// playlist it chains into (variants, `#EXT-X-MEDIA` renditions, nested
  /// masters) within a bounded queue and a whole-scan deadline, and
  /// host-checks every reference it finds (segments, encryption keys,
  /// init segments/maps, DASH `BaseURL`/`SegmentTemplate`/
  /// `ContentProtection`, ...) before this method returns.
  /// [cookiesByDomain] is handed down so the scanner can also report
  /// references outside the scope of the cookie [headers] carries.
  Future<ManifestScanResult> _assertManifestSafe(
    String url,
    Map<String, String> headers,
    Map<String, List<CookieEntry>>? cookiesByDomain,
  ) {
    return _scanner.scanAndCheck(
      Uri.parse(url),
      headers,
      allowPrivateHosts: allowPrivateHosts,
      cookiesByDomain: cookiesByDomain,
      resolveHost: resolveHost,
    );
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
  ///
  /// Always awaits the process's own exit code before returning (and
  /// before the pipeline's caller ever attempts to move the `.part` file
  /// ffmpeg was writing to) - this is what makes the move safe to attempt
  /// at all; `FileMover`'s own `PathAccessException` retry (see its own
  /// doc) is a separate, further backstop against something *else*
  /// (Windows Defender/an indexer) transiently locking the file right
  /// after ffmpeg itself released it, not evidence this method returns
  /// early. [processTimeout], when set, kills ffmpeg (`SIGKILL`, so a
  /// stalled/hung process - a stuck network read mid-manifest, say -
  /// cannot block this forever) if it has not exited by then; opt-in and
  /// unset by default so a long real download is never cut short by a
  /// value this method cannot itself justify choosing.
  Future<void> run(
    List<String> args, {
    Duration? totalDuration,
    void Function(double progress)? onProgress,
    Duration? processTimeout,
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

    var timedOut = false;
    var exitCodeFuture = process.exitCode;
    if (processTimeout != null) {
      exitCodeFuture = exitCodeFuture.timeout(processTimeout, onTimeout: () {
        timedOut = true;
        process.kill(ProcessSignal.sigkill);
        return process.exitCode;
      });
    }
    final exitCode = await exitCodeFuture;
    await stdoutSub.cancel();
    await stderrSub.cancel();
    if (timedOut) {
      throw MediaMergeException(
        'ffmpeg did not finish within ${processTimeout!.inSeconds}s and was killed (stalled/hung process).',
      );
    }
    if (exitCode != 0) {
      throw MediaMergeException.fromStderr(stderrBuffer.toString());
    }
  }
}
