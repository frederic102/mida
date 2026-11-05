import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/extractor_site_ids.dart';
import 'package:mida/core/extractors/generic/embeds/embed_delegation.dart';
import 'package:mida/core/extractors/media_extractor.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/net/retry_policy.dart';

// The registry names the producing extractor by class name (extractorSiteId),
// so the doubles below carry the real class names. The real classes are not
// imported here, so there is no clash and nothing touches the network.
typedef _Extract = Future<MediaInfo> Function(Uri url);

const _format = MediaFormat(id: 'f', url: 'https://example.invalid/v.mp4', container: 'mp4', hasVideo: true, hasAudio: true);

abstract class _Fake implements MediaExtractor {
  final bool Function(Uri) handles;
  final _Extract? run;
  const _Fake(this.handles, [this.run]);

  @override
  bool canHandle(Uri url) => handles(url);

  @override
  Future<MediaInfo> extract(Uri url) =>
      run?.call(url) ?? Future.value(MediaInfo(id: 'x', title: 'fake', sourceUrl: url, formats: const [_format]));
}

class PinterestExtractor extends _Fake {
  const PinterestExtractor(super.handles, [super.run]);
}

class YoutubeExtractor extends _Fake {
  const YoutubeExtractor(super.handles, [super.run]);
}

class GenericExtractor extends _Fake {
  const GenericExtractor(super.handles, [super.run]);
}

class BrowserCaptureExtractor extends _Fake {
  const BrowserCaptureExtractor(super.handles, [super.run]);
}

class _Unlisted extends _Fake {
  const _Unlisted(super.handles, [super.run]);
}

Future<MediaInfo> _throws(String status) async => throw MediaExtractionException(status, 'x');

final _pin = Uri.parse('https://www.pinterest.com/pin/1/');
final _page = Uri.parse('https://news.example/article/1');
final _youtube = Uri.https('www.youtube.com', '/watch', {'v': 'dQw4w9WgXcQ'});

ExtractorRegistry _registry({
  _Extract? pinterest,
  _Extract? youtube,
  _Extract? generic,
  _Extract? browser,
  bool pinterestHandles = true,
}) =>
    ExtractorRegistry(
      [
        PinterestExtractor((u) => pinterestHandles && u.host.endsWith('pinterest.com'), pinterest),
        YoutubeExtractor((u) => u.host == 'www.youtube.com', youtube),
        GenericExtractor((_) => true, generic),
      ],
      fallbacks: [BrowserCaptureExtractor((_) => true, browser)],
      retryPolicy: RetryPolicy(maxAttempts: 2, sleeper: (_) async {}),
    );

void main() {
  test('a native success reports the native id', () async {
    expect((await _registry().resolveInfo(_pin)).extractor, 'pinterest');
  });

  test('the native failing and the catch-all succeeding reports generic', () async {
    final info = await _registry(pinterest: (_) => _throws('PARSE_ERROR')).resolveInfo(_pin);
    expect(info.extractor, 'generic');
  });

  test('a URL only the catch-all matches reports generic (the native matcher rejected it)', () async {
    final info = await _registry(pinterestHandles: false).resolveInfo(_pin);
    expect(info.extractor, 'generic');
  });

  test('the fallbacks succeeding reports browser-capture', () async {
    final info = await _registry(generic: (_) => _throws('NO_MEDIA_FOUND')).resolveInfo(_page);
    expect(info.extractor, 'browser-capture');
  });

  test('an empty-format native success continues the chain and reports the tier that won', () async {
    final info = await _registry(
      pinterest: (u) async => MediaInfo(id: 'x', title: 'empty', sourceUrl: u),
      generic: (_) => _throws('NO_MEDIA_FOUND'),
    ).resolveInfo(_pin);
    expect(info.extractor, 'browser-capture');
  });

  test('embed delegation reports the delegated native, not generic', () async {
    final info = await _registry(
      generic: (_) async => throw EmbedDelegationException(_youtube, platform: 'YouTube'),
    ).resolveInfo(_page);
    expect(info.extractor, 'youtube');
  });

  test('a delegated native that throws falls back to the browser and reports browser-capture', () async {
    final info = await _registry(
      generic: (_) async => throw EmbedDelegationException(_youtube, platform: 'YouTube'),
      youtube: (_) => _throws('PARSE_ERROR'),
    ).resolveInfo(_page);
    expect(info.extractor, 'browser-capture');
  });

  test('a platform fall-through to the catch-all that delegates reports the delegated native', () async {
    final info = await _registry(
      pinterest: (_) => _throws('PARSE_ERROR'),
      generic: (_) async => throw EmbedDelegationException(_youtube, platform: 'YouTube'),
    ).resolveInfo(_pin);
    expect(info.extractor, 'youtube');
  });

  test('a native LOGIN_REQUIRED falling through to a catch-all success reports generic', () async {
    final info = await _registry(pinterest: (_) => _throws('LOGIN_REQUIRED')).resolveInfo(_pin);
    expect(info.extractor, 'generic');
  });

  test('a native RATE_LIMITED that succeeds on the retry still reports the native', () async {
    var calls = 0;
    final info = await _registry(pinterest: (u) {
      calls++;
      if (calls == 1) return _throws('RATE_LIMITED');
      return Future.value(MediaInfo(id: 'x', title: 'ok', sourceUrl: u, formats: const [_format]));
    }).resolveInfo(_pin);
    expect(calls, 2);
    expect(info.extractor, 'pinterest');
  });

  MediaInfo evil(Uri u) => MediaInfo(id: 'x', title: 'evil', sourceUrl: u, formats: const [_format], extractor: 'evil');

  test('an extractor outside the tables reports null, not a guess', () async {
    const registry = ExtractorRegistry([_Unlisted(_always)]);
    expect((await registry.resolveInfo(_page)).extractor, isNull);
  });

  test('an unlisted extractor that sets extractor itself is cleared to null', () async {
    final registry = ExtractorRegistry([_Unlisted(_always, (u) async => evil(u))]);
    expect((await registry.resolveInfo(_page)).extractor, isNull);
  });

  test('a listed extractor that sets extractor itself is overwritten with its own id', () async {
    final info = await _registry(pinterest: (u) async => evil(u)).resolveInfo(_pin);
    expect(info.extractor, 'pinterest');
  });

  test('every native and tier class maps to a distinct, shell friendly id', () {
    final ids = [...nativeExtractorIds.values, ...tierExtractorIds.values];
    expect(ids.toSet(), hasLength(ids.length));
    for (final id in ids) {
      expect(id, matches(RegExp(r'^[a-z0-9-]+$')));
    }
    expect(extractorSiteId(const GenericExtractor(_always)), 'generic');
  });
}

bool _always(Uri _) => true;
