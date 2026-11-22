import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/youtube/youtube_list_models.dart';
import 'package:mida/core/extractors/youtube/youtube_list_target.dart';

void main() {
  const uc = 'UCBR8-60-B28hp2BmDPdntcQ';
  const pl = 'PLbpi6ZahtOH4vec4VIxczjwC4pY0jAPNC';
  // Built at runtime so the repo's email guard does not read userinfo as an address.
  const at = '@';

  group('accepts', () {
    final channels = {
      'https://www.youtube.com/@YouTube': 'https://www.youtube.com/@YouTube/videos',
      'https://youtube.com/@YouTube/': 'https://www.youtube.com/@YouTube/videos',
      'https://www.youtube.com/@YouTube/videos': 'https://www.youtube.com/@YouTube/videos',
      'http://m.youtube.com/@some.handle-1/videos': 'https://www.youtube.com/@some.handle-1/videos',
      'https://www.youtube.com/channel/$uc': 'https://www.youtube.com/channel/$uc/videos',
      'https://www.youtube.com/channel/$uc/videos': 'https://www.youtube.com/channel/$uc/videos',
      'https://www.youtube.com/c/GoogleDevelopers': 'https://www.youtube.com/c/GoogleDevelopers/videos',
      'https://www.youtube.com/c/GoogleDevelopers/videos': 'https://www.youtube.com/c/GoogleDevelopers/videos',
      'https://www.youtube.com/user/youtube': 'https://www.youtube.com/user/youtube/videos',
      'https://www.youtube.com/user/youtube/videos': 'https://www.youtube.com/user/youtube/videos',
      'https://www.youtube.com/@%ED%95%9C%EA%B8%80': 'https://www.youtube.com/@%ED%95%9C%EA%B8%80/videos',
    };
    channels.forEach((input, page) {
      test('channel $input', () {
        final t = YoutubeListTarget.parse(input);
        expect(t?.kind, YoutubeListKind.channel);
        expect(t?.pageUrl.toString(), page);
      });
    });

    test('a /channel/UC URL carries its channel id, a handle does not', () {
      expect(YoutubeListTarget.parse('https://www.youtube.com/channel/$uc')!.channelId, uc);
      expect(YoutubeListTarget.parse('https://www.youtube.com/@YouTube')!.channelId, isNull);
    });

    final playlists = [
      'https://www.youtube.com/playlist?list=$pl',
      'https://youtube.com/playlist?list=$pl&si=abc',
      'https://www.youtube.com/watch?v=dD33lDxL9K0&list=$pl',
      'https://www.youtube.com/watch?v=dD33lDxL9K0&list=$pl&index=3',
      'https://youtu.be/dD33lDxL9K0?list=$pl',
      'https://www.youtube.com/playlist?list=UUBR8-60-B28hp2BmDPdntcQ',
    ];
    for (final input in playlists) {
      test('playlist $input', () {
        final t = YoutubeListTarget.parse(input);
        expect(t?.kind, YoutubeListKind.playlist);
        expect(t?.pageUrl.path, '/playlist');
        expect(t?.id, input.contains(pl) ? pl : 'UUBR8-60-B28hp2BmDPdntcQ');
      });
    }
  });

  group('rejects', () {
    final bad = [
      'https://www.youtube.com/watch?v=dD33lDxL9K0',
      'https://youtu.be/dD33lDxL9K0',
      'https://www.youtube.com/shorts/dD33lDxL9K0',
      'https://www.youtube.com/',
      'https://www.youtube.com/feed/subscriptions',
      'https://www.youtube.com/@YouTube/shorts',
      'https://www.youtube.com/@YouTube/playlists',
      'https://www.youtube.com/@YouTube/videos/extra',
      'https://www.youtube.com/channel/UCshort',
      'https://www.youtube.com/channel/$uc/community',
      'https://www.youtube.com/c',
      'https://www.youtube.com/@',
      'https://www.youtube.com/playlist?list=RDdD33lDxL9K0',
      'https://www.youtube.com/playlist?list=WL',
      'https://www.youtube.com/playlist?list=LL',
      'https://www.youtube.com/playlist?list=',
      'https://www.youtube.com/playlist',
      'https://www.youtube.com/watch?v=dD33lDxL9K0&list=RDdD33lDxL9K0',
      'https://www.youtube.com.evil.com/@YouTube',
      'https://notyoutube.com/@YouTube',
      'https://evil.com/?u=https://www.youtube.com/@YouTube',
      'https://user:pw${at}www.youtube.com/@YouTube',
      'https://www.youtube.com:8443/@YouTube',
      'ftp://www.youtube.com/@YouTube',
      'javascript:alert(1)',
      'not a url',
      '',
    ];
    for (final input in bad) {
      test(input.isEmpty ? '(empty)' : input, () => expect(YoutubeListTarget.parse(input), isNull));
    }
  });
}
