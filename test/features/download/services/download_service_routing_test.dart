import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_extractor.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/services/settings_service.dart';
import 'package:mida/features/download/services/download_service_io.dart';

class _FakeExtractor implements MediaExtractor {
  final bool Function(Uri) canHandleFn;
  final Future<MediaInfo> Function(Uri url) extractFn;
  _FakeExtractor(this.canHandleFn, this.extractFn);

  @override
  bool canHandle(Uri url) => canHandleFn(url);

  @override
  Future<MediaInfo> extract(Uri url) => extractFn(url);
}

void main() {
  // A non-empty formats list: `MediaInfo` with `formats: []` is not
  // success (`ExtractorRegistry.resolveInfo` treats that as
  // NO_MEDIA_FOUND and continues the fall-through chain), so a fake
  // extractor standing in for a real successful one must include this.
  const fakeFormat = MediaFormat(
    id: 'f',
    url: 'https://example.invalid/video.mp4',
    container: 'mp4',
    hasVideo: true,
    hasAudio: true,
  );
  MediaInfo infoFor(Uri url, String title) =>
      MediaInfo(id: 'id', title: title, sourceUrl: url, formats: const [fakeFormat]);

  ExtractorRegistry fakeRegistryFor(Map<String, String> hostToTitle) {
    return ExtractorRegistry([
      for (final entry in hostToTitle.entries)
        _FakeExtractor(
          (u) => u.host == entry.key,
          (url) async => infoFor(url, entry.value),
        ),
    ]);
  }

  group('DownloadService routing: every platform resolves through ExtractorRegistry', () {
    test('fetchVideoInfo resolves youtube/twitter/generic-looking URLs entirely through the registry', () async {
      final registry = fakeRegistryFor({
        'youtube.example': 'youtube-looking title',
        'x.example': 'twitter-looking title',
        'generic.example': 'generic-looking title',
      });
      final service = DownloadService(SettingsService(), registry: registry);

      final youtubeInfo = await service.fetchVideoInfo('https://youtube.example/watch');
      final twitterInfo = await service.fetchVideoInfo('https://x.example/status');
      final genericInfo = await service.fetchVideoInfo('https://generic.example/page');

      expect(youtubeInfo?['title'], 'youtube-looking title');
      expect(twitterInfo?['title'], 'twitter-looking title');
      expect(genericInfo?['title'], 'generic-looking title');
    });

    test('fetchVideoInfo returns null (not a throw) for a URL no fake extractor recognizes', () async {
      final service = DownloadService(SettingsService(), registry: fakeRegistryFor(const {}));

      expect(await service.fetchVideoInfo('https://unrecognized.example/video'), isNull);
    });

    test('download routes through the registry and pipeline, and reports NoDownloadableFormatsException '
        'as the task error', () async {
      // Audio-only format on a VIDEO request: the registry itself sees a
      // non-empty (successful) format list, but `FormatSelector.rank` for
      // `DownloadType.video` finds nothing usable (no video-only, no
      // muxed, and the silent-source fallback only applies when *no*
      // format claims audio) - the pipeline, not the registry, is what
      // must fail here.
      const audioOnlyFormat = MediaFormat(
        id: 'audio-only',
        url: 'https://example.invalid/audio.mp4',
        container: 'mp4',
        hasVideo: false,
        hasAudio: true,
      );
      final registry = ExtractorRegistry([
        _FakeExtractor(
          (u) => u.host == 'generic.example',
          (url) async => MediaInfo(
            id: 'id',
            title: 'generic-looking title',
            sourceUrl: url,
            formats: const [audioOnlyFormat],
          ),
        ),
      ]);
      final service = DownloadService(SettingsService(), registry: registry);

      await service.download('https://generic.example/page', DownloadType.video);

      expect(service.currentTask, isNotNull);
      expect(service.currentTask!.status, DownloadStatus.error);
      expect(service.currentTask!.title, 'generic-looking title');
      expect(service.currentTask!.error, contains('No downloadable formats'));
    });
  });
}
