import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/download/format_request_context.dart';
import 'package:mida/core/download/hls_ffmpeg_downloader.dart';
import 'package:mida/core/download/media_merger.dart';
import 'package:mida/core/download/stream_downloader.dart';
import 'package:mida/core/extractors/format_selector.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/features/download/services/adaptive_pair_downloader.dart';
import 'package:mida/features/download/services/download_service_io.dart';

import 'media_download_pipeline_test_fakes.dart';

/// Phase 6 (`docs/plan-phase6-av-pairing.md`, Lane P, P4b): each half of an
/// adaptive pair is routed independently - `HlsFfmpegDownloader` only for
/// the half that actually needs it (`AdaptivePairDownloader.needsFfmpeg`),
/// `StreamDownloader` otherwise. Pre-phase-6, this class did not exist:
/// every half went through `StreamDownloader` unconditionally, which
/// downloads a manifest URL's *text* as if it were the media file.
void main() {
  late Directory outDir;

  setUp(() async {
    outDir = await Directory.systemTemp.createTemp('mida_adaptive_pair_out_');
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

  AdaptivePairDownloader downloaderWith({
    required HlsFfmpegDownloader hlsDownloader,
    required StreamDownloader Function() streamFactory,
  }) {
    return AdaptivePairDownloader(
      hlsDownloader: hlsDownloader,
      downloaderFactory: streamFactory,
      merger: RecordingMerger(),
    );
  }

  group('AdaptivePairDownloader.processTimeoutFor (round 2 P-R5)', () {
    test('a known duration is duration*4 + 5 minutes', () {
      expect(AdaptivePairDownloader.processTimeoutFor(const Duration(minutes: 10)), const Duration(minutes: 45));
      expect(AdaptivePairDownloader.processTimeoutFor(const Duration(seconds: 30)), const Duration(minutes: 7));
    });

    test('an unknown (null) duration falls back to a flat 60 minutes, not no timeout at all', () {
      expect(AdaptivePairDownloader.processTimeoutFor(null), const Duration(minutes: 60));
    });
  });

  test('a video-only HLS half and an audio-only HLS half (the pinterest/ted split-audio shape) both route through '
      'HlsFfmpegDownloader, not StreamDownloader (guard: needsFfmpeg is what decides this - a plain https pair '
      'below never touches HlsFfmpegDownloader at all)', () async {
    final hlsDownloader = RecordingHlsDownloader();
    final downloader = downloaderWith(
      hlsDownloader: hlsDownloader,
      streamFactory: () => throw StateError('StreamDownloader must never be used for an all-HLS pair'),
    );

    final selected = SelectedFormats(
      video: const MediaFormat(
        id: 'v1',
        url: 'https://example.invalid/video_720p.m3u8',
        container: 'm3u8',
        protocol: 'hls',
        videoCodec: 'avc1.4d401f',
        height: 720,
        hasVideo: true,
        hasAudio: false,
      ),
      audio: const MediaFormat(
        id: 'a1',
        url: 'https://example.invalid/audio_en.m3u8',
        container: 'm3u8',
        protocol: 'hls',
        audioCodec: 'mp4a.40.2',
        hasVideo: false,
        hasAudio: true,
      ),
    );

    final downloaded = await downloader.download(
      selected: selected,
      options: const DownloadOptions(videoFormat: VideoFormat.mp4),
      baseName: 'pair test',
      outputDir: outDir.path,
      tempPrefix: '${outDir.path}/.mida_tmp_pair_0',
      requestContext: const FormatRequestContext({}, {}),
      duration: const Duration(seconds: 30),
    );

    expect(downloaded.path, '${outDir.path}/pair test.mp4');
    expect(hlsDownloader.urlsRequested, unorderedEquals([
      'https://example.invalid/video_720p.m3u8',
      'https://example.invalid/audio_en.m3u8',
    ]));

    // Video half: `-c copy` into a `.mp4` temp - the aac_adtstoasc bsf gets
    // added by default (mp4-family output, no sourceAudioCodec passed for
    // this half) but is a harmless no-op since this half carries no audio
    // stream at all.
    final videoArgs = hlsDownloader.builtArgs.firstWhere((a) => a.any((e) => e.contains('video_720p.m3u8')));
    expect(videoArgs, containsAllInOrder(['-c', 'copy']));
    expect(videoArgs, isNot(contains('-vn')), reason: 'a pair half is always a stream copy, never `-vn` audio '
        'extraction - that flag belongs to the audio-only-request path only');

    // Audio half: also `-c copy` (never `-vn` - there is nothing to
    // transcode, only to remux), with its own audioCodec ('mp4a.40.2')
    // passed through as sourceAudioCodec so a codec-aware buildArgs could
    // (correctly, for AAC) still apply the bsf.
    final audioArgs = hlsDownloader.builtArgs.firstWhere((a) => a.any((e) => e.contains('audio_en.m3u8')));
    expect(audioArgs, containsAllInOrder(['-c', 'copy']));
    expect(audioArgs, isNot(contains('-vn')));

    // Round 2 P-R5 (Codex#7): a known 30s duration must produce
    // duration*4 + 5min = 7 minutes for BOTH halves, not left null (guard
    // can fail: dropping `processTimeout:` from either `downloadVerified`
    // call makes this list come back `[null, null]` instead).
    expect(hlsDownloader.processTimeoutsRequested, everyElement(const Duration(minutes: 7)));
  });

  test('an ec-3 audio-only HLS half never gets -bsf:a aac_adtstoasc (trap 2: that bsf assumes ADTS AAC, and '
      'ec-3/Dolby Digital Plus is not AAC at all)', () async {
    final hlsDownloader = RecordingHlsDownloader();
    final downloader = downloaderWith(
      hlsDownloader: hlsDownloader,
      streamFactory: () => throw StateError('unused in this test'),
    );

    final selected = SelectedFormats(
      video: const MediaFormat(
        id: 'v1',
        url: 'https://example.invalid/video.m3u8',
        container: 'm3u8',
        protocol: 'hls',
        videoCodec: 'avc1.4d401f',
        hasVideo: true,
        hasAudio: false,
      ),
      audio: const MediaFormat(
        id: 'a1',
        url: 'https://example.invalid/audio_ec3.m3u8',
        container: 'm3u8',
        protocol: 'hls',
        audioCodec: 'ec-3',
        hasVideo: false,
        hasAudio: true,
      ),
    );

    await downloader.download(
      selected: selected,
      options: const DownloadOptions(videoFormat: VideoFormat.mp4),
      baseName: 'ec3 test',
      outputDir: outDir.path,
      tempPrefix: '${outDir.path}/.mida_tmp_ec3_0',
      requestContext: const FormatRequestContext({}, {}),
      duration: null,
    );

    final audioArgs = hlsDownloader.builtArgs.firstWhere((a) => a.any((e) => e.contains('audio_ec3.m3u8')));
    expect(audioArgs, isNot(contains('-bsf:a')));

    // Round 2 P-R5: an unknown duration (null) gets the flat 60-minute
    // fallback, not an unbounded/no-timeout call.
    expect(hlsDownloader.processTimeoutsRequested, everyElement(const Duration(minutes: 60)));
  });

  test('a plain https pair (Facebook efg-tagged flat mp4 shape) never touches HlsFfmpegDownloader at all', () async {
    final content = Uint8List.fromList(List.generate(200, (i) => i % 256));
    final server = await startByteServer(content);
    addTearDown(() => server.close(force: true));

    final hlsDownloader = RecordingHlsDownloader();
    final downloader = downloaderWith(
      hlsDownloader: hlsDownloader,
      streamFactory: () => StreamDownloader(allowPrivateHosts: true),
    );

    final selected = SelectedFormats(
      video: MediaFormat(
        id: 'v1',
        url: 'http://127.0.0.1:${server.port}/video',
        container: 'mp4',
        videoCodec: 'avc1.4d401f',
        contentLength: content.length,
        hasVideo: true,
        hasAudio: false,
      ),
      audio: MediaFormat(
        id: 'a1',
        url: 'http://127.0.0.1:${server.port}/audio',
        container: 'mp4',
        audioCodec: 'mp4a.40.2',
        contentLength: content.length,
        hasVideo: false,
        hasAudio: true,
      ),
    );

    final downloaded = await downloader.download(
      selected: selected,
      options: const DownloadOptions(videoFormat: VideoFormat.mp4),
      baseName: 'plain pair test',
      outputDir: outDir.path,
      tempPrefix: '${outDir.path}/.mida_tmp_plain_0',
      requestContext: const FormatRequestContext({}, {}),
      duration: null,
    );

    expect(downloaded.path, '${outDir.path}/plain pair test.mp4');
    expect(hlsDownloader.urlsRequested, isEmpty, reason: 'guard can fail: a plain https pair routed through '
        'ffmpeg at all would mean needsFfmpeg is mis-detecting a normal candidate');
  });

  test('when the audio half throws after the video half already succeeded, both temp files are gone and the '
      'exception propagates (guard: a leftover video temp is not left behind just because its sibling half failed)',
      () async {
    final hlsDownloader = RecordingHlsDownloader();
    var callCount = 0;
    final failSecondHalf = CountingHlsDownloader(hlsDownloader, () {
      callCount++;
      return callCount == 2; // video half (call 1) succeeds; audio half (call 2) fails
    });
    final downloader = downloaderWith(
      hlsDownloader: failSecondHalf,
      streamFactory: () => throw StateError('unused in this test'),
    );

    final selected = SelectedFormats(
      video: const MediaFormat(
        id: 'v1',
        url: 'https://example.invalid/video.m3u8',
        container: 'm3u8',
        protocol: 'hls',
        videoCodec: 'avc1.4d401f',
        hasVideo: true,
        hasAudio: false,
      ),
      audio: const MediaFormat(
        id: 'a1',
        url: 'https://example.invalid/audio.m3u8',
        container: 'm3u8',
        protocol: 'hls',
        audioCodec: 'mp4a.40.2',
        hasVideo: false,
        hasAudio: true,
      ),
    );

    final tempPrefix = '${outDir.path}/.mida_tmp_half_fail_0';
    await expectLater(
      downloader.download(
        selected: selected,
        options: const DownloadOptions(videoFormat: VideoFormat.mp4),
        baseName: 'half fail test',
        outputDir: outDir.path,
        tempPrefix: tempPrefix,
        requestContext: const FormatRequestContext({}, {}),
        duration: null,
      ),
      throwsA(isA<MediaMergeException>()),
    );

    expect(File('$tempPrefix.video.mp4').existsSync(), isFalse,
        reason: 'the video half actually wrote this file before the audio half failed - the finally block must '
            'still clean it up');
    expect(File('$tempPrefix.audio.m4a').existsSync(), isFalse);
  });

  test('round 3 P-R3-4 (Codex#13): a loose pair half flagged for transcoding is downloaded into an .mkv temp, '
      'not an mp4-family one that cannot hold its codec', () async {
    final hlsDownloader = RecordingHlsDownloader();
    final downloader = downloaderWith(
      hlsDownloader: hlsDownloader,
      streamFactory: () => throw StateError('unused in this test'),
    );

    // vp9 video + opus audio offered for an mp4 request: the selector's
    // loose tier flags both halves for transcode, and both are HLS
    // manifests, so both go through ffmpeg.
    final selected = SelectedFormats(
      video: const MediaFormat(
        id: 'v1',
        url: 'https://example.invalid/video_vp9.m3u8',
        container: 'm3u8',
        protocol: 'hls',
        videoCodec: 'vp09.00.10.08',
        hasVideo: true,
        hasAudio: false,
      ),
      audio: const MediaFormat(
        id: 'a1',
        url: 'https://example.invalid/audio_opus.m3u8',
        container: 'm3u8',
        protocol: 'hls',
        audioCodec: 'opus',
        hasVideo: false,
        hasAudio: true,
      ),
      videoNeedsTranscode: true,
      audioNeedsTranscode: true,
    );

    final tempPrefix = '${outDir.path}/.mida_tmp_transcode_0';
    await downloader.download(
      selected: selected,
      options: const DownloadOptions(videoFormat: VideoFormat.mp4),
      baseName: 'transcode pair test',
      outputDir: outDir.path,
      tempPrefix: tempPrefix,
      requestContext: const FormatRequestContext({}, {}),
      duration: null,
    );

    final videoArgs = hlsDownloader.builtArgs.firstWhere((a) => a.any((e) => e.contains('video_vp9.m3u8')));
    final audioArgs = hlsDownloader.builtArgs.firstWhere((a) => a.any((e) => e.contains('audio_opus.m3u8')));
    expect(videoArgs.last, '$tempPrefix.video.mkv', reason: 'guard can fail: the round 2 fixed .mp4 temp makes '
        'ffmpeg refuse this vp9 stream copy at the download step, before the merge that was going to transcode '
        'it ever runs');
    expect(audioArgs.last, '$tempPrefix.audio.mkv');
  });

  test('a pair with NO transcode flags keeps the mp4-family temps (the flag, not the protocol, is what moves '
      'them to matroska)', () async {
    final hlsDownloader = RecordingHlsDownloader();
    final downloader = downloaderWith(
      hlsDownloader: hlsDownloader,
      streamFactory: () => throw StateError('unused in this test'),
    );

    final selected = SelectedFormats(
      video: const MediaFormat(
        id: 'v1',
        url: 'https://example.invalid/video_avc.m3u8',
        container: 'm3u8',
        protocol: 'hls',
        videoCodec: 'avc1.4d401f',
        hasVideo: true,
        hasAudio: false,
      ),
      audio: const MediaFormat(
        id: 'a1',
        url: 'https://example.invalid/audio_aac.m3u8',
        container: 'm3u8',
        protocol: 'hls',
        audioCodec: 'mp4a.40.2',
        hasVideo: false,
        hasAudio: true,
      ),
    );

    final tempPrefix = '${outDir.path}/.mida_tmp_no_transcode_0';
    await downloader.download(
      selected: selected,
      options: const DownloadOptions(videoFormat: VideoFormat.mp4),
      baseName: 'plain transcode-free pair',
      outputDir: outDir.path,
      tempPrefix: tempPrefix,
      requestContext: const FormatRequestContext({}, {}),
      duration: null,
    );

    final videoArgs = hlsDownloader.builtArgs.firstWhere((a) => a.any((e) => e.contains('video_avc.m3u8')));
    final audioArgs = hlsDownloader.builtArgs.firstWhere((a) => a.any((e) => e.contains('audio_aac.m3u8')));
    expect(videoArgs.last, '$tempPrefix.video.mp4');
    expect(audioArgs.last, '$tempPrefix.audio.m4a');
  });
}
