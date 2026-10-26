import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/generic/embeds/embed_delegation.dart';
import 'package:mida/core/extractors/generic/embeds/embed_resolver.dart';
import 'package:mida/core/extractors/generic/embeds/embed_resolver_chain.dart';
import 'package:mida/core/extractors/generic/generic_extractor.dart';
import 'package:mida/core/extractors/media_models.dart';

import '../generic_test_support.dart';
import 'fake_embed_http.dart';

const _bcTag = '<video-js data-account="1234567890" data-player="AbCdEf-123" '
    'data-embed="default" data-video-id="6301234567001"></video-js>';
const _bcConfig = 'GET https://players.brightcove.net/1234567890/AbCdEf-123_default/config.json';
const _bcPlayback = 'GET https://edge.api.brightcove.com/playback/v1/accounts/1234567890/videos/6301234567001';

class _ThrowingMatcher implements EmbedResolver {
  @override
  String get platform => 'Broken';
  @override
  bool matches(String html) => throw const FormatException('matcher bug');
  @override
  Future<MediaInfo?> resolve(EmbedRequest request) async => null;
}

/// Discovery order of `GenericExtractor` (page sniff, platform chain,
/// iframe follow). The page comes from a loopback fixture server; every
/// other host either goes to [FakeEmbedHttp] (platform APIs) or, for the
/// iframe follower, to a client that records the attempt and refuses it.
void main() {
  late FakePageServer server;
  late List<Uri> attempts;

  setUp(() async {
    server = await FakePageServer.start();
    attempts = [];
  });
  tearDown(() => server.close());

  /// Loopback only: any other host is recorded and refused (never dialled).
  HttpClient recordingClient() => HttpClient()
    ..findProxy = ((_) => 'DIRECT')
    ..connectionFactory = (uri, proxyHost, proxyPort) {
      attempts.add(uri);
      if (uri.host == '127.0.0.1') return Socket.startConnect(InternetAddress.loopbackIPv4, uri.port);
      return Future.error(SocketException('offline test refuses ${uri.host}'));
    };

  GenericExtractor extractorWith(FakeEmbedHttp http, {List<EmbedResolver>? resolvers}) => GenericExtractor(
        allowPrivateHosts: true,
        httpClientFactory: recordingClient,
        embedResolverChain: EmbedResolverChain(
          http: http,
          resolvers: resolvers ?? EmbedResolverChain.defaultResolvers,
        ),
      );

  test('a dead bare .mp4 candidate no longer hides a valid Brightcove embed', () async {
    final adServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => adServer.close(force: true));
    adServer.listen((request) async {
      request.response.headers.set('Content-Type', 'text/html');
      await request.response.close();
    });
    final deadUrl = 'http://127.0.0.1:${adServer.port}/dead.mp4';
    server.body = '<html><body><script>var beacon = "$deadUrl";</script>$_bcTag</body></html>';
    final http = FakeEmbedHttp({
      _bcConfig: ok(fixture('brightcove_config.json')),
      _bcPlayback: ok(fixture('brightcove_playback.json')),
    });

    final info = await extractorWith(http).extract(server.urlFor('/watch'));

    expect(info.title, 'Product tour 2026');
    expect(info.formats, isNotEmpty);
    expect(info.formats.any((f) => f.url == deadUrl), isFalse);
    expect(http.requests.map((r) => '${r.method} ${r.url}'), [_bcConfig, _bcPlayback]);
  });

  test('a claimed player iframe delegates before the generic follower fetches it', () async {
    server.body = '<html><body><iframe src="https://player.vimeo.com/video/76979871"></iframe></body></html>';
    await expectLater(
      extractorWith(FakeEmbedHttp({})).extract(server.urlFor('/watch')),
      throwsA(isA<EmbedDelegationException>()
          .having((e) => e.target.toString(), 'target', 'https://player.vimeo.com/video/76979871')),
    );
    expect(attempts.map((u) => u.host).toSet(), {'127.0.0.1'},
        reason: 'player.vimeo.com must never be fetched by the iframe follower');
  });

  test('an unclaimed iframe is still followed (no regression for ordinary embeds)', () async {
    server.body = '<html><body><iframe src="https://player.example.net/e/1"></iframe></body></html>';
    await expectLater(
      extractorWith(FakeEmbedHttp({})).extract(server.urlFor('/watch')),
      throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'NO_MEDIA_FOUND')),
    );
    expect(attempts.map((u) => u.host), contains('player.example.net'));
  });

  test('malformed Vimeo hash (?h=%FF): ordinary delegation, no raw exception', () async {
    server.body = '<html><body><iframe src="https://player.vimeo.com/video/123?h=%FF"></iframe></body></html>';
    await expectLater(
      extractorWith(FakeEmbedHttp({})).extract(server.urlFor('/watch')),
      throwsA(isA<EmbedDelegationException>()
          .having((e) => e.target.toString(), 'target', 'https://player.vimeo.com/video/123')),
    );
  });

  test('a resolver whose matches() throws is isolated: ordinary NO_MEDIA_FOUND', () async {
    server.body = '<html><body><p>nothing</p></body></html>';
    await expectLater(
      extractorWith(FakeEmbedHttp({}), resolvers: [_ThrowingMatcher()]).extract(server.urlFor('/watch')),
      throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'NO_MEDIA_FOUND')),
    );
  });

  test('a context-backed HLS candidate that expands to nothing does not shadow a delegated embed', () async {
    // The fake page server answers every path with this HTML, so the
    // manifest "fetch" returns no #EXTM3U playlist: zero formats.
    server.body = '<html><body><video src="/master.m3u8"></video>'
        '<iframe src="https://www.youtube.com/embed/dQw4w9WgXcQ"></iframe></body></html>';
    await expectLater(
      extractorWith(FakeEmbedHttp({})).extract(server.urlFor('/watch')),
      throwsA(isA<EmbedDelegationException>()
          .having((e) => e.target.toString(), 'target', 'https://www.youtube.com/watch?v=dQw4w9WgXcQ')),
    );
    expect(attempts.map((u) => u.host).toSet(), {'127.0.0.1'});
  });
}
