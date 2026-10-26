import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_extractor.dart';
import 'package:mida/core/extractors/media_models.dart';

import 'facebook_fake_server.dart';

class _Recording implements MediaExtractor {
  final String label;
  final List<String> calls;
  final Future<MediaInfo> Function(Uri url) onExtract;

  _Recording(this.label, this.calls, this.onExtract);

  @override
  bool canHandle(Uri url) => true;

  @override
  Future<MediaInfo> extract(Uri url) {
    calls.add(label);
    return onExtract(url);
  }
}

/// Gadfly round 3, Counter 1: Facebook's "content isn't available" page with
/// a login form (a group/friends-only video seen anonymously) must stay
/// non-terminal, so a signed-in browser capture still gets its turn.
/// Hermetic: the Facebook page comes from the loopback fake server, the
/// generic and browser tiers are recording fakes.
void main() {
  late FakeFacebookServer server;
  setUp(() async => server = await FakeFacebookServer.start());
  tearDown(() => server.close());

  test('not-available page with a login form reaches the browser tier when a login session exists', () async {
    server.route('www.facebook.com/reel/6666666666666', FakeRoute(body: fixture('facebook_not_found.html')));
    final calls = <String>[];
    final registry = ExtractorRegistry(
      [
        server.extractor(),
        _Recording('generic', calls, (_) async => throw const MediaExtractionException('NO_MEDIA_FOUND', 'none')),
      ],
      fallbacks: [
        _Recording('browser', calls, (url) async => MediaInfo(
              id: 'b',
              title: 'from browser',
              sourceUrl: url,
              formats: const [
                MediaFormat(id: 'b', url: 'https://cdn.example/b.mp4', container: 'mp4', hasVideo: true, hasAudio: true),
              ],
            )),
      ],
      loginSessionAvailable: true,
    );

    final info = await registry.resolveInfo(Uri.parse('https://www.facebook.com/reel/6666666666666'));

    expect(info.title, 'from browser');
    expect(calls, contains('browser'));
  });
}
