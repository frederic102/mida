import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/generic/media_url_probe.dart';
import 'package:mida/core/extractors/media_models.dart';

void main() {
  group('MediaUrlProbe.containerFromExtension (no network)', () {
    test('recognizes every extension the plan lists', () {
      for (final ext in const ['mp4', 'webm', 'mkv', 'mov', 'm4v', 'm3u8', 'mpd', 'mp3', 'm4a']) {
        final url = Uri.parse('https://cdn.example.com/file.$ext?q=1');
        expect(MediaUrlProbe.containerFromExtension(url), ext, reason: 'extension .$ext should be recognized');
      }
    });

    test('rejects a page URL with no file extension', () {
      expect(MediaUrlProbe.containerFromExtension(Uri.parse('https://example.com/watch?v=abc')), isNull);
    });

    test('rejects a tracker-shaped URL whose extension is not a media container', () {
      expect(
        MediaUrlProbe.containerFromExtension(Uri.parse('https://tracker.example.com/pixel.gif?id=1')),
        isNull,
      );
      expect(
        MediaUrlProbe.containerFromExtension(Uri.parse('https://www.google-analytics.com/analytics.js')),
        isNull,
      );
    });
  });

  group('MediaUrlProbe.containerFromContentType against a local HttpServer', () {
    late HttpServer server;
    String contentType = 'video/mp4';
    int headStatus = 200;

    setUp(() async {
      contentType = 'video/mp4';
      headStatus = 200;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        if (request.method == 'HEAD') {
          request.response.statusCode = headStatus;
          request.response.headers.set('Content-Type', contentType);
          await request.response.close();
          return;
        }
        request.response.statusCode = 200;
        request.response.headers.set('Content-Type', contentType);
        request.response.write('body');
        await request.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('a video/mp4 Content-Type maps to the mp4 container', () async {
      final probe = MediaUrlProbe(allowPrivateHosts: true);
      final container = await probe.containerFromContentType(Uri.parse('http://127.0.0.1:${server.port}/stream'));
      expect(container, 'mp4');
    });

    test('application/vnd.apple.mpegurl maps to m3u8', () async {
      contentType = 'application/vnd.apple.mpegurl';
      final probe = MediaUrlProbe(allowPrivateHosts: true);
      final container = await probe.containerFromContentType(Uri.parse('http://127.0.0.1:${server.port}/stream'));
      expect(container, 'm3u8');
    });

    test('a non-media Content-Type (text/html) yields null', () async {
      contentType = 'text/html; charset=utf-8';
      final probe = MediaUrlProbe(allowPrivateHosts: true);
      final container = await probe.containerFromContentType(Uri.parse('http://127.0.0.1:${server.port}/page'));
      expect(container, isNull);
    });

    test('falls back to GET when the server rejects HEAD', () async {
      headStatus = 405;
      contentType = 'video/webm';
      final probe = MediaUrlProbe(allowPrivateHosts: true);
      final container = await probe.containerFromContentType(Uri.parse('http://127.0.0.1:${server.port}/stream'));
      expect(container, 'webm');
    });

    test('without allowPrivateHosts, a loopback URL is rejected with UNSUPPORTED_URL (SSRF guard)', () async {
      final probe = MediaUrlProbe();
      await expectLater(
        probe.containerFromContentType(Uri.parse('http://127.0.0.1:${server.port}/stream')),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'UNSUPPORTED_URL')),
      );
    });
  });
}
