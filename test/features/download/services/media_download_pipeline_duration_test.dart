import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/format_selector.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/features/download/services/download_outcome_verifier.dart';
import 'package:mida/features/download/services/download_service_io.dart';
import 'package:mida/features/download/services/media_download_pipeline.dart';

import 'media_download_pipeline_test_fakes.dart';

/// Round 2 (`docs/plan-phase6-av-pairing.md`, Lane P, P-R9): the pipeline
/// must pass `expectedDuration: currentInfo.duration` to
/// `DownloadOutcomeVerifier.verifyOutput` (so a truncated merge can be
/// caught by comparing real output duration against what the source
/// reported - Lane S's S-R7), and every place that rebuilds a [MediaInfo]
/// must go through [MediaInfo.copyWith] rather than a hand-spelled field
/// list (the same class of bug that dropped `cookiesByDomain` in round 1,
/// C1/N1).
void main() {
  late Directory outDir;

  setUp(() async {
    outDir = await Directory.systemTemp.createTemp('mida_pipeline_duration_out_');
  });

  tearDown(() async {
    if (await outDir.exists()) await outDir.delete(recursive: true);
  });

  test('verifyOutput receives the MediaInfo\'s own duration (guard can fail: dropping `expectedDuration:` from the '
      'pipeline\'s call site makes this come back null even though the source reported one)', () async {
    final hlsDownloader = RecordingHlsDownloader();
    Duration? capturedDuration;
    var captured = false;
    final verifier = _CapturingVerifier((duration) {
      capturedDuration = duration;
      captured = true;
    });

    final pipeline = MediaDownloadPipeline(hlsDownloader: hlsDownloader, verifier: verifier);

    final info = MediaInfo(
      id: 'duration_test',
      title: 'duration test',
      duration: const Duration(minutes: 3, seconds: 20),
      sourceUrl: Uri.parse('https://example.invalid'),
      formats: const [
        MediaFormat(
          id: 'v1',
          url: 'https://example.invalid/1.m3u8',
          container: 'm3u8',
          protocol: 'hls',
          height: 720,
          hasVideo: true,
          hasAudio: true,
        ),
      ],
    );

    await pipeline.download(
      info: info,
      type: DownloadType.video,
      options: const DownloadOptions(),
      outputDir: outDir.path,
    );

    expect(captured, isTrue, reason: 'verifyOutput must actually run for a video download');
    expect(capturedDuration, const Duration(minutes: 3, seconds: 20));
  });

  test('a MediaInfo with no known duration, whose manifest declared none either, passes expectedDuration: null, '
      'not a stale non-null value', () async {
    final hlsDownloader = RecordingHlsDownloader();
    Duration? capturedDuration = const Duration(seconds: 1); // deliberately non-null sentinel
    final verifier = _CapturingVerifier((duration) => capturedDuration = duration);

    final pipeline = MediaDownloadPipeline(hlsDownloader: hlsDownloader, verifier: verifier);

    final info = MediaInfo(
      id: 'no_duration_test',
      title: 'no duration test',
      sourceUrl: Uri.parse('https://example.invalid'),
      formats: const [
        MediaFormat(
          id: 'v1',
          url: 'https://example.invalid/1.m3u8',
          container: 'm3u8',
          protocol: 'hls',
          height: 720,
          hasVideo: true,
          hasAudio: true,
        ),
      ],
    );

    await pipeline.download(
      info: info,
      type: DownloadType.video,
      options: const DownloadOptions(),
      outputDir: outDir.path,
    );

    expect(capturedDuration, isNull);
  });

  test('round 3 P-R3-5: when the source reported no duration, the one the MANIFEST declared is used instead', () async {
    final hlsDownloader = RecordingHlsDownloader()..declaredDuration = const Duration(minutes: 2, seconds: 30);
    Duration? capturedDuration;
    final verifier = _CapturingVerifier((duration) => capturedDuration = duration);

    final pipeline = MediaDownloadPipeline(hlsDownloader: hlsDownloader, verifier: verifier);

    final info = MediaInfo(
      id: 'declared_duration_test',
      title: 'declared duration test',
      sourceUrl: Uri.parse('https://example.invalid'),
      formats: const [
        MediaFormat(
          id: 'v1',
          url: 'https://example.invalid/1.m3u8',
          container: 'm3u8',
          protocol: 'hls',
          height: 720,
          hasVideo: true,
          hasAudio: true,
        ),
      ],
    );

    await pipeline.download(
      info: info,
      type: DownloadType.video,
      options: const DownloadOptions(),
      outputDir: outDir.path,
    );

    expect(capturedDuration, const Duration(minutes: 2, seconds: 30),
        reason: 'guard can fail: dropping `?? downloaded.declaredDuration` from the pipeline call site makes this '
            'null again, and a truncated download of a duration-less source goes unchecked');
  });

  test('round 3 P-R3-5: the source own reported duration still wins over the one the manifest declared', () async {
    final hlsDownloader = RecordingHlsDownloader()..declaredDuration = const Duration(seconds: 5);
    Duration? capturedDuration;
    final verifier = _CapturingVerifier((duration) => capturedDuration = duration);

    final pipeline = MediaDownloadPipeline(hlsDownloader: hlsDownloader, verifier: verifier);

    final info = MediaInfo(
      id: 'both_durations_test',
      title: 'both durations test',
      duration: const Duration(minutes: 4),
      sourceUrl: Uri.parse('https://example.invalid'),
      formats: const [
        MediaFormat(
          id: 'v1',
          url: 'https://example.invalid/1.m3u8',
          container: 'm3u8',
          protocol: 'hls',
          height: 720,
          hasVideo: true,
          hasAudio: true,
        ),
      ],
    );

    await pipeline.download(
      info: info,
      type: DownloadType.video,
      options: const DownloadOptions(),
      outputDir: outDir.path,
    );

    expect(capturedDuration, const Duration(minutes: 4),
        reason: 'a manifest chain that only declared its first playlist length must not shrink the '
            'expectation the extractor already stated');
  });
}

class _CapturingVerifier extends DownloadOutcomeVerifier {
  final void Function(Duration? expectedDuration) onVerify;
  _CapturingVerifier(this.onVerify);

  @override
  Future<void> verifyOutput(
    String path,
    SelectedFormats selected,
    DownloadType type,
    void Function(String message)? onStatus, {
    Duration? expectedDuration,
  }) async {
    onVerify(expectedDuration);
  }
}
