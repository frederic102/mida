import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/facebook/facebook_extractor.dart';
import 'package:mida/core/extractors/facebook/facebook_page_state.dart';
import 'package:mida/core/extractors/facebook/facebook_url_matcher.dart';
import 'package:mida/core/extractors/facebook/facebook_video_json_parser.dart';

import 'facebook_fake_server.dart';

void main() {
  group('FacebookUrlMatcher', () {
    test('accepts every supported shape and extracts the id where the URL has one', () {
      const cases = <String, String?>{
        'https://www.facebook.com/NatGeoAnimals/videos/371360365972647/': '371360365972647',
        'https://www.facebook.com/NatGeoAnimals/videos/reindeer-national-geographic/371360365972647/':
            '371360365972647',
        'https://facebook.com/watch/?v=371360365972647': '371360365972647',
        'https://www.facebook.com/watch?v=371360365972647': '371360365972647',
        'https://m.facebook.com/reel/1234567890': '1234567890',
        'https://web.facebook.com/reel/1234567890/': '1234567890',
        'https://www.facebook.com/share/v/1AbCdEfGh/': null,
        'https://fb.watch/aBc12_x/': null,
      };
      for (final entry in cases.entries) {
        final ref = FacebookUrlMatcher.match(Uri.parse(entry.key));
        expect(ref, isNotNull, reason: entry.key);
        expect(ref!.videoId, entry.value, reason: entry.key);
      }
    });

    test('fetches facebook.com pages on www, keeps path and query', () {
      final ref = FacebookUrlMatcher.match(Uri.parse('https://m.facebook.com/watch/?v=42&ref=share'))!;
      expect(ref.fetchUrl.toString(), 'https://www.facebook.com/watch/?v=42&ref=share');
    });

    test('rejects non-video pages, other hosts and schemes', () {
      final extractor = FacebookExtractor();
      for (final url in [
        'https://www.facebook.com/NatGeoAnimals',
        'https://www.facebook.com/NatGeoAnimals/videos/',
        'https://www.facebook.com/NatGeoAnimals/videos/not-a-number/',
        'https://www.facebook.com/watch/?v=abc',
        'https://www.facebook.com/watch/',
        'https://www.facebook.com/reel/abc',
        'https://www.facebook.com/share/p/1AbCdEf/',
        'https://www.facebook.com/NatGeoAnimals/videos/371360365972647/extra',
        'https://evil.facebook.com.example/reel/1',
        'https://business.facebook.com/reel/1',
        'https://fb.watch/',
        'https://fb.watch/a/b',
        'ftp://www.facebook.com/reel/1',
      ]) {
        expect(extractor.canHandle(Uri.parse(url)), isFalse, reason: url);
      }
    });
  });

  group('FacebookVideoJsonParser', () {
    const parser = FacebookVideoJsonParser();

    test('fixture: the requested id wins over a related video, metadata from the JSON', () {
      final data = parser.parse(fixture('facebook_video_hd_sd.html'), videoId: '1234567890123');
      expect(data.video!.hdUrl, contains('target_hd.mp4'));
      expect(data.video!.sdUrl, contains('target_sd.mp4'));
      expect(data.meta.author, 'Nat Geo Animals');

      final related = parser.parse(fixture('facebook_video_hd_sd.html'), videoId: '9999999999999');
      expect(related.video!.hdUrl, contains('related_hd.mp4'));
      expect(related.video!.sdUrl, isNull);
    });

    test('no id from the URL: first node in document order', () {
      final data = parser.parse(fixture('facebook_video_hd_sd.html'));
      expect(data.video!.hdUrl, contains('target_hd.mp4'));
    });

    test('unattributed raw node is accepted only when the page mentions the id', () {
      const html = '<script>x({"browser_native_sd_url":"https:\\/\\/v.fbcdn.net\\/a.mp4"})</script>';
      expect(parser.parse(html, videoId: '77').video, isNull);
      expect(parser.parse('$html<a href="/reel/77">', videoId: '77').video!.sdUrl, 'https://v.fbcdn.net/a.mp4');
    });

    test('Shape B progressive_urls with quality metadata, length_in_second duration', () {
      const html = '<script type="application/json">{"v":{"id":"5","length_in_second":12.5,'
          '"title":"Plain title","r":{"progressive_urls":['
          '{"progressive_url":"https://v.fbcdn.net/sd.mp4","metadata":{"quality":"SD"}},'
          '{"progressive_url":"https://v.fbcdn.net/hd.mp4","metadata":{"quality":"HD"}}]}}}</script>';
      final data = parser.parse(html, videoId: '5');
      expect(data.video!.hdUrl, 'https://v.fbcdn.net/hd.mp4');
      expect(data.video!.sdUrl, 'https://v.fbcdn.net/sd.mp4');
      expect(data.meta.duration, const Duration(milliseconds: 12500));
      expect(data.meta.title, 'Plain title');
    });

    test('non-https and malformed values are ignored, broken JSON blocks skipped', () {
      const html = '<script type="application/json">{not json</script>'
          '<script type="application/json">{"id":"6","browser_native_hd_url":"http://v.fbcdn.net/a.mp4",'
          '"browser_native_sd_url":"javascript:alert(1)","dash_manifest":"not a manifest"}</script>';
      expect(parser.parse(html, videoId: '6').video, isNull);
    });
  });

  group('FacebookPageStateDetector', () {
    test('login wall fixture is a login wall; a normal page is not', () {
      expect(FacebookPageStateDetector.classify(fixture('facebook_login_wall.html')), FacebookPageState.loginWall);
      expect(FacebookPageStateDetector.classify('<html><title>Cute cats</title></html>'), FacebookPageState.unknown);
    });

    test('Korean sign-in title is a login wall', () {
      const html = '<html><title>Facebook에 로그인</title></html>';
      expect(FacebookPageStateDetector.isLoginWall(html), isTrue);
    });

    test('not-found wording, with HTML-escaped or curly apostrophes', () {
      // The fixture also carries a login form: that makes it a login wall.
      expect(FacebookPageStateDetector.classify(fixture('facebook_not_found.html')), FacebookPageState.loginWall);
      expect(
        FacebookPageStateDetector.classify('<h2>This content isn&#039;t available right now</h2>'),
        FacebookPageState.notFound,
      );
      expect(
        FacebookPageStateDetector.classify('<p>This video isn’t available anymore</p>'),
        FacebookPageState.notFound,
      );
    });

    test('login redirect only counts on a Facebook host', () {
      expect(FacebookPageStateDetector.isLoginRedirect(Uri.parse('https://www.facebook.com/login.php?next=x')), isTrue);
      expect(FacebookPageStateDetector.isLoginRedirect(Uri.parse('https://www.facebook.com/checkpoint/1')), isTrue);
      expect(FacebookPageStateDetector.isLoginRedirect(Uri.parse('https://example.com/login.php')), isFalse);
      expect(FacebookPageStateDetector.isLoginRedirect(Uri.parse('https://www.facebook.com/reel/1')), isFalse);
    });
  });
}
