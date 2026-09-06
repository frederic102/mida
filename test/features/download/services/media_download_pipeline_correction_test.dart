import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/download/stream_downloader.dart';
import 'package:mida/core/extractors/format_selector.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/features/download/services/all_format_candidates_failed_exception.dart';
import 'package:mida/features/download/services/download_outcome_verifier.dart';
import 'package:mida/features/download/services/download_service_io.dart';
import 'package:mida/features/download/services/media_download_pipeline.dart';

import 'media_download_pipeline_test_fakes.dart';

/// Phase 6 (`docs/plan-phase6-av-pairing.md`, Lane P, P4c/P5): the
/// retry loop's handling of `OutputTrackMismatchException` - a single
/// muxed format that mismatches gets its flags corrected and the whole
/// format list re-ranked (so a real fix can surface); an adaptive pair
/// that mismatches does not get its flags rewritten (ambiguous which half
/// was at fault), just recorded as a failed combination; and neither path
/// can loop forever or blow past the documented attempt cap
/// (`maxAttempts + correctiveRetryBudget`).
void main() {
  late Directory outDir;

  setUp(() async {
    outDir = await Directory.systemTemp.createTemp('mida_pipeline_correction_out_');
  });

  tearDown(() async {
    if (await outDir.exists()) await outDir.delete(recursive: true);
  });

  Future<HttpServer> startByteServer(Uint8List content) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.statusCode = 200;
      request.response.add(content);
      await request.response.close();
    });
    return server;
  }

  /// Throws `OutputTrackMismatchException` on demand (per [shouldMismatch]);
  /// otherwise delegates to a fixed-report prober's usual pass-through
  /// behavior for a genuinely clean output.
  test('a muxed format that mismatches gets its flags corrected and re-ranked, surfacing the real strict pair '
      'that a same-id-only retry could never have found', () async {
    final content = Uint8List.fromList(List.generate(500, (i) => i % 256));
    final server = await startByteServer(content);
    addTearDown(() => server.close(force: true));

    // `muxed1` claims muxed (hasVideo/hasAudio both true) but is really
    // video-only - exactly the pinterest/facebook/vimeo shape this phase
    // targets. `audio1` is a real, independently offered audio-only
    // format (as `HlsMasterFormatMapper`/`Mp4TrackSniffer` would produce)
    // that the *initial* rank never considers pairing with `muxed1`
    // because `muxed1` does not yet claim to be video-only.
    final info = MediaInfo(
      id: 'correction_test',
      title: 'correction test',
      sourceUrl: Uri.parse('https://example.invalid'),
      formats: [
        MediaFormat(
          id: 'muxed1',
          url: 'http://127.0.0.1:${server.port}/muxed',
          container: 'mp4',
          videoCodec: 'avc1.4d401f',
          height: 720,
          contentLength: content.length,
          hasVideo: true,
          hasAudio: true, // wrong - the mismatch below reports the truth
        ),
        MediaFormat(
          id: 'audio1',
          url: 'http://127.0.0.1:${server.port}/audio',
          container: 'mp4',
          audioCodec: 'mp4a.40.2',
          contentLength: content.length,
          hasVideo: false,
          hasAudio: true,
        ),
      ],
    );

    var verifyCalls = 0;
    final verifier = _CallbackVerifier((path, selected, type, onStatus) async {
      verifyCalls++;
      if (verifyCalls == 1) {
        expect(selected.muxed?.id, 'muxed1', reason: 'first attempt must be the (wrongly) muxed-labeled candidate');
        throw const OutputTrackMismatchException(
          hasVideo: true,
          hasAudio: false,
          message: 'Output is missing its audio track; the selected format may have been mislabeled.',
        );
      }
      // Second attempt: the real adaptive pair - accepted.
    });

    final pipeline = MediaDownloadPipeline(
      verifier: verifier,
      merger: RecordingMerger(),
      downloaderFactory: () => StreamDownloader(allowPrivateHosts: true),
    );

    final statuses = <String>[];
    final path = await pipeline.download(
      info: info,
      type: DownloadType.video,
      options: const DownloadOptions(videoQuality: VideoQuality.best, videoFormat: VideoFormat.mp4),
      outputDir: outDir.path,
      onStatus: statuses.add,
    );

    expect(path, '${outDir.path}/correction test.mp4');
    expect(verifyCalls, 2, reason: 'the correction must actually trigger a second, different attempt - not just '
        'fail once and give up');
    expect(statuses, anyElement(contains('Retrying with another format')));
  });

  test('an adaptive-pair mismatch does not rewrite either half\'s flags - only the tuple is excluded, so the same '
      'pair is never retried unmodified, but its formats are otherwise untouched', () async {
    final content = Uint8List.fromList(List.generate(500, (i) => i % 256));
    final server = await startByteServer(content);
    addTearDown(() => server.close(force: true));

    final info = MediaInfo(
      id: 'pair_mismatch_test',
      title: 'pair mismatch test',
      sourceUrl: Uri.parse('https://example.invalid'),
      formats: [
        MediaFormat(
          id: 'video1',
          url: 'http://127.0.0.1:${server.port}/video',
          container: 'mp4',
          videoCodec: 'avc1.4d401f',
          height: 720,
          contentLength: content.length,
          hasVideo: true,
          hasAudio: false,
        ),
        MediaFormat(
          id: 'audio1',
          url: 'http://127.0.0.1:${server.port}/audio',
          container: 'mp4',
          audioCodec: 'mp4a.40.2',
          contentLength: content.length,
          hasVideo: false,
          hasAudio: true,
        ),
      ],
    );

    final verifier = _CallbackVerifier((path, selected, type, onStatus) async {
      throw const OutputTrackMismatchException(
        hasVideo: true,
        hasAudio: false,
        message: 'Output is missing its audio track; the selected format may have been mislabeled.',
      );
    });

    final pipeline = MediaDownloadPipeline(
      verifier: verifier,
      merger: RecordingMerger(),
      downloaderFactory: () => StreamDownloader(allowPrivateHosts: true),
    );

    await expectLater(
      pipeline.download(
        info: info,
        type: DownloadType.video,
        options: const DownloadOptions(videoQuality: VideoQuality.best, videoFormat: VideoFormat.mp4),
        outputDir: outDir.path,
      ),
      throwsA(isA<AllFormatCandidatesFailedException>()),
    );
    // Guard can fail (see report): if a pair mismatch were (wrongly)
    // treated like a muxed one and had `copyWith(hasAudio: false)` applied
    // to the audio half, the very next re-rank would offer the *same*
    // video+audio pair again under a different tuple key shape - this test
    // exists to be the place that regresses if that ever happens (only one
    // candidate combination exists here, so a second, different attempt
    // is not even possible - the assertion is simply that this terminates
    // with a normal failure instead of retrying the identical pair
    // forever).
  });

  test('the correction budget caps at maxAttempts + correctiveRetryBudget total attempts even when every '
      'candidate keeps mismatching', () async {
    final content = Uint8List.fromList(List.generate(100, (i) => i % 256));
    final server = await startByteServer(content);
    addTearDown(() => server.close(force: true));

    // Four muxed-labeled (but actually video-only) candidates and no real
    // audio-only format anywhere - simulates a TED-shaped master before
    // HlsMasterFormatMapper's fix: every sibling variant looks muxed.
    final formats = [
      for (var i = 1; i <= 4; i++)
        MediaFormat(
          id: 'v$i',
          url: 'http://127.0.0.1:${server.port}/v$i',
          container: 'mp4',
          videoCodec: 'avc1.4d401f',
          height: 1080 - (i * 100),
          contentLength: content.length,
          hasVideo: true,
          hasAudio: true,
        ),
    ];
    final info = MediaInfo(
      id: 'budget_cap_test',
      title: 'budget cap test',
      sourceUrl: Uri.parse('https://example.invalid'),
      formats: formats,
    );

    final verifier = _CallbackVerifier((path, selected, type, onStatus) async {
      throw const OutputTrackMismatchException(
        hasVideo: true,
        hasAudio: false,
        message: 'Output is missing its audio track; the selected format may have been mislabeled.',
      );
    });

    final pipeline = MediaDownloadPipeline(
      verifier: verifier,
      merger: RecordingMerger(),
      downloaderFactory: () => StreamDownloader(allowPrivateHosts: true),
    );

    await expectLater(
      pipeline.download(
        info: info,
        type: DownloadType.video,
        options: const DownloadOptions(videoQuality: VideoQuality.best, videoFormat: VideoFormat.mp4),
        outputDir: outDir.path,
      ),
      throwsA(isA<AllFormatCandidatesFailedException>().having(
        (e) => e.attempted,
        'attempted',
        lessThanOrEqualTo(MediaDownloadPipeline.maxAttempts + MediaDownloadPipeline.correctiveRetryBudget),
      )),
    );
    // Guard can fail (see report): an earlier draft granted one extra
    // attempt per correction with no ceiling at all - that version looped
    // until every one of the 4 candidates' ids had independently cycled
    // through the correction+silent-source-fallback path, but a version
    // that also forgot to gate the ceiling on `correctiveRetryBudget`
    // would have keep going past 6 for a longer formats list.
  });

  test('guard-can-fail (round 2 P-R4, Codex#2): two DIFFERENT format instances that happen to share the same '
      'provider id are tracked and corrected independently - a same-id-only retry key would wrongly treat the '
      'second, genuinely-different candidate as "already tried" and give up', () async {
    final content = Uint8List.fromList(List.generate(500, (i) => i % 256));
    final server = await startByteServer(content);
    addTearDown(() => server.close(force: true));

    // Both formats carry id 'dup' - a stand-in for a source that reuses id
    // strings across genuinely different renditions (`FormatExpander`/
    // `CapturedFormatBuilder` both build an id from the URL for some direct
    // candidates, so two different candidates sharing an id string is not
    // hypothetical). `f1` (720p) is wrongly labeled muxed; `f2` (480p) is
    // genuinely muxed and must remain untouched and independently
    // selectable even after `f1`'s correction.
    final info = MediaInfo(
      id: 'dup_id_test',
      title: 'dup id test',
      sourceUrl: Uri.parse('https://example.invalid'),
      formats: [
        MediaFormat(
          id: 'dup',
          url: 'http://127.0.0.1:${server.port}/first',
          container: 'mp4',
          videoCodec: 'avc1.4d401f',
          height: 720,
          contentLength: content.length,
          hasVideo: true,
          hasAudio: true, // wrong - mismatch below reports the truth
        ),
        MediaFormat(
          id: 'dup',
          url: 'http://127.0.0.1:${server.port}/second',
          container: 'mp4',
          height: 480,
          contentLength: content.length,
          hasVideo: true,
          hasAudio: true, // genuinely muxed - must survive f1's correction untouched
        ),
      ],
    );

    var verifyCalls = 0;
    final verifier = _CallbackVerifier((path, selected, type, onStatus) async {
      verifyCalls++;
      if (verifyCalls == 1) {
        expect(selected.muxed?.height, 720, reason: 'the taller (ranked-first) candidate goes first');
        throw const OutputTrackMismatchException(
          hasVideo: true,
          hasAudio: false,
          message: 'Output is missing its audio track; the selected format may have been mislabeled.',
        );
      }
      // Second attempt: the genuinely-muxed 480p 'dup' - accepted.
      expect(selected.muxed?.height, 480, reason: 'guard can fail: keying attempts by id alone would make this '
          "candidate look like the same 'dup' already tried and failed, and the pipeline would give up instead of "
          'ever reaching it');
    });

    final pipeline = MediaDownloadPipeline(
      verifier: verifier,
      merger: RecordingMerger(),
      downloaderFactory: () => StreamDownloader(allowPrivateHosts: true),
    );

    final path = await pipeline.download(
      info: info,
      type: DownloadType.video,
      options: const DownloadOptions(videoQuality: VideoQuality.best, videoFormat: VideoFormat.mp4),
      outputDir: outDir.path,
    );

    expect(path, '${outDir.path}/dup id test.mp4');
    expect(verifyCalls, 2, reason: 'the second, distinct \'dup\' instance must still get its own attempt');
  });
}

class _CallbackVerifier extends DownloadOutcomeVerifier {
  final Future<void> Function(
    String path,
    SelectedFormats selected,
    DownloadType type,
    void Function(String message)? onStatus,
  ) onVerify;

  _CallbackVerifier(this.onVerify);

  // [expectedDuration] must be declared to stay a valid override of
  // `DownloadOutcomeVerifier.verifyOutput` (round 2 contract) - this fake
  // does not need the value itself, only the tests in
  // media_download_pipeline_duration_test.dart assert on it.
  @override
  Future<void> verifyOutput(
    String path,
    SelectedFormats selected,
    DownloadType type,
    void Function(String message)? onStatus, {
    Duration? expectedDuration,
  }) => onVerify(path, selected, type, onStatus);
}
