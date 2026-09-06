import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/download/mp4_track_sniffer.dart';
import 'package:mida/core/extractors/media_models.dart';

import 'mp4_fixture_bytes.dart';

/// Serves [content] as a Range-aware GET (206 when a Range header is
/// present, 200 with the whole body otherwise), recording the last
/// request's headers - the same shape `_RangeTestServer` in
/// `stream_downloader_test.dart` uses.
class _RangeAwareServer {
  final HttpServer server;
  final Uint8List content;
  int requestCount = 0;
  Map<String, String?> lastHeaders = {};

  _RangeAwareServer(this.server, this.content);

  static Future<_RangeAwareServer> start(Uint8List content) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final instance = _RangeAwareServer(server, content);
    server.listen(instance._handle);
    return instance;
  }

  String get url => 'http://127.0.0.1:${server.port}/video.mp4';

  Future<void> _handle(HttpRequest request) async {
    requestCount++;
    lastHeaders = {
      'range': request.headers.value('range'),
      'cookie': request.headers.value('cookie'),
      'x-test-header': request.headers.value('x-test-header'),
    };
    final range = request.headers.value('range');
    if (range == null) {
      request.response.statusCode = 200;
      request.response.add(content);
      await request.response.close();
      return;
    }
    final match = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(range);
    var start = 0;
    var end = content.length - 1;
    if (match != null) {
      start = int.parse(match.group(1)!);
      end = int.parse(match.group(2)!).clamp(0, content.length - 1);
    }
    final slice = content.sublist(start, end + 1);
    request.response.statusCode = 206;
    request.response.headers.set('Content-Range', 'bytes $start-$end/${content.length}');
    request.response.add(slice);
    await request.response.close();
  }

  Future<void> close() => server.close(force: true);
}

/// Answers 200 with a body far larger than the sniffer's 64 KiB window,
/// deliberately drip-fed with a small delay per chunk so an unbounded
/// reader would take seconds while a correctly capped one returns in
/// milliseconds - the guard-can-fail evidence for the byte cap.
class _UnboundedServer {
  final HttpServer server;
  final Uint8List head;
  bool finishedWriting = false;
  static const int totalBytes = 2 * 1024 * 1024; // 2 MiB, ~32x the window
  static const int chunkSize = 8192;
  static const Duration perChunkDelay = Duration(milliseconds: 15);

  _UnboundedServer(this.server, this.head);

  static Future<_UnboundedServer> start(Uint8List head) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final instance = _UnboundedServer(server, head);
    server.listen(instance._handle);
    return instance;
  }

  String get url => 'http://127.0.0.1:${server.port}/video.mp4';

  Future<void> _handle(HttpRequest request) async {
    // Ignores any Range header entirely - exactly the non-cooperating
    // server shape the cap has to defend against on its own.
    request.response.statusCode = 200;
    try {
      request.response.add(head);
      var sent = head.length;
      while (sent < totalBytes) {
        await Future.delayed(perChunkDelay);
        final n = (totalBytes - sent) < chunkSize ? (totalBytes - sent) : chunkSize;
        request.response.add(Uint8List(n));
        sent += n;
        await request.response.flush();
      }
      await request.response.close();
      finishedWriting = true;
    } catch (_) {
      // The client force-closed the connection before we finished -
      // exactly what the guard is supposed to make happen.
    }
  }

  Future<void> close() => server.close(force: true);
}

void main() {
  group('Mp4TrackSniffer.sniff', () {
    test('reads a Range-served fixture and returns the parsed track info', () async {
      final fixture = buildFmp4Init(videoFourCc: 'avc1', audioFourCc: 'mp4a', width: 1280, height: 720);
      final server = await _RangeAwareServer.start(fixture);
      addTearDown(server.close);

      final sniffer = Mp4TrackSniffer(allowPrivateHosts: true);
      final info = await sniffer.sniff(Uri.parse(server.url), const {});

      expect(info, isNotNull);
      expect(info!.hasVideo, isTrue);
      expect(info.hasAudio, isTrue);
      expect(info.width, 1280);
      expect(info.height, 720);
      expect(info.videoCodec, 'avc1');
      expect(info.audioCodec, 'mp4a');
    });

    test('requests exactly the 64 KiB window via a Range header', () async {
      final fixture = buildFmp4Init();
      final server = await _RangeAwareServer.start(fixture);
      addTearDown(server.close);

      final sniffer = Mp4TrackSniffer(allowPrivateHosts: true);
      await sniffer.sniff(Uri.parse(server.url), const {});

      expect(server.lastHeaders['range'], 'bytes=0-65535');
    });

    test('caller-supplied headers reach the server alongside the Range header', () async {
      final fixture = buildFmp4Init();
      final server = await _RangeAwareServer.start(fixture);
      addTearDown(server.close);

      final sniffer = Mp4TrackSniffer(allowPrivateHosts: true);
      await sniffer.sniff(Uri.parse(server.url), const {'X-Test-Header': 'mida-sniff'});

      expect(server.lastHeaders['x-test-header'], 'mida-sniff');
      expect(server.lastHeaders['range'], 'bytes=0-65535');
    });

    test('a domain-scoped cookie is sent for a matching host', () async {
      final fixture = buildFmp4Init();
      final server = await _RangeAwareServer.start(fixture);
      addTearDown(server.close);

      final sniffer = Mp4TrackSniffer(allowPrivateHosts: true);
      await sniffer.sniff(
        Uri.parse(server.url),
        const {},
        cookiesByDomain: const {
          '127.0.0.1': [CookieEntry(domain: '127.0.0.1', path: '/', secure: false, name: 'sid', value: 'abc123')],
        },
      );

      expect(server.lastHeaders['cookie'], 'sid=abc123');
    });

    test('guard can fail: a cookie scoped to an unrelated domain is never sent', () async {
      final fixture = buildFmp4Init();
      final server = await _RangeAwareServer.start(fixture);
      addTearDown(server.close);

      final sniffer = Mp4TrackSniffer(allowPrivateHosts: true);
      await sniffer.sniff(
        Uri.parse(server.url),
        const {},
        cookiesByDomain: const {
          'unrelated.example.com': [
            CookieEntry(domain: 'unrelated.example.com', path: '/', secure: false, name: 'sid', value: 'abc123'),
          ],
        },
      );

      expect(server.lastHeaders['cookie'], isNull);
    });

    test('a non-2xx status (expired signed URL) returns null instead of throwing', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.statusCode = 403;
        await request.response.close();
      });

      final sniffer = Mp4TrackSniffer(allowPrivateHosts: true);
      final info = await sniffer.sniff(Uri.parse('http://127.0.0.1:${server.port}/video.mp4'), const {});

      expect(info, isNull);
    });

    test('a 200 whose body is not a valid box tree returns null instead of throwing', () async {
      final server = await _RangeAwareServer.start(Uint8List.fromList(List.filled(100, 7)));
      addTearDown(server.close);

      final sniffer = Mp4TrackSniffer(allowPrivateHosts: true);
      final info = await sniffer.sniff(Uri.parse(server.url), const {});

      expect(info, isNull);
    });

    group('SSRF posture (same guard the rest of the app uses)', () {
      test('by default (allowPrivateHosts: false), a loopback URL is refused - returns null, never throws', () async {
        final fixture = buildFmp4Init();
        final server = await _RangeAwareServer.start(fixture);
        addTearDown(server.close);

        final sniffer = const Mp4TrackSniffer(); // allowPrivateHosts defaults to false
        final info = await sniffer.sniff(Uri.parse(server.url), const {});

        expect(info, isNull);
      });

      test('guard can fail: with allowPrivateHosts: true (test-only escape hatch), the same loopback URL works',
          () async {
        // Directly proves the allowPrivateHosts flag threaded through to
        // HostPolicy.guardedRequest is load-bearing (manually verified,
        // see report: hardcoding `allowPrivateHosts: false` in the
        // guardedRequest call inside sniff() makes this exact test fail
        // the same way the test above expects - reverted immediately
        // after confirming the failure).
        final fixture = buildFmp4Init();
        final server = await _RangeAwareServer.start(fixture);
        addTearDown(server.close);

        final sniffer = Mp4TrackSniffer(allowPrivateHosts: true);
        final info = await sniffer.sniff(Uri.parse(server.url), const {});

        expect(info?.hasVideo, isTrue);
      });
    });

    test(
      'guard-can-fail: a server that ignores Range and streams far past the window is cut off, '
      'not read to completion',
      () async {
        final fixture = buildFmp4Init(); // real moov well within the first 64 KiB
        final server = await _UnboundedServer.start(fixture);
        addTearDown(server.close);

        final sniffer = Mp4TrackSniffer(allowPrivateHosts: true);
        final stopwatch = Stopwatch()..start();
        final info = await sniffer.sniff(Uri.parse(server.url), const {});
        stopwatch.stop();

        // The real moov sits in the first few hundred bytes, so a
        // correctly capped sniff still finds it.
        expect(info?.hasVideo, isTrue);

        // At 15ms/chunk for ~2 MiB, letting the server finish would take
        // several seconds; a sniffer that actually stops at 64 KiB returns
        // within a couple dozen chunks' worth of delay. Guard-can-fail
        // (manually verified, see report): removing the `settle()` call on
        // hitting the byte cap in `_readWindow` (so it only settles on
        // `onDone`) makes this assertion fail - the elapsed time crosses
        // several seconds instead - reverted immediately after confirming.
        expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
        expect(server.finishedWriting, isFalse, reason: 'the server must not have been allowed to finish its 2 MiB body');
      },
    );
  });
}
