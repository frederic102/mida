import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/generic/hls_master_format_mapper.dart';
import 'package:mida/core/extractors/generic/hls_playlist_parser.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/features/download/services/all_format_candidates_failed_exception.dart';
import 'package:mida/features/download/services/download_outcome_verifier.dart';
import 'package:mida/features/download/services/download_service_io.dart';
import 'package:mida/features/download/services/media_download_pipeline.dart';

import 'media_download_pipeline_test_fakes.dart';

/// Round 3 P-R3-1 (`docs/plan-phase6-av-pairing.md`, Gadfly C1/C2,
/// blocker): the end-to-end version of the silent-success regression, run
/// from the real HLS master text through `HlsMasterFormatMapper` and
/// `FormatSelector` into `MediaDownloadPipeline`, because every earlier
/// round fixed one link of that chain and the next link quietly undid it.
///
/// The shape: a master whose variant declares `CODECS="avc1...,mp4a..."`
/// (it claims audio) and takes that audio from an `AUDIO="aud1"` rendition
/// group whose only rendition is excluded - DRM, or unreachable. There is
/// no audio to download anywhere, and the video half alone would remux
/// into a file that plays silently. The required outcome is a loud
/// failure, never a returned path.
const _masterUrl = 'https://cdn.example.invalid/master.m3u8';
const _master = '''
#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud1",NAME="main",DEFAULT=YES,URI="audio/en.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720,CODECS="avc1.4d401f,mp4a.40.2",AUDIO="aud1"
video_720p.m3u8
''';

MediaInfo _infoFrom({required Set<String> excludedAudioUris}) {
  final baseUri = Uri.parse(_masterUrl);
  final formats = HlsMasterFormatMapper.formatsForVariants(
    _masterUrl,
    HlsPlaylistParser.parseMasterVariants(_master, baseUri),
    HlsPlaylistParser.parseAudioRenditions(_master, baseUri),
    excludedAudioUris: excludedAudioUris,
  );
  return MediaInfo(
    id: 'gadfly_silent',
    title: 'gadfly silent guard',
    // Deliberately no duration: this fixture is about the audio guard, and
    // a duration here would send `DownloadOutcomeVerifier`'s truncation
    // check to a real ffprobe process (`FixedProber` only fakes
    // `streamTypes`), which these hermetic tests must never spawn.
    sourceUrl: Uri.parse('https://example.invalid/watch'),
    formats: [for (final f in formats) f.withProtocol('hls')],
  );
}

void main() {
  late Directory outDir;

  setUp(() async {
    outDir = await Directory.systemTemp.createTemp('mida_silent_guard_out_');
  });

  tearDown(() async {
    if (await outDir.exists()) await outDir.delete(recursive: true);
  });

  test('guard-can-fail: a variant claiming audio whose entire rendition group is excluded fails loudly - no '
      'path is ever returned, and the probe reporting video-only is never used to launder it', () async {
    final hlsDownloader = RecordingHlsDownloader();
    final pipeline = MediaDownloadPipeline(
      hlsDownloader: hlsDownloader,
      // Reports video-only, i.e. exactly what a download of the video half
      // alone would produce. Round 2 accepted such a file (via the
      // mismatch correction plus the selector's silent-source tier) and
      // reported success; if that path ever comes back, this test's
      // `expectLater` goes red on a returned path instead of a throw.
      verifier: DownloadOutcomeVerifier(prober: FixedProber({'video'})),
    );

    final info = _infoFrom(excludedAudioUris: {'https://cdn.example.invalid/audio/en.m3u8'});
    expect(info.formats, hasLength(1), reason: 'no audio-only format survives the exclusion');
    expect(info.formats.single.audioWasStripped, isTrue);

    await expectLater(
      pipeline.download(
        info: info,
        type: DownloadType.video,
        options: const DownloadOptions(videoFormat: VideoFormat.mp4),
        outputDir: outDir.path,
      ),
      throwsA(isA<AllFormatCandidatesFailedException>()),
    );

    expect(hlsDownloader.urlsRequested, isEmpty,
        reason: 'nothing is downloaded at all: the refusal happens while ranking, before any bytes are fetched');
    expect(outDir.listSync(), isEmpty, reason: 'no silent output (and no temp) is left behind');
  });

  test('the same master with its rendition available downloads normally - the refusal above is caused by the '
      'exclusion, not by the fixture being unusable', () async {
    final hlsDownloader = RecordingHlsDownloader();
    final pipeline = MediaDownloadPipeline(
      hlsDownloader: hlsDownloader,
      merger: RecordingMerger(),
      verifier: DownloadOutcomeVerifier(prober: FixedProber({'video', 'audio'})),
    );

    final info = _infoFrom(excludedAudioUris: const {});
    expect(info.formats.where((f) => f.isAudioOnly), hasLength(1));

    final path = await pipeline.download(
      info: info,
      type: DownloadType.video,
      options: const DownloadOptions(videoFormat: VideoFormat.mp4),
      outputDir: outDir.path,
    );

    expect(path, '${outDir.path}/gadfly silent guard.mp4');
    expect(hlsDownloader.urlsRequested, [
      'https://cdn.example.invalid/video_720p.m3u8',
      'https://cdn.example.invalid/audio/en.m3u8',
    ]);
  });
}
