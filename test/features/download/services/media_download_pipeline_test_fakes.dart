import 'dart:io';
import 'dart:typed_data';

import 'package:mida/core/download/hls_ffmpeg_downloader.dart';
import 'package:mida/core/download/media_merger.dart';
import 'package:mida/core/download/output_stream_prober.dart';
import 'package:mida/core/extractors/media_models.dart';

/// Shared test doubles for `media_download_pipeline_test.dart` and
/// `media_download_pipeline_retry_test.dart` (split across two files
/// purely to stay under the 400-line rule; both exercise the same
/// pipeline, so they share these fakes instead of each keeping a copy).

/// Records every `run` call instead of spawning a real ffmpeg process, and
/// writes a small dummy file at the path ffmpeg was asked to produce (the
/// last arg), so `MediaDownloadPipeline`'s temp-then-move and post-download
/// sanity check both have something real to work with.
class RecordingHlsDownloader extends HlsFfmpegDownloader {
  final List<String> urlsRequested = [];
  final List<Duration?> totalDurationsRequested = [];
  final List<List<String>> builtArgs = [];
  bool shouldThrow = false;

  /// Overridden so the real `downloadVerified` (which would otherwise
  /// fetch [url] as a real manifest before ever reaching the overridden
  /// `buildArgs`/`run` below) never actually hits the network: these
  /// tests use fake `https://example.invalid/...` URLs precisely so nothing
  /// here does real I/O.
  @override
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
    final args = buildArgs(
      url: url,
      outputPath: outputPath,
      headers: headers,
      audioOnly: audioOnly,
      audioCodecArgs: audioCodecArgs,
    );
    await run(args, totalDuration: totalDuration, onProgress: onProgress);
  }

  @override
  Future<void> run(
    List<String> args, {
    Duration? totalDuration,
    void Function(double progress)? onProgress,
    Duration? processTimeout,
  }) async {
    totalDurationsRequested.add(totalDuration);
    onProgress?.call(1.0);
    if (shouldThrow) throw const MediaMergeException('simulated ffmpeg failure');
    await File(args.last).writeAsString('fake ffmpeg output');
  }

  @override
  List<String> buildArgs({
    required String url,
    required String outputPath,
    Map<String, String> headers = const {},
    bool audioOnly = false,
    List<String> audioCodecArgs = const ['-c:a', 'aac'],
  }) {
    urlsRequested.add(url);
    final args = super.buildArgs(
      url: url,
      outputPath: outputPath,
      headers: headers,
      audioOnly: audioOnly,
      audioCodecArgs: audioCodecArgs,
    );
    builtArgs.add(args);
    return args;
  }
}

/// Wraps a real [RecordingHlsDownloader], failing the call (as decided by
/// [shouldFailThisCall]) instead of ever reaching it, so a retry test can
/// make "the first candidate download fails, the next succeeds"
/// deterministic without depending on which URL was requested.
class CountingHlsDownloader extends HlsFfmpegDownloader {
  final HlsFfmpegDownloader inner;
  final bool Function() shouldFailThisCall;
  CountingHlsDownloader(this.inner, this.shouldFailThisCall);

  /// Same reasoning as `RecordingHlsDownloader.downloadVerified`: skip the
  /// real manifest fetch/host-check entirely and go straight to this
  /// fake's own (delegating) `buildArgs`/`run`.
  @override
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
    final args = buildArgs(
      url: url,
      outputPath: outputPath,
      headers: headers,
      audioOnly: audioOnly,
      audioCodecArgs: audioCodecArgs,
    );
    await run(args, totalDuration: totalDuration, onProgress: onProgress);
  }

  @override
  List<String> buildArgs({
    required String url,
    required String outputPath,
    Map<String, String> headers = const {},
    bool audioOnly = false,
    List<String> audioCodecArgs = const ['-c:a', 'aac'],
  }) {
    return inner.buildArgs(
      url: url,
      outputPath: outputPath,
      headers: headers,
      audioOnly: audioOnly,
      audioCodecArgs: audioCodecArgs,
    );
  }

  @override
  Future<void> run(
    List<String> args, {
    Duration? totalDuration,
    void Function(double progress)? onProgress,
    Duration? processTimeout,
  }) async {
    if (shouldFailThisCall()) {
      throw const MediaMergeException('simulated failure on this candidate');
    }
    await inner.run(args, totalDuration: totalDuration, onProgress: onProgress);
  }
}

/// Records every `run` call (the ffmpeg convert/remux step) and writes a
/// small dummy file at the output path (the last arg), same reasoning as
/// [RecordingHlsDownloader] above.
class RecordingMerger extends MediaMerger {
  final List<List<String>> runCalls = [];
  bool shouldThrow = false;

  @override
  Future<void> run(List<String> args) async {
    runCalls.add(args);
    if (shouldThrow) throw const MediaMergeException('simulated ffmpeg failure');
    await File(args.last).writeAsString('fake merged output');
  }
}

/// A prober that always reports a fixed set of stream types, regardless of
/// what is actually on disk - lets tests deterministically trigger (or
/// avoid) `DownloadOutcomeVerifier`'s "missing a stream" failure without
/// depending on a real ffprobe binary being on PATH.
class FixedProber extends OutputStreamProber {
  final Set<String>? types;
  FixedProber(this.types);

  @override
  Future<Set<String>?> streamTypes(String path) async => types;
}

Future<HttpServer> startByteServer(Uint8List content) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    request.response.statusCode = 200;
    request.response.add(content);
    await request.response.close();
  });
  return server;
}
