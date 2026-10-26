import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/extractors/rumble/rumble_page_parser.dart';
import 'package:mida/core/extractors/rumble/rumble_url_matcher.dart';
import 'package:mida/core/extractors/rumble/rumble_video_parser.dart';

void main() {
  group('RumbleUrlMatcher', () {
    test('page slugs and embed ids are validated, everything else is left alone', () {
      expect(RumbleUrlMatcher.match(Uri.parse('https://rumble.com/v5demo1-demo-clip.html?x=1'))!.pageSlug, 'v5demo1-demo-clip');
      expect(RumbleUrlMatcher.match(Uri.parse('https://rumble.com/embed/v5demo/?pub=4'))!.embedId, 'v5demo');
      expect(RumbleUrlMatcher.match(Uri.parse('https://rumble.com/embed/v5demo'))!.embedId, 'v5demo');
      expect(RumbleUrlMatcher.match(Uri.parse('https://rumble.com/v5demo1-demo-clip.html'))!.pageUrl.toString(),
          'https://rumble.com/v5demo1-demo-clip.html');
      for (final input in [
        'https://rumble.com/',
        'https://rumble.com/c/Channel',
        'https://rumble.com/v5demo1-demo-clip',
        'https://rumble.com/a/b.html',
        'https://rumble.com/embed/v5/x',
        'https://rumble.com/embed/v5demo%2F..',
        'https://rumble.com/embed/ab',
        'https://rumble.com/embed/abcdefghijklmnopq',
        'https://rumble.com/.html',
        'https://rumble.com/v5%2Fdemo.html',
        'https://rumble.org/v5demo1-x.html',
        'ftp://rumble.com/v5demo1-x.html',
      ]) {
        expect(RumbleUrlMatcher.match(Uri.parse(input)), isNull, reason: input);
      }
    });
  });

  group('RumblePageParser', () {
    const parser = RumblePageParser();

    test('a JSON-LD node whose url is another slug is never used when the slug node exists', () {
      const html = '''<script type="application/ld+json">{"@graph":[
        {"url":"https://rumble.com/v1other-x.html","embedUrl":"https://rumble.com/embed/v1other/"},
        {"url":"https://rumble.com/v2mine-x.html","embedUrl":"https://rumble.com/embed/v2mine/"}]}</script>''';
      expect(parser.embedId(html, slug: 'v2mine-x'), 'v2mine');
    });

    test('a node naming only other slugs falls back to the raw embedUrl, not to that node', () {
      const html = '''<script type="application/ld+json">{"url":"https://rumble.com/v1other-x.html","embedUrl":"https://rumble.com/embed/v1other/"}</script>
        <script>{"embedUrl":"https:\\/\\/rumble.com\\/embed\\/v9raw\\/"}</script>''';
      expect(parser.embedId(html, slug: 'v2mine-x'), 'v9raw');
    });

    test('several different candidates with no ownership signal throw PARSE_ERROR at every stage', () {
      Matcher parseError() => throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'PARSE_ERROR'));
      const twoUnlinked = '''<script type="application/ld+json">[{"embedUrl":"https://rumble.com/embed/v1aaaa/"},{"embedUrl":"https://rumble.com/embed/v2bbbb/"}]</script>''';
      const twoOwned = '''<script type="application/ld+json">[{"url":"https://rumble.com/v3x-y.html","embedUrl":"https://rumble.com/embed/v1aaaa/"},{"url":"https://rumble.com/v3x-y.html","embedUrl":"https://rumble.com/embed/v2bbbb/"}]</script>''';
      const twoRaw = '''<script>{"embedUrl":"https://rumble.com/embed/v1aaaa/"} {"embedUrl":"https://rumble.com/embed/v2bbbb/"}</script>''';
      const twoOembed = '''<link rel="alternate" type="application/json+oembed" href="https://rumble.com/api/Media/oembed.json?url=https%3A%2F%2Frumble.com%2Fembed%2Fv1aaaa%2F">
        <link rel="alternate" type="application/json+oembed" href="https://rumble.com/api/Media/oembed.json?url=https%3A%2F%2Frumble.com%2Fembed%2Fv2bbbb%2F">''';
      expect(() => parser.embedId(twoUnlinked, slug: 'v3x-y'), parseError());
      expect(() => parser.embedId(twoOwned, slug: 'v3x-y'), parseError());
      expect(() => parser.embedId(twoRaw, slug: 'v3x-y'), parseError());
      expect(() => parser.embedId(twoOembed, slug: 'v3x-y'), parseError());
    });

    test('the same id repeated, and a slug-owned node beside a url-less one, are not ambiguous', () {
      const same = '''<script>{"embedUrl":"https://rumble.com/embed/v1aaaa/"} {"embedUrl":"https:\\/\\/rumble.com\\/embed\\/v1aaaa\\/"}</script>''';
      expect(parser.embedId(same, slug: 'v3x-y'), 'v1aaaa');
      const mixed = '''<script type="application/ld+json">[{"embedUrl":"https://rumble.com/embed/v2bbbb/"},{"url":"https://rumble.com/v3x-y.html","embedUrl":"https://rumble.com/embed/v1aaaa/"}]</script>''';
      expect(parser.embedId(mixed, slug: 'v3x-y'), 'v1aaaa');
    });

    test('ids that fail the anchored pattern are never returned', () {
      const html = '''<script type="application/ld+json">{"embedUrl":"https://rumble.com/embed/v1/../../evil/"}</script>
        <link rel="alternate" type="application/json+oembed" href="https://rumble.com/api/Media/oembed.json?url=https%3A%2F%2Frumble.com%2Fembed%2F..%2F..%2Fevil">''';
      expect(parser.embedId(html, slug: 'v2mine-x'), isNull);
    });

    test('broken JSON-LD is skipped, not fatal', () {
      const html = '''<script type="application/ld+json">{not json</script><script>{"embedUrl":"https:\\/\\/rumble.com\\/embed\\/v3ok\\/"}</script>''';
      expect(parser.embedId(html, slug: 'v3ok-x'), 'v3ok');
    });
  });

  group('RumbleVideoParser', () {
    const parser = RumbleVideoParser();

    test('falls back to the older u map when ua yields nothing; a rendition without a url is skipped', () {
      final video = parser.parse({
        'title': 'Old shape',
        'ua': {
          'mp4': {'720': {'meta': {}}},
        },
        'u': {
          'mp4': {'url': 'https://1a-1791.com/v/old.mp4', 'meta': {'w': 640, 'h': 360, 'bitrate': 700}},
        },
      });
      expect(video.files.single.url, 'https://1a-1791.com/v/old.mp4');
      expect(video.files.single.height, 360);
      expect(video.files.single.bitrate, 700000);
    });

    test('a non-https, non-url, or duplicated rendition URL is dropped or upgraded, never trusted', () {
      final video = parser.parse({
        'ua': {
          'mp4': {
            '360': {'url': 'javascript:alert(1)'},
            '480': {'url': 'file:///etc/passwd'},
            '720': {'url': 'http://1a-1791.com/v/a.mp4'},
            '1080': {'url': 'https://1a-1791.com/v/a.mp4'},
          },
        },
      });
      expect(video.files.map((f) => f.url), ['https://1a-1791.com/v/a.mp4'], reason: 'http upgraded, duplicate dropped');
    });

    test('error answers map to NOT_FOUND / LOGIN_REQUIRED / PARSE_ERROR', () {
      Matcher status(String s) => throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', s));
      expect(() => parser.parse({'error': 'This video was removed'}), status('NOT_FOUND'));
      expect(() => parser.parse({'error': 'Members only, please log in'}), status('LOGIN_REQUIRED'));
      expect(() => parser.parse({'error': 'xyzzy'}), status('PARSE_ERROR'));
      // "unavailable" is not a removal statement: guest and region wording stay non-terminal.
      expect(() => parser.parse({'error': 'This video is unavailable for guests'}), status('LOGIN_REQUIRED'));
      expect(() => parser.parse({'error': 'This video is unavailable in your country'}), status('CHALLENGE_FAILED'));
      expect(() => parser.parse({'error': 'This video was deleted. Please log in'}), status('LOGIN_REQUIRED'));
      expect(() => parser.parse({'error': 'Video not found'}), status('NOT_FOUND'));
      expect(() => parser.parse({'status': 'ok'}), status('PARSE_ERROR'));
    });
  });
}
