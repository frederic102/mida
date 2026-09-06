import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/download/media_merger.dart';
import 'package:mida/core/download/output_stream_prober.dart';
import 'package:mida/core/extractors/format_selector.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/features/download/services/download_outcome_verifier.dart';
import 'package:mida/features/download/services/download_service_io.dart';

/// Split out of `download_outcome_verifier_test.dart` purely for the
/// 400-line file cap: this file covers exactly one thing (phase 6 round 4,
/// S-R4-4, Gadfly#1 / Codex#3) - `verifyOutput` must not silently accept a
/// video download when ffprobe could not be started (`streamTypes` came
/// back null) for a candidate that itself claims to carry both video and
/// audio. The rest of `verifyOutput`'s behavior (missing/empty output,
/// track-mismatch shapes, truncation, the genuinely-silent-source
/// acceptance path) is covered there.
///
/// `OutputStreamProber` is a plain (non-sealed) class, so extending it and
/// overriding [streamTypes] lets these tests fix ffprobe's answer without
/// ever shelling out to a real ffprobe binary.
class _FixedProber extends OutputStreamProber {
  final Set<String>? types;
  _FixedProber(this.types) : super();

  @override
  Future<Set<String>?> streamTypes(String path) async => types;
}

MediaFormat _fmt({required bool hasVideo, required bool hasAudio}) => MediaFormat(
      id: 'f',
      url: 'https://example.invalid/f.mp4',
      container: 'mp4',
      hasVideo: hasVideo,
      hasAudio: hasAudio,
    );

void main() {
  group('DownloadOutcomeVerifier.verifyOutput: ffprobe unavailable (streamTypes null)', () {
    late Directory tempDir;
    late String outputPath;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('mida_verifier_ffprobe_test_');
      outputPath = '${tempDir.path}/out.mp4';
      await File(outputPath).writeAsBytes([1, 2, 3, 4]);
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    test(
      'guard can fail: a null probe result (ffprobe could not run) throws for a candidate that claims '
      'both audio and video, rather than silently accepting an unverified mislabel',
      () async {
        final verifier = DownloadOutcomeVerifier(prober: _FixedProber(null));

        await expectLater(
          verifier.verifyOutput(
            outputPath,
            SelectedFormats(muxed: _fmt(hasVideo: true, hasAudio: true)),
            DownloadType.video,
            null,
          ),
          throwsA(
            isA<MediaMergeException>().having(
              (e) => e.message,
              'message',
              allOf(contains('ffprobe unavailable'), contains('audio and video')),
            ),
          ),
          // Guard-can-fail (manually verified, see report): removing the
          // `selected.expectsVideoAndAudio` check in
          // `DownloadOutcomeVerifier.verifyOutput` (falling straight
          // through to `_checkNotTruncated` as round 3 did) makes this
          // test fail - the call completes instead of throwing.
        );
      },
    );

    test(
      'guard can fail: a null probe result also throws for an adaptive pair (video+audio candidates), '
      'not just the muxed shape',
      () async {
        final verifier = DownloadOutcomeVerifier(prober: _FixedProber(null));

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
          throwsA(isA<MediaMergeException>()),
        );
      },
    );

    test('a null probe result is still accepted for a video-only candidate (never claimed audio)', () async {
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
    });
  });
}
