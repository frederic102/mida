import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/download/caption_downloader.dart';
import 'package:mida/core/download/stream_downloader.dart';
import 'package:mida/core/extractors/media_models.dart';

import 'fake_hop_http_client.dart';

const _secretCookie = 'session=COOKIESECRET';
const _authHeader = 'Bearer AUTHSECRET';
final _origin = Uri.parse('https://captions.a.example/track?id=1');

Future<List<InternetAddress>> _publicDns(String host) async => [InternetAddress('93.184.216.34')];

CaptionTrack _track(String url) => CaptionTrack(url: url, languageCode: 'en');

/// Bulwark round 3 M1/M2: flat credentials never follow a redirect to
/// another origin, caption bodies are bounded, caption hops are https-only.
void main() {
  late Directory tempDir;
  setUp(() async => tempDir = await Directory.systemTemp.createTemp('mida_hop_creds_'));
  tearDown(() async => tempDir.delete(recursive: true));

  group('captions', () {
    test('a cross-origin redirect hop gets no Cookie or Authorization; the origin hop does', () async {
      final client = FakeHopHttpClient((uri) => uri.host == 'captions.a.example'
          ? const FakeHop(302, location: 'https://cdn.b.example/t.vtt')
          : FakeHop(200, body: 'WEBVTT\n'.codeUnits));
      final out = '${tempDir.path}/a.vtt';
      await CaptionDownloader(httpClient: client, resolveHost: _publicDns)
          .download(_track('$_origin'), out, headers: {'Cookie': _secretCookie, 'Authorization': _authHeader});

      expect(client.sent, hasLength(2));
      expect(client.sent[0].headers['cookie'], _secretCookie);
      expect(client.sent[1].uri.host, 'cdn.b.example');
      expect(client.sent[1].headers.containsKey('cookie'), isFalse);
      expect(client.sent[1].headers.containsKey('authorization'), isFalse);
      expect(await File(out).readAsString(), 'WEBVTT\n');
    });

    test('an oversized caption body is refused after reading at most the cap', () async {
      final client = FakeHopHttpClient((uri) => FakeHop(200, body: List<int>.filled(5 * 1024 * 1024, 0x41)));
      final out = '${tempDir.path}/big.vtt';
      await expectLater(
        CaptionDownloader(httpClient: client, resolveHost: _publicDns).download(_track('$_origin'), out),
        throwsA(isA<CaptionDownloadException>()),
      );
      expect(client.bodyBytesServed, lessThanOrEqualTo(CaptionDownloader.maxCaptionBytes + 65536));
      expect(File(out).existsSync(), isFalse);
    });

    test('an https -> http caption hop is refused before it is requested', () async {
      final client = FakeHopHttpClient((uri) => const FakeHop(302, location: 'http://cdn.b.example/t.vtt?sig=X'));
      await expectLater(
        CaptionDownloader(httpClient: client, resolveHost: _publicDns).download(_track('$_origin'), '${tempDir.path}/x.vtt'),
        throwsA(isA<CaptionDownloadException>().having((e) => e.message, 'message', contains('non-https'))),
      );
      expect(client.sent.map((r) => r.uri.scheme), ['https']);
    });
  });

  group('streams', () {
    test('a cross-origin redirect hop gets no flat Cookie or Authorization', () async {
      final client = FakeHopHttpClient((uri) => uri.host == 'media.a.example'
          ? const FakeHop(302, location: 'https://cdn.b.example/v.mp4')
          : const FakeHop(403));
      final downloader = StreamDownloader(httpClient: client, maxRetries: 1, backoff: (_) => Duration.zero, resolveHost: _publicDns);
      await expectLater(
        downloader.download(
          url: 'https://media.a.example/v.mp4',
          outputPath: '${tempDir.path}/v.mp4',
          contentLength: 100,
          headers: {'Cookie': _secretCookie, 'Authorization': _authHeader},
        ),
        throwsA(isA<StreamDownloadException>()),
      );
      expect(client.sent.first.headers['cookie'], _secretCookie);
      final crossOrigin = client.sent.where((r) => r.uri.host == 'cdn.b.example').toList();
      expect(crossOrigin, isNotEmpty);
      for (final r in crossOrigin) {
        expect(r.headers.containsKey('cookie'), isFalse);
        expect(r.headers.containsKey('authorization'), isFalse);
      }
    });

    test('a cookie CookieScope scopes to the redirect host still travels there', () async {
      final client = FakeHopHttpClient((uri) => uri.host == 'media.a.example'
          ? const FakeHop(302, location: 'https://cdn.b.example/v.mp4')
          : const FakeHop(403));
      final downloader = StreamDownloader(httpClient: client, maxRetries: 1, backoff: (_) => Duration.zero, resolveHost: _publicDns);
      await expectLater(
        downloader.download(
          url: 'https://media.a.example/v.mp4',
          outputPath: '${tempDir.path}/v2.mp4',
          contentLength: 100,
          cookiesByDomain: {
            '.b.example': [const CookieEntry(domain: '.b.example', name: 'cdn', value: 'ok', path: '/', secure: true)],
          },
        ),
        throwsA(isA<StreamDownloadException>()),
      );
      expect(client.sent.firstWhere((r) => r.uri.host == 'cdn.b.example').headers['cookie'], 'cdn=ok');
    });
  });

  group('astra final: the RESOLVED address is checked before every hop', () {
    Future<List<InternetAddress>> fakeDns(String host) async => [
          InternetAddress(switch (host) {
            'media.a.example' => '93.184.216.34',
            'internal.b.example' => '192.168.1.2',
            _ => '10.0.0.5',
          }),
        ];

    test('stream: an initial hostname resolving to 10.0.0.5 is refused before any request', () async {
      final client = FakeHopHttpClient((uri) => const FakeHop(200));
      final downloader =
          StreamDownloader(httpClient: client, maxRetries: 1, backoff: (_) => Duration.zero, resolveHost: fakeDns);
      await expectLater(
        downloader.download(url: 'https://private.a.example/v.mp4', outputPath: '${tempDir.path}/p.mp4', contentLength: 1),
        throwsA(isA<StreamDownloadException>()),
      );
      expect(client.sent, isEmpty);
    });

    test('stream: a redirect hop resolving to 192.168.1.2 is refused before it is requested', () async {
      final client = FakeHopHttpClient((uri) => uri.host == 'media.a.example'
          ? const FakeHop(302, location: 'https://internal.b.example/v.mp4')
          : const FakeHop(200));
      final downloader =
          StreamDownloader(httpClient: client, maxRetries: 1, backoff: (_) => Duration.zero, resolveHost: fakeDns);
      await expectLater(
        downloader.download(url: 'https://media.a.example/v.mp4', outputPath: '${tempDir.path}/r.mp4', contentLength: 1),
        throwsA(isA<StreamDownloadException>()),
      );
      expect(client.sent.map((r) => r.uri.host), ['media.a.example']);
    });

    test('captions: an initial hostname resolving to 10.0.0.5 is refused before any request', () async {
      final client = FakeHopHttpClient((uri) => FakeHop(200, body: 'WEBVTT'.codeUnits));
      await expectLater(
        CaptionDownloader(httpClient: client, resolveHost: fakeDns)
            .download(_track('https://private.a.example/t'), '${tempDir.path}/c.vtt'),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'UNSUPPORTED_URL')),
      );
      expect(client.sent, isEmpty);
    });
  });
}
