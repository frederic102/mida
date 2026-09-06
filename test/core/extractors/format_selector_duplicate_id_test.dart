import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/format_selector.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/features/download/services/download_service_io.dart';

/// Residual follow-up (`docs/plan-phase6-av-pairing.md` "라운드 4 판결",
/// "중복 format id 테스트"). `FormatSelector.rank` groups/filters formats
/// purely by object identity and by `MediaFormat.audioGroupId` - never by
/// `MediaFormat.id` - so two formats that happen to share the same id but
/// point at different URLs (the shape `MediaDownloadPipeline`'s own
/// mismatch-correction re-rank already has to cope with, per round 2
/// P-R4's identity-keyed retry tracking) must both still show up as
/// distinct, independently rankable candidates rather than one silently
/// standing in for the other.
void main() {
  group('FormatSelector.rank - duplicate MediaFormat.id', () {
    test('two video-only formats sharing the same id but different urls/heights both appear, ranked by height', () {
      const selector = FormatSelector();
      const taller = MediaFormat(
        id: 'dup',
        url: 'https://example.invalid/720.mp4',
        container: 'mp4',
        videoCodec: 'avc1',
        height: 720,
        width: 1280,
        bitrate: 3000,
        hasVideo: true,
        hasAudio: false,
      );
      const shorter = MediaFormat(
        id: 'dup',
        url: 'https://example.invalid/480.mp4',
        container: 'mp4',
        videoCodec: 'avc1',
        height: 480,
        width: 854,
        bitrate: 1500,
        hasVideo: true,
        hasAudio: false,
      );
      const audio = MediaFormat(
        id: 'aud',
        url: 'https://example.invalid/audio.mp4',
        container: 'mp4',
        audioCodec: 'mp4a',
        bitrate: 128000,
        hasVideo: false,
        hasAudio: true,
      );

      final info = MediaInfo(
        id: 'v',
        title: 'duplicate id test',
        sourceUrl: Uri.parse('https://example.invalid'),
        formats: [taller, shorter, audio],
      );

      final ranked = selector.rank(info, DownloadType.video, const DownloadOptions(videoFormat: VideoFormat.mp4));
      final pairedUrls = ranked.where((r) => r.isAdaptivePair).map((r) => r.video!.url).toSet();

      expect(
        pairedUrls,
        containsAll(<String>['https://example.invalid/720.mp4', 'https://example.invalid/480.mp4']),
        reason: 'both formats sharing id "dup" must remain independently offered candidates',
      );
      // The taller one still ranks first - the shared id must not have
      // scrambled the height-based ordering either.
      expect(ranked.first.video?.url, 'https://example.invalid/720.mp4');
    });
  });
}
