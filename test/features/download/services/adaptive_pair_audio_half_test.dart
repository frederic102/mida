import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/download/format_request_context.dart';
import 'package:mida/core/extractors/format_selector.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/features/download/services/adaptive_pair_downloader.dart';
import 'package:mida/features/download/services/download_service_io.dart';

import 'media_download_pipeline_test_fakes.dart';

/// Phase 6 round 3, Codex cross-review #1 (blocker): the adaptive audio
/// half must ALWAYS be downloaded. A `declaredDuration ??= await
/// _downloadHalf(audio...)` short-circuited the entire `await` whenever the
/// video half had already reported a declared duration, so the audio temp
/// was never written and the merge ran against a missing file. Split out
/// of `adaptive_pair_downloader_test.dart` only because that file sits at
/// the 400-line cap.
void main() {
  late Directory outDir;

  setUp(() async {
    outDir = await Directory.systemTemp.createTemp('mida_adaptive_audio_half_');
  });

  tearDown(() async {
    if (await outDir.exists()) await outDir.delete(recursive: true);
  });

  const video = MediaFormat(
    id: 'v1',
    url: 'https://example.invalid/video_720p.m3u8',
    container: 'm3u8',
    protocol: 'hls',
    videoCodec: 'avc1.4d401f',
    height: 720,
    hasVideo: true,
    hasAudio: false,
  );
  const audio = MediaFormat(
    id: 'a1',
    url: 'https://example.invalid/audio_en.m3u8',
    container: 'm3u8',
    protocol: 'hls',
    audioCodec: 'mp4a.40.2',
    hasVideo: false,
    hasAudio: true,
  );

  test('guard can fail: the audio half is downloaded even when the video half already declared a duration '
      '(round 3 Codex#1 - a `??= await` on the audio download skipped it entirely)', () async {
    final hlsDownloader = RecordingHlsDownloader()..declaredDuration = const Duration(seconds: 120);
    final downloader = AdaptivePairDownloader(
      hlsDownloader: hlsDownloader,
      downloaderFactory: () => throw StateError('StreamDownloader must never be used for an all-HLS pair'),
      merger: RecordingMerger(),
    );

    final downloaded = await downloader.download(
      selected: const SelectedFormats(video: video, audio: audio),
      options: const DownloadOptions(videoFormat: VideoFormat.mp4),
      baseName: 'audio half',
      outputDir: outDir.path,
      tempPrefix: '${outDir.path}/.mida_tmp_pair_0',
      requestContext: const FormatRequestContext({}, {}),
      duration: const Duration(seconds: 120),
    );

    expect(
      hlsDownloader.urlsRequested,
      unorderedEquals(['https://example.invalid/video_720p.m3u8', 'https://example.invalid/audio_en.m3u8']),
      reason: 'guard can fail: with the `??=` short-circuit the video half alone was requested and the audio '
          'temp never existed, so the merge had nothing to mux',
    );
    expect(downloaded.declaredDuration, const Duration(seconds: 120),
        reason: 'the video half still wins the declared duration; the audio half only fills in a missing one');
  });

  test('the audio half supplies the declared duration only when the video half had none', () async {
    final hlsDownloader = _VideoSilentHlsDownloader(audioDeclared: const Duration(seconds: 90));
    final downloader = AdaptivePairDownloader(
      hlsDownloader: hlsDownloader,
      downloaderFactory: () => throw StateError('unused'),
      merger: RecordingMerger(),
    );

    final downloaded = await downloader.download(
      selected: const SelectedFormats(video: video, audio: audio),
      options: const DownloadOptions(videoFormat: VideoFormat.mp4),
      baseName: 'audio half fallback',
      outputDir: outDir.path,
      tempPrefix: '${outDir.path}/.mida_tmp_pair_1',
      requestContext: const FormatRequestContext({}, {}),
      duration: null,
    );

    expect(hlsDownloader.urlsRequested, hasLength(2));
    expect(downloaded.declaredDuration, const Duration(seconds: 90));
  });
}

/// Returns no declared duration for the video half and a fixed one for the
/// audio half, so the `??` fallback direction is observable.
class _VideoSilentHlsDownloader extends RecordingHlsDownloader {
  final Duration audioDeclared;

  _VideoSilentHlsDownloader({required this.audioDeclared});

  @override
  Future<Duration?> downloadVerified({
    required String url,
    required String outputPath,
    Map<String, String> headers = const {},
    bool audioOnly = false,
    List<String> audioCodecArgs = const ['-c:a', 'aac'],
    Duration? totalDuration,
    void Function(double progress)? onProgress,
    void Function(String message)? onStatus,
    Map<String, List<CookieEntry>>? cookiesByDomain,
    String? sourceAudioCodec,
    bool? segmentsAreTransportStream,
    Duration? processTimeout,
  }) async {
    await super.downloadVerified(
      url: url,
      outputPath: outputPath,
      headers: headers,
      audioOnly: audioOnly,
      audioCodecArgs: audioCodecArgs,
      totalDuration: totalDuration,
      onProgress: onProgress,
      onStatus: onStatus,
      cookiesByDomain: cookiesByDomain,
      sourceAudioCodec: sourceAudioCodec,
      segmentsAreTransportStream: segmentsAreTransportStream,
      processTimeout: processTimeout,
    );
    return url.contains('audio_en') ? audioDeclared : null;
  }
}
