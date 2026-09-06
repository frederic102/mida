import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/download/media_merger.dart';
import 'package:mida/core/download/output_stream_prober.dart';
import 'package:mida/core/extractors/format_selector.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/features/download/services/download_outcome_verifier.dart';
import 'package:mida/features/download/services/download_service_io.dart';

/// `OutputStreamProber` is a plain (non-sealed) class, so extending it and
/// overriding [streamTypes] lets these tests fix ffprobe's answer without
/// ever shelling out to a real ffprobe binary.
class _FixedProber extends OutputStreamProber {
  final Set<String>? types;
  final Duration? fixedDuration;
  int streamTypesCalls = 0;
  int durationCalls = 0;
  _FixedProber(this.types, {this.fixedDuration}) : super();

  @override
  Future<Set<String>?> streamTypes(String path) async {
    streamTypesCalls++;
    return types;
  }

  @override
  Future<Duration?> duration(String path) async {
    durationCalls++;
    return fixedDuration;
  }
}

MediaFormat _fmt({required bool hasVideo, required bool hasAudio}) => MediaFormat(
      id: 'f',
      url: 'https://example.invalid/f.mp4',
      container: 'mp4',
      hasVideo: hasVideo,
      hasAudio: hasAudio,
    );

void main() {
  group('DownloadOutcomeVerifier.verifyOutput', () {
    late Directory tempDir;
    late String outputPath;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('mida_verifier_test_');
      outputPath = '${tempDir.path}/out.mp4';
      await File(outputPath).writeAsBytes([1, 2, 3, 4]);
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    test('a missing/empty output file throws MediaMergeException, not the phase 6 mismatch type', () async {
      await File(outputPath).delete();
      final verifier = DownloadOutcomeVerifier(prober: _FixedProber({'video', 'audio'}));

      await expectLater(
        verifier.verifyOutput(outputPath, const SelectedFormats(muxed: null), DownloadType.video, null),
        throwsA(isA<MediaMergeException>()),
      );
    });

    test('an audio-type download never runs the stream-kind probe (that check is video-only)', () async {
      final prober = _FixedProber(null); // would return "inconclusive" if called
      final verifier = DownloadOutcomeVerifier(prober: prober);
      await expectLater(
        verifier.verifyOutput(
          outputPath,
          SelectedFormats(muxed: _fmt(hasVideo: false, hasAudio: true)),
          DownloadType.audio,
          null,
        ),
        completes,
      );
      expect(prober.streamTypesCalls, 0);
      // No expectedDuration was supplied, so the truncation check has
      // nothing to compare against and never reaches ffprobe either.
      expect(prober.durationCalls, 0);
    });

    test(
      'a null probe result (ffprobe could not run) does not fail the download when the candidate never '
      'claimed audio',
      () async {
        final verifier = DownloadOutcomeVerifier(prober: _FixedProber(null));
        await expectLater(
          verifier.verifyOutput(
            outputPath,
            SelectedFormats(muxed: _fmt(hasVideo: true, hasAudio: false)),
            DownloadType.video,
            null,
          ),
          completes,
        );
      },
    );

    test(
      'guard can fail: a missing video track throws OutputTrackMismatchException (hasVideo: false), '
      'not MediaMergeException',
      () async {
        final verifier = DownloadOutcomeVerifier(prober: _FixedProber({'audio'}));

        await expectLater(
          verifier.verifyOutput(
            outputPath,
            SelectedFormats(muxed: _fmt(hasVideo: true, hasAudio: true)),
            DownloadType.video,
            null,
          ),
          throwsA(
            isA<OutputTrackMismatchException>()
                .having((e) => e.hasVideo, 'hasVideo', isFalse)
                .having((e) => e.hasAudio, 'hasAudio', isTrue)
                .having((e) => e.message, 'message', contains('missing its video track')),
          ),
        );
      },
    );

    test(
      'guard can fail: a missing audio track on a candidate that claimed audio (muxed) throws '
      'OutputTrackMismatchException (hasVideo: true, hasAudio: false)',
      () async {
        final verifier = DownloadOutcomeVerifier(prober: _FixedProber({'video'}));

        await expectLater(
          verifier.verifyOutput(
            outputPath,
            SelectedFormats(muxed: _fmt(hasVideo: true, hasAudio: true)),
            DownloadType.video,
            null,
          ),
          throwsA(
            isA<OutputTrackMismatchException>()
                .having((e) => e.hasVideo, 'hasVideo', isTrue)
                .having((e) => e.hasAudio, 'hasAudio', isFalse)
                .having((e) => e.message, 'message', contains('missing its audio track'))
                .having((e) => e.message, 'message', isNot(contains('MediaMergeException'))),
          ),
        );
      },
    );

    test(
      'guard can fail: a missing audio track on an adaptive pair (video+audio candidates) also throws, '
      'not just the muxed shape',
      () async {
        final verifier = DownloadOutcomeVerifier(prober: _FixedProber({'video'}));

        await expectLater(
          verifier.verifyOutput(
            outputPath,
            SelectedFormats(
              video: _fmt(hasVideo: true, hasAudio: false),
              audio: _fmt(hasVideo: false, hasAudio: true),
            ),
            DownloadType.video,
            null,
          ),
          throwsA(isA<OutputTrackMismatchException>()),
        );
      },
    );

    test(
      'a genuinely silent source (candidate never claimed audio) is accepted, not thrown, '
      'and onStatus reports it only after the probe',
      () async {
        final verifier = DownloadOutcomeVerifier(prober: _FixedProber({'video'}));
        final statuses = <String>[];

        await verifier.verifyOutput(
          outputPath,
          SelectedFormats(muxed: _fmt(hasVideo: true, hasAudio: false)),
          DownloadType.video,
          statuses.add,
        );

        expect(statuses, contains('ffprobe confirms the source has no audio track.'));
      },
    );

    test('a probe reporting both video and audio present never throws', () async {
      final verifier = DownloadOutcomeVerifier(prober: _FixedProber({'video', 'audio'}));

      await expectLater(
        verifier.verifyOutput(
          outputPath,
          SelectedFormats(muxed: _fmt(hasVideo: true, hasAudio: true)),
          DownloadType.video,
          null,
        ),
        completes,
      );
    });

    group('truncation check applies to audio downloads too (round 3, S-R3-3, Codex #11)', () {
      test(
        'guard can fail: a truncated audio download throws MediaMergeException even though no '
        'stream-kind check runs for audio',
        () async {
          final prober = _FixedProber(null, fixedDuration: const Duration(seconds: 10));
          final verifier = DownloadOutcomeVerifier(prober: prober);

          await expectLater(
            verifier.verifyOutput(
              outputPath,
              SelectedFormats(muxed: _fmt(hasVideo: false, hasAudio: true)),
              DownloadType.audio,
              null,
              expectedDuration: const Duration(seconds: 100),
            ),
            throwsA(isA<MediaMergeException>()),
          );
          // The stream-kind probe is still skipped for audio; only the
          // duration probe ran. Guard-can-fail (verified in the round 3
          // report): restoring round 2's bare `if (type !=
          // DownloadType.video) return;` makes this test go green-by-
          // completing instead of throwing, and durationCalls drops to 0.
          expect(prober.streamTypesCalls, 0);
          expect(prober.durationCalls, 1);
        },
      );

      test('an audio download at or above 90% of expectedDuration passes', () async {
        final prober = _FixedProber(null, fixedDuration: const Duration(seconds: 95));
        final verifier = DownloadOutcomeVerifier(prober: prober);

        await expectLater(
          verifier.verifyOutput(
            outputPath,
            SelectedFormats(muxed: _fmt(hasVideo: false, hasAudio: true)),
            DownloadType.audio,
            null,
            expectedDuration: const Duration(seconds: 100),
          ),
          completes,
        );
        expect(prober.durationCalls, 1);
      });

      test('a video download whose ffprobe could not be started still gets the truncation check', () async {
        // streamTypes returning null is the "could not run ffprobe at
        // all" shape; round 2 returned right there, skipping truncation.
        // Uses a candidate that never claimed audio - round 4's S-R4-4
        // check (above) short-circuits before ever reaching the
        // truncation check for a candidate that does claim both, so this
        // truncation-still-runs case needs one that does not.
        final prober = _FixedProber(null, fixedDuration: const Duration(seconds: 10));
        final verifier = DownloadOutcomeVerifier(prober: prober);

        await expectLater(
          verifier.verifyOutput(
            outputPath,
            SelectedFormats(muxed: _fmt(hasVideo: true, hasAudio: false)),
            DownloadType.video,
            null,
            expectedDuration: const Duration(seconds: 100),
          ),
          throwsA(isA<MediaMergeException>()),
        );
        expect(prober.durationCalls, 1);
      });
    });

    group('truncation check via expectedDuration (phase 6 round 2, S-R7)', () {
      test(
        'guard can fail: an output whose duration is well under 90% of expectedDuration throws '
        'MediaMergeException mentioning it is shorter than the source',
        () async {
          final verifier = DownloadOutcomeVerifier(
            prober: _FixedProber({'video', 'audio'}, fixedDuration: const Duration(seconds: 30)),
          );

          await expectLater(
            verifier.verifyOutput(
              outputPath,
              SelectedFormats(muxed: _fmt(hasVideo: true, hasAudio: true)),
              DownloadType.video,
              null,
              expectedDuration: const Duration(seconds: 100),
            ),
            throwsA(
              isA<MediaMergeException>().having(
                (e) => e.message,
                'message',
                contains('Output is shorter than the source'),
              ),
            ),
          );
        },
      );

      test('an output whose duration is at or above 90% of expectedDuration does not throw', () async {
        final verifier = DownloadOutcomeVerifier(
          prober: _FixedProber({'video', 'audio'}, fixedDuration: const Duration(seconds: 91)),
        );

        await expectLater(
          verifier.verifyOutput(
            outputPath,
            SelectedFormats(muxed: _fmt(hasVideo: true, hasAudio: true)),
            DownloadType.video,
            null,
            expectedDuration: const Duration(seconds: 100),
          ),
          completes,
        );
      });

      test('expectedDuration omitted entirely means no truncation check at all, even if the output is short',
          () async {
        final verifier = DownloadOutcomeVerifier(
          prober: _FixedProber({'video', 'audio'}, fixedDuration: const Duration(seconds: 1)),
        );

        await expectLater(
          verifier.verifyOutput(
            outputPath,
            SelectedFormats(muxed: _fmt(hasVideo: true, hasAudio: true)),
            DownloadType.video,
            null,
          ),
          completes,
        );
      });

      test('the prober being unable to read the output\'s duration (null) is not treated as a failure', () async {
        final verifier = DownloadOutcomeVerifier(
          prober: _FixedProber({'video', 'audio'}, fixedDuration: null),
        );

        await expectLater(
          verifier.verifyOutput(
            outputPath,
            SelectedFormats(muxed: _fmt(hasVideo: true, hasAudio: true)),
            DownloadType.video,
            null,
            expectedDuration: const Duration(seconds: 100),
          ),
          completes,
        );
      });
    });
  });
}
