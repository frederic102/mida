import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_extractor.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/services/settings_service.dart';
import 'package:mida/core/utils/file_utils.dart';
import 'package:mida/features/download/services/download_service_io.dart';
import 'package:mida/features/download/services/media_download_pipeline.dart';

// A non-empty formats list: `MediaInfo` with `formats: []` is not success
// (`ExtractorRegistry.resolveInfo` now treats that as NO_MEDIA_FOUND), so
// every fake extractor below that stands in for a real successful one
// must include this.
const _fakeFormat = MediaFormat(
  id: 'f',
  url: 'https://example.invalid/video.mp4',
  container: 'mp4',
  hasVideo: true,
  hasAudio: true,
);

class _FakeExtractor implements MediaExtractor {
  final bool Function(Uri) canHandleFn;
  final Future<MediaInfo> Function(Uri url) extractFn;
  _FakeExtractor(this.canHandleFn, this.extractFn);

  @override
  bool canHandle(Uri url) => canHandleFn(url);

  @override
  Future<MediaInfo> extract(Uri url) => extractFn(url);
}

/// Never completes until [gate] is completed, so a test can hold a
/// download "in flight" and observe whether a second `download()` call
/// starts a second real pipeline run.
class _SlowPipeline extends MediaDownloadPipeline {
  int callCount = 0;
  final Completer<void> gate = Completer<void>();

  @override
  Future<String> download({
    required MediaInfo info,
    required DownloadType type,
    required DownloadOptions options,
    required String outputDir,
    void Function(double progress)? onProgress,
    void Function(String message)? onStatus,
  }) async {
    callCount++;
    await gate.future;
    return '$outputDir/fake_output.mp4';
  }
}

void main() {
  // A completed download makes DownloadService open the user's download
  // folder in a real file-manager window. These fakes never touch the
  // filesystem, so that would otherwise pop a real Explorer/Finder window
  // as a side effect of running `flutter test` (observed in practice: see
  // the file_utils_test.dart folder-opener group for the general fix).
  final openedFolders = <String>[];
  setUp(() {
    openedFolders.clear();
    FileUtils.folderOpenerOverride = (path) async => openedFolders.add(path);
  });
  tearDown(() {
    FileUtils.folderOpenerOverride = null;
  });

  test('a second download() call while one is already in flight is a no-op (reentrancy guard)', () async {
    final pipeline = _SlowPipeline();
    final registry = ExtractorRegistry([
      _FakeExtractor(
        (u) => u.host == 'generic.example',
        (url) async => MediaInfo(id: 'id', title: 'reentrancy test title', sourceUrl: url, formats: const [_fakeFormat]),
      ),
    ]);
    final service = DownloadService(
      SettingsService(),
      registry: registry,
      pipeline: pipeline,
    );

    final firstCall = service.download('https://generic.example/page', DownloadType.video);
    // Let the first call run far enough to set `_isDownloading` and reach
    // the (now gated) pipeline.download() call.
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    // A second call while the first is still in flight.
    await service.download('https://generic.example/page', DownloadType.video);

    expect(pipeline.callCount, 1, reason: 'the second call must not start a second real download');
    expect(
      service.currentTask?.statusMessage,
      contains('already in progress'),
      reason: 'the busy second call should leave a clear status message',
    );

    pipeline.gate.complete();
    await firstCall;

    expect(service.currentTask?.status, DownloadStatus.completed);
    expect(openedFolders, hasLength(1),
        reason: 'exactly one real "open folder" call, via the override, no '
            'real OS process spawned');
  });

  test('once a download completes, a later call is free to start a new one', () async {
    final firstPipeline = _SlowPipeline();
    final registry = ExtractorRegistry([
      _FakeExtractor(
        (u) => u.host == 'generic.example',
        (url) async => MediaInfo(id: 'id', title: 'second run title', sourceUrl: url, formats: const [_fakeFormat]),
      ),
    ]);
    final service = DownloadService(
      SettingsService(),
      registry: registry,
      pipeline: firstPipeline,
    );

    firstPipeline.gate.complete();
    await service.download('https://generic.example/page', DownloadType.video);
    expect(service.currentTask?.status, DownloadStatus.completed);

    await service.download('https://generic.example/page', DownloadType.video);
    expect(firstPipeline.callCount, 2, reason: 'a call after the previous one finished must actually run');
    expect(openedFolders, hasLength(2), reason: 'each completed run opens the folder once, via the override');
  });
}
