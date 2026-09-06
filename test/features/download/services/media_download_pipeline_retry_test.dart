import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/download/media_merger.dart';
import 'package:mida/core/download/output_stream_prober.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/features/download/services/all_format_candidates_failed_exception.dart';
import 'package:mida/features/download/services/download_outcome_verifier.dart';
import 'package:mida/features/download/services/download_service_io.dart';
import 'package:mida/features/download/services/media_download_pipeline.dart';

import 'media_download_pipeline_test_fakes.dart';

/// Retry-across-ranked-candidates and post-download sanity-check behavior
/// (the coordinator's format-fallback + ffprobe-sanity-check request).
/// Protocol-branch behavior lives in `media_download_pipeline_test.dart`
/// (split purely for the 400-line rule).
void main() {
  late Directory outDir;

  setUp(() async {
    outDir = await Directory.systemTemp.createTemp('mida_media_pipeline_retry_out_');
  });

  tearDown(() async {
    if (await outDir.exists()) await outDir.delete(recursive: true);
  });

  MediaInfo hlsMuxedInfo(String id, {int height = 720}) => MediaInfo(
        id: id,
        title: 'hls test $id',
        duration: const Duration(seconds: 10),
        sourceUrl: Uri.parse('https://example.invalid'),
        formats: [
          MediaFormat(
            id: 'v1',
            url: 'https://example.invalid/master.m3u8',
            container: 'm3u8',
            protocol: 'hls',
            height: height,
            hasVideo: true,
            hasAudio: true,
          ),
        ],
      );

  test('the first candidate failing to download does not fail the whole job: the next candidate is tried', () async {
    final hlsDownloader = RecordingHlsDownloader();
    var callCount = 0;
    final failFirstThenSucceed = CountingHlsDownloader(hlsDownloader, () {
      callCount++;
      return callCount == 1;
    });
    final pipeline = MediaDownloadPipeline(
      hlsDownloader: failFirstThenSucceed,
      verifier: DownloadOutcomeVerifier(prober: FixedProber({'video', 'audio'})),
    );

    final info = MediaInfo(
      id: 'multi_candidate',
      title: 'multi candidate test',
      duration: const Duration(seconds: 10),
      sourceUrl: Uri.parse('https://example.invalid'),
      formats: const [
        MediaFormat(id: 'v1080', url: 'https://example.invalid/1080.m3u8', container: 'm3u8', protocol: 'hls', height: 1080, bitrate: 5000000, hasVideo: true, hasAudio: true),
        MediaFormat(id: 'v720', url: 'https://example.invalid/720.m3u8', container: 'm3u8', protocol: 'hls', height: 720, bitrate: 2000000, hasVideo: true, hasAudio: true),
      ],
    );

    final statuses = <String>[];
    final progressValues = <double>[];
    final path = await pipeline.download(
      info: info,
      type: DownloadType.video,
      options: const DownloadOptions(videoFormat: VideoFormat.mp4),
      outputDir: outDir.path,
      onStatus: statuses.add,
      onProgress: progressValues.add,
    );

    expect(path, '${outDir.path}/multi candidate test.mp4');
    // Top-ranked (1080p) tried first and failed, then the 720p fallback.
    expect(hlsDownloader.urlsRequested, [
      'https://example.invalid/1080.m3u8',
      'https://example.invalid/720.m3u8',
    ]);
    expect(statuses, contains('Retrying with another format (2/2)...'));
    // Progress must restart at 0.0 for the second attempt, not continue
    // climbing from wherever the first attempt left off.
    expect(progressValues.first, 0.0);
    expect(progressValues.where((p) => p == 0.0).length, greaterThanOrEqualTo(2));
  });

  test('when every candidate fails, the error names the last cause, is capped at 3 attempts, '
      'and cleans up every attempt\'s temp', () async {
    final hlsDownloader = RecordingHlsDownloader()..shouldThrow = true;
    final pipeline = MediaDownloadPipeline(hlsDownloader: hlsDownloader);

    final info = MediaInfo(
      id: 'all_fail',
      title: 'all fail test',
      sourceUrl: Uri.parse('https://example.invalid'),
      formats: const [
        MediaFormat(id: 'v1', url: 'https://example.invalid/1.m3u8', container: 'm3u8', protocol: 'hls', height: 1080, hasVideo: true, hasAudio: true),
        MediaFormat(id: 'v2', url: 'https://example.invalid/2.m3u8', container: 'm3u8', protocol: 'hls', height: 720, hasVideo: true, hasAudio: true),
        MediaFormat(id: 'v3', url: 'https://example.invalid/3.m3u8', container: 'm3u8', protocol: 'hls', height: 480, hasVideo: true, hasAudio: true),
        MediaFormat(id: 'v4', url: 'https://example.invalid/4.m3u8', container: 'm3u8', protocol: 'hls', height: 360, hasVideo: true, hasAudio: true),
      ],
    );

    await expectLater(
      pipeline.download(
        info: info,
        type: DownloadType.video,
        options: const DownloadOptions(),
        outputDir: outDir.path,
      ),
      throwsA(isA<AllFormatCandidatesFailedException>()
          .having((e) => e.attempted, 'attempted', 3) // capped at 3 even though 4 candidates existed
          .having((e) => e.lastError, 'lastError', isA<MediaMergeException>())),
    );

    expect(hlsDownloader.urlsRequested, [
      'https://example.invalid/1.m3u8',
      'https://example.invalid/2.m3u8',
      'https://example.invalid/3.m3u8',
    ]);
    expect(outDir.listSync(), isEmpty, reason: 'a leftover temp/.part file was left behind across attempts');
  });

  test('guard-can-fail: a probe reporting a missing audio track moves on to the next candidate', () async {
    final hlsDownloader = RecordingHlsDownloader();
    // Reports video-only for every attempt, as if every candidate were a
    // mislabeled video-only rendition: the pipeline should exhaust all
    // (capped) attempts rather than accept the first one as "done".
    final pipeline = MediaDownloadPipeline(
      hlsDownloader: hlsDownloader,
      verifier: DownloadOutcomeVerifier(prober: FixedProber({'video'})),
    );

    final info = MediaInfo(
      id: 'video_only_mislabeled',
      title: 'video only mislabeled test',
      sourceUrl: Uri.parse('https://example.invalid'),
      formats: const [
        MediaFormat(id: 'v1', url: 'https://example.invalid/1.m3u8', container: 'm3u8', protocol: 'hls', height: 1080, hasVideo: true, hasAudio: true),
        MediaFormat(id: 'v2', url: 'https://example.invalid/2.m3u8', container: 'm3u8', protocol: 'hls', height: 720, hasVideo: true, hasAudio: true),
      ],
    );

    await expectLater(
      pipeline.download(
        info: info,
        type: DownloadType.video,
        options: const DownloadOptions(),
        outputDir: outDir.path,
      ),
      throwsA(isA<AllFormatCandidatesFailedException>().having(
        (e) => e.lastError.toString(),
        'lastError',
        contains('missing its audio track'),
      )),
    );

    // Both candidates were actually tried (the sanity check, not the
    // download itself, is what rejected each one).
    expect(hlsDownloader.urlsRequested, [
      'https://example.invalid/1.m3u8',
      'https://example.invalid/2.m3u8',
    ]);
    expect(outDir.listSync(), isEmpty, reason: 'a "successful" but sanity-check-failed output was left behind');
  });

  test('a genuinely silent source (no format anywhere claims audio) is accepted, not retried, '
      'and the status only appears after the probe (guard: ffprobe is never skipped based on extractor flags)', () async {
    final hlsDownloader = RecordingHlsDownloader();
    // The probe is injected (reporting video-only) rather than omitted:
    // per the coordinator's fix, ffprobe always runs for a video download
    // regardless of the candidate's own hasAudio flag - it is the PROBE
    // result, checked against that flag only afterward, that decides
    // accept-vs-retry and what status to show.
    final pipeline = MediaDownloadPipeline(
      hlsDownloader: hlsDownloader,
      verifier: DownloadOutcomeVerifier(prober: FixedProber({'video'})),
    );

    final info = MediaInfo(
      id: 'silent_reel',
      title: 'silent reel test',
      sourceUrl: Uri.parse('https://example.invalid'),
      formats: const [
        MediaFormat(
          id: 'v1',
          url: 'https://example.invalid/silent.m3u8',
          container: 'm3u8',
          protocol: 'hls',
          height: 720,
          hasVideo: true,
          hasAudio: false, // extractor reporting honestly: no audio track
        ),
      ],
    );

    final statuses = <String>[];
    final path = await pipeline.download(
      info: info,
      type: DownloadType.video,
      options: const DownloadOptions(),
      outputDir: outDir.path,
      onStatus: statuses.add,
    );

    expect(path, '${outDir.path}/silent reel test.mp4');
    expect(hlsDownloader.urlsRequested, ['https://example.invalid/silent.m3u8']);
    expect(statuses, contains('ffprobe confirms the source has no audio track.'));
  });

  test('a candidate that claims audio but is missing it is NOT confused with a genuinely silent source', () async {
    // Same shape as the test above, restated to make the distinction
    // explicit: `hasAudio: true` (claims audio) + a probe that finds none
    // => failure and retry, never the "confirms no audio track" status
    // (that is reserved for `hasAudio: false` candidates).
    final hlsDownloader = RecordingHlsDownloader();
    final pipeline = MediaDownloadPipeline(
      hlsDownloader: hlsDownloader,
      verifier: DownloadOutcomeVerifier(prober: FixedProber({'video'})),
    );

    final info = MediaInfo(
      id: 'claims_audio_but_missing',
      title: 'claims audio but missing test',
      sourceUrl: Uri.parse('https://example.invalid'),
      formats: const [
        MediaFormat(id: 'v1', url: 'https://example.invalid/only.m3u8', container: 'm3u8', protocol: 'hls', height: 720, hasVideo: true, hasAudio: true),
      ],
    );

    final statuses = <String>[];
    await expectLater(
      pipeline.download(
        info: info,
        type: DownloadType.video,
        options: const DownloadOptions(),
        outputDir: outDir.path,
        onStatus: statuses.add,
      ),
      throwsA(isA<AllFormatCandidatesFailedException>().having(
        (e) => e.toString(),
        'message',
        contains('missing its audio track'),
      )),
      reason: 'Gadfly round 3 #4: the exception TYPE alone does not pin the contract; the loud failure must '
          'name the missing audio track so a future edit cannot change the reason without going red',
    );
    expect(statuses, isNot(contains('ffprobe confirms the source has no audio track.')));
  });

  test('guard-can-fail: the probe is called even for a hasAudio: false candidate '
      '(never skipped based on the extractor flag)', () async {
    final hlsDownloader = RecordingHlsDownloader();
    var probeCalled = false;
    final trackingProber = FixedProber({'video'});
    final pipeline = MediaDownloadPipeline(
      hlsDownloader: hlsDownloader,
      verifier: DownloadOutcomeVerifier(prober: _TrackingProber(trackingProber, () => probeCalled = true)),
    );

    final info = MediaInfo(
      id: 'silent_probe_called',
      title: 'silent probe called test',
      sourceUrl: Uri.parse('https://example.invalid'),
      formats: const [
        MediaFormat(
          id: 'v1',
          url: 'https://example.invalid/silent.m3u8',
          container: 'm3u8',
          protocol: 'hls',
          hasVideo: true,
          hasAudio: false,
        ),
      ],
    );

    await pipeline.download(
      info: info,
      type: DownloadType.video,
      options: const DownloadOptions(),
      outputDir: outDir.path,
    );

    expect(probeCalled, isTrue, reason: 'ffprobe must run even when the candidate says hasAudio: false');
  });

  test('a lower-than-requested quality is announced via onStatus', () async {
    final hlsDownloader = RecordingHlsDownloader();
    final pipeline = MediaDownloadPipeline(
      hlsDownloader: hlsDownloader,
      verifier: DownloadOutcomeVerifier(prober: FixedProber({'video', 'audio'})),
    );
    final info = hlsMuxedInfo('quality_mismatch', height: 720);

    final statuses = <String>[];
    await pipeline.download(
      info: info,
      type: DownloadType.video,
      options: const DownloadOptions(videoQuality: VideoQuality.p2160),
      outputDir: outDir.path,
      onStatus: statuses.add,
    );

    expect(statuses, contains('Requested 2160p, best available 720p.'));
  });
}

/// Delegates to [inner] but calls [onCalled] first, so a test can assert
/// the probe actually ran without depending on its return value alone.
class _TrackingProber extends OutputStreamProber {
  final OutputStreamProber inner;
  final void Function() onCalled;
  _TrackingProber(this.inner, this.onCalled);

  @override
  Future<Set<String>?> streamTypes(String path) async {
    onCalled();
    return inner.streamTypes(path);
  }
}
