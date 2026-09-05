import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/instagram/instagram_extractor.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/services/browser_page_fetcher.dart';

/// Stands in for a real headless-browser DOM fetch: `InstagramExtractor`'s
/// only I/O call is `BrowserPageFetcher.fetchDom`, so overriding it (rather
/// than spinning up a real browser or a fake HTTP server) is enough to
/// exercise the extractor's own glue - URL validation plus handing the DOM
/// to `InstagramDomParser` - in isolation from both the network and
/// `InstagramDomParser`'s own parsing logic (covered separately by
/// `instagram_dom_parser_test.dart`).
class _FakeBrowserPageFetcher extends BrowserPageFetcher {
  final Future<String> Function(Uri url) onFetch;

  _FakeBrowserPageFetcher(this.onFetch);

  @override
  Future<String> fetchDom(Uri url) => onFetch(url);
}

void main() {
  group('InstagramExtractor.canHandle', () {
    late InstagramExtractor extractor;
    setUp(() => extractor = InstagramExtractor(fetcher: _FakeBrowserPageFetcher((_) async => '')));

    test('accepts /p/, /reel/, /reels/ and /tv/ post URLs', () {
      expect(extractor.canHandle(Uri.parse('https://www.instagram.com/p/Abc123/')), isTrue);
      expect(extractor.canHandle(Uri.parse('https://www.instagram.com/reel/Abc123/')), isTrue);
      expect(extractor.canHandle(Uri.parse('https://www.instagram.com/reels/Abc123/')), isTrue);
      expect(extractor.canHandle(Uri.parse('https://www.instagram.com/tv/Abc123/')), isTrue);
    });

    test('rejects a bare profile URL and an unrelated host', () {
      expect(extractor.canHandle(Uri.parse('https://www.instagram.com/someuser/')), isFalse);
      expect(extractor.canHandle(Uri.parse('https://evil.example/p/Abc123/')), isFalse);
    });
  });

  group('InstagramExtractor.extract', () {
    test('throws UNSUPPORTED_URL for a non-post URL without calling the fetcher', () async {
      var called = false;
      final extractor = InstagramExtractor(
        fetcher: _FakeBrowserPageFetcher((_) async {
          called = true;
          return '';
        }),
      );
      await expectLater(
        extractor.extract(Uri.parse('https://www.instagram.com/someuser/')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'UNSUPPORTED_URL')),
      );
      expect(called, isFalse);
    });

    test('hands the fetched DOM to the parser and returns its MediaInfo', () async {
      final url = Uri.parse('https://www.instagram.com/reel/Chunk8-jurw/');
      const html = '<script type="application/json">'
          '{"code":"Chunk8-jurw","caption":{"text":"hello"},'
          '"user":{"username":"someone"},'
          '"video_versions":[{"type":101,"url":"https://example.com/v.mp4"}]}'
          '</script>';

      Uri? requestedUrl;
      final extractor = InstagramExtractor(
        fetcher: _FakeBrowserPageFetcher((requested) async {
          requestedUrl = requested;
          return html;
        }),
      );

      final info = await extractor.extract(url);
      expect(requestedUrl, url);
      expect(info.title, '@someone - hello');
      expect(info.author, 'someone');
      expect(info.formats.single.url, 'https://example.com/v.mp4');
    });

    test('propagates BROWSER_MISSING from the fetcher untouched', () async {
      final extractor = InstagramExtractor(
        fetcher: _FakeBrowserPageFetcher((_) async => throw const MediaExtractionException(
              'BROWSER_MISSING',
              'no browser installed',
            )),
      );
      await expectLater(
        extractor.extract(Uri.parse('https://www.instagram.com/reel/Abc123/')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'BROWSER_MISSING')),
      );
    });
  });
}
