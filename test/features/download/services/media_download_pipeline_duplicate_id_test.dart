import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/features/download/services/download_outcome_verifier.dart';
import 'package:mida/features/download/services/download_service_io.dart';
import 'package:mida/features/download/services/media_download_pipeline.dart';

import 'media_download_pipeline_test_fakes.dart';

/// Residual follow-up (`docs/plan-phase6-av-pairing.md` "라운드 4 판결",
/// "중복 format id 테스트"). Round 2 (P-R4, Codex#2) moved the pipeline's
/// own attempt-tracking off `MediaFormat.id` and onto object identity
/// (`identityHashCode`, see `media_download_pipeline.dart`'s
/// `_tupleKey`/`_firstUntried`) precisely so two formats sharing the same
/// id but pointing at different URLs would not have the second one
/// silently marked "already tried" the moment the first one was. This test
/// is the end-to-end proof of that: both candidates below carry the id
/// `'dup'`, the first one is made to fail, and the download must still
/// succeed by falling through to the second.
void main() {
  late Directory outDir;

  setUp(() async {
    outDir = await Directory.systemTemp.createTemp('mida_media_pipeline_dup_id_out_');
  });

  tearDown(() async {
    if (await outDir.exists()) await outDir.delete(recursive: true);
  });

  test('two candidates sharing the same MediaFormat.id are both tried (identity, not id, keys the attempt)',
      () async {
    final hlsDownloader = RecordingHlsDownloader();
    var callCount = 0;
    // Fails only the very first call - the top-ranked candidate - so the
    // pipeline must reach the second one to succeed at all.
    final failFirstThenSucceed = CountingHlsDownloader(hlsDownloader, () {
      callCount++;
      return callCount == 1;
    });
    final pipeline = MediaDownloadPipeline(
      hlsDownloader: failFirstThenSucceed,
      verifier: DownloadOutcomeVerifier(prober: FixedProber({'video', 'audio'})),
    );

    final info = MediaInfo(
      id: 'duplicate_id_source',
      title: 'duplicate id pipeline test',
      duration: const Duration(seconds: 10),
      sourceUrl: Uri.parse('https://example.invalid'),
      formats: const [
        MediaFormat(
          id: 'dup',
          url: 'https://example.invalid/1080.m3u8',
          container: 'm3u8',
          protocol: 'hls',
          height: 1080,
          bitrate: 5000000,
          hasVideo: true,
          hasAudio: true,
        ),
        MediaFormat(
          id: 'dup',
          url: 'https://example.invalid/720.m3u8',
          container: 'm3u8',
          protocol: 'hls',
          height: 720,
          bitrate: 2000000,
          hasVideo: true,
          hasAudio: true,
        ),
      ],
    );

    final path = await pipeline.download(
      info: info,
      type: DownloadType.video,
      options: const DownloadOptions(videoFormat: VideoFormat.mp4),
      outputDir: outDir.path,
    );

    expect(path, '${outDir.path}/duplicate id pipeline test.mp4');
    // Both share id 'dup' - if the pipeline's retry tracking were keyed on
    // id rather than identity, the 720p candidate would have been marked
    // "already tried" as soon as the 1080p one (same id) failed, and this
    // download would have thrown instead of reaching a second URL at all.
    expect(hlsDownloader.urlsRequested, [
      'https://example.invalid/1080.m3u8',
      'https://example.invalid/720.m3u8',
    ]);
  });
}
