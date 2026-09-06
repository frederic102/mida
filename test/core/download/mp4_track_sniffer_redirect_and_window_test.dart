import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/download/mp4_track_sniffer.dart';
import 'package:mida/core/extractors/media_models.dart';

import 'mp4_fixture_bytes.dart';

/// Split out of `mp4_track_sniffer_test.dart` purely for the 400-line file
/// cap - phase 6 round 2's S-R1 (redirect-hop origin handling) and S-R3
/// (window byte-cap precision) each need their own fixture server shape,
/// so they get their own file rather than crowding the main one further.

/// Answers 200 (ignoring any Range header, like a CDN with no Range
/// support) with [content] split into exactly two writes: everything up
/// to [splitAt], flushed, then the remainder. Used by the S-R3 test to
/// make the "chunk that crosses the window boundary" reproducible: the
/// first write alone stays safely under the 64 KiB window, so only the
/// second write's bytes can ever push the running total past it.
class _TwoChunkServer {
  final HttpServer server;
  final Uint8List content;
  final int splitAt;

  _TwoChunkServer(this.server, this.content, this.splitAt);

  static Future<_TwoChunkServer> start(Uint8List content, {required int splitAt}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final instance = _TwoChunkServer(server, content, splitAt);
    server.listen(instance._handle);
    return instance;
  }

  String get url => 'http://127.0.0.1:${server.port}/video.mp4';

  Future<void> _handle(HttpRequest request) async {
    request.response.statusCode = 200;
    request.response.add(content.sublist(0, splitAt));
    await request.response.flush();
    request.response.add(content.sublist(splitAt));
    await request.response.close();
  }

  Future<void> close() => server.close(force: true);
}

void main() {
  test(
    'guard can fail: a chunk that would cross the 64 KiB window only contributes up to what is still '
    'missing, not the whole chunk (S-R3)',
    () async {
      final fixture = buildWindowBoundaryStraddlingFmp4();
      // The split sits comfortably under the window so the first write
      // alone can never trigger it; the second write (everything past
      // 65500) is what would carry the buffer past 65536 if let through
      // whole.
      final server = await _TwoChunkServer.start(fixture, splitAt: 65500);
      addTearDown(server.close);

      const sniffer = Mp4TrackSniffer(allowPrivateHosts: true);
      final info = await sniffer.sniff(Uri.parse(server.url), const {});

      // moov's own declared size covers the trailing audio trak, well
      // past 64 KiB - a correctly windowed read never actually has those
      // bytes, so IsoBmffReader's own S-R5 fix treats moov as incomplete
      // and this comes back null. Guard-can-fail (manually verified, see
      // report): reverting `_readWindow` to plain `builder.add(chunk)`
      // (no `min(chunk.length, window - total)` clamp) lets the second
      // write's ~756 bytes through in full, which reaches all the way to
      // the trailing audio trak - the result stops being null and instead
      // reports `hasAudio: true`.
      expect(info, isNull);
    },
  );

  group('redirect-hop origin handling (S-R1)', () {
    // Two IP-literal "public-looking" hosts (documentation ranges, never
    // actually dialed - `connectionFactory` below always redirects the
    // real socket to one of two local fixture servers) so `HostPolicy`'s
    // own per-hop private-host check never gets in the way of proving the
    // *origin-change* behavior specifically: both hosts are equally
    // "allowed", the only difference between them is that they are
    // different origins.
    const hostA = '93.184.216.34';
    const hostB = '198.51.100.7';

    test(
      'guard can fail: a redirect to a different origin forwards neither the flat headers\' Cookie/Authorization '
      'nor a domain-scoped cookie captured for the original host',
      () async {
        final serverA = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => serverA.close(force: true));
        serverA.listen((request) async {
          request.response.statusCode = 302;
          request.response.headers.set('location', 'https://$hostB/target.mp4');
          await request.response.close();
        });

        final fixture = buildFmp4Init();
        var hostBHeaders = <String, String?>{};
        final serverB = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => serverB.close(force: true));
        serverB.listen((request) async {
          hostBHeaders = {
            'cookie': request.headers.value('cookie'),
            'authorization': request.headers.value('authorization'),
            'x-test-header': request.headers.value('x-test-header'),
          };
          request.response.statusCode = 200;
          request.response.add(fixture);
          await request.response.close();
        });

        HttpClient pinnedClient() {
          final client = HttpClient();
          client.connectionFactory = (uri, proxyHost, proxyPort) => Socket.startConnect(
                InternetAddress.loopbackIPv4,
                uri.host == hostA ? serverA.port : serverB.port,
              );
          return client;
        }

        final sniffer = Mp4TrackSniffer(httpClientFactory: pinnedClient);
        final info = await sniffer.sniff(
          Uri.parse('https://$hostA/start.mp4'),
          const {'Cookie': 'sess=onA', 'Authorization': 'Bearer secretA', 'X-Test-Header': 'still-fine'},
          cookiesByDomain: const {
            hostA: [CookieEntry(domain: hostA, path: '/', secure: false, name: 'sid', value: 'fromA')],
          },
        );

        expect(info?.hasVideo, isTrue, reason: 'the redirect itself must still be followed to hostB successfully');
        expect(hostBHeaders['cookie'], isNull,
            reason: 'neither the flat Cookie header nor the domain-scoped cookie captured for hostA may reach hostB');
        expect(hostBHeaders['authorization'], isNull,
            reason: 'Authorization must not ride along onto a different origin either');
        expect(hostBHeaders['x-test-header'], 'still-fine',
            reason: 'a non-credential header is still forwarded across the redirect');
      },
    );

    test('a same-origin redirect (same scheme/host/port) still forwards Cookie/Authorization normally', () async {
      // A redirect to a *different* loopback host (even same-origin in the
      // sense this test cares about, i.e. hostA -> hostA) is refused by
      // `HostPolicy.guardedRequest` itself past hop 0 (`allowPrivateHosts`
      // only exempts the very first hop - see
      // `stream_downloader_redirect_test.dart`'s own doc on this), so a
      // plain loopback URL can never actually exercise a same-origin
      // redirect end to end. hostA here is the same IP-literal
      // "public-looking" pinning trick as the guard-can-fail test above,
      // just pinned to the same server both times.
      const hostA = '93.184.216.34';
      final requests = <Map<String, String?>>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var hit = 0;
      server.listen((request) async {
        requests.add({'cookie': request.headers.value('cookie'), 'path': request.uri.path});
        hit++;
        if (hit == 1) {
          request.response.statusCode = 302;
          request.response.headers.set('location', 'https://$hostA/final.mp4');
          await request.response.close();
          return;
        }
        request.response.statusCode = 200;
        request.response.add(buildFmp4Init());
        await request.response.close();
      });

      HttpClient pinnedClient() {
        final client = HttpClient();
        client.connectionFactory =
            (uri, proxyHost, proxyPort) => Socket.startConnect(InternetAddress.loopbackIPv4, server.port);
        return client;
      }

      final sniffer = Mp4TrackSniffer(httpClientFactory: pinnedClient);
      final info = await sniffer.sniff(
        Uri.parse('https://$hostA/start.mp4'),
        const {'Cookie': 'sess=same-origin'},
      );

      expect(info?.hasVideo, isTrue);
      expect(requests, hasLength(2));
      expect(requests[1]['cookie'], 'sess=same-origin');
    });
  });
}
