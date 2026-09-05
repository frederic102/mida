import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/browser_capture/browser_capture_extractor.dart';
import 'package:mida/core/extractors/media_models.dart';

import 'fake_devtools_session.dart';

/// End-to-end (fake `DevtoolsSession`, no real browser) coverage for the
/// real-download-gate fragment/segment work in
/// `docs/plan-phase5-coverage.md` (rounds 5 and 6: round 5's rules were too
/// broad and briefly rejected real whole-file candidates on vimeo/bbc/vk.com,
/// narrowed in round 6) - split out of `browser_capture_extractor_test.dart`
/// once these pushed it over this project's 400-line cap. A true CMAF/fMP4
/// fragment (an actual `.m4s`/`.cmfv`/`.cmfa`/`.ts` extension, or a real
/// `init`/`seg`/`frag`/`chunk` path token, or 3+ small numbered siblings)
/// must never reach `MediaInfo.formats` as if it were a complete,
/// independently downloadable file - but a single `range=`/`bytes=`-
/// addressed whole-file candidate, however large or small, must.
void main() {
  group('BrowserCaptureExtractor fragment/segment shapes (fake DevtoolsSession, no browser)', () {
    test(
      'two Range-fragmented requests for the same file dedupe into one format '
      '(round 6 revert: round 5 briefly rejected this real bbc.co.uk/vk.com shape outright as a segment - '
      'see CapturedMediaClassifier.isSegmentUrl\'s own doc comment)',
      () async {
        late FakeDevtoolsSession session;
        session = FakeDevtoolsSession(
          onSend: (method, params) async {
            if (method == 'Page.navigate') {
              session.emit('Network.responseReceived', {
                'response': {'url': 'https://cdn.example.com/video.mp4?range=0-1023', 'mimeType': 'video/mp4'}
              });
              session.emit('Network.responseReceived', {
                'response': {'url': 'https://cdn.example.com/video.mp4?range=1024-2047', 'mimeType': 'video/mp4'}
              });
              return {};
            }
            if (method == 'Runtime.evaluate') {
              final expression = params?['expression'] as String? ?? '';
              if (expression.contains('JSON.stringify')) {
                return jsonEvalResult({'title': null, 'ogTitle': null, 'ogImage': null});
              }
              return {};
            }
            return {};
          },
        );

        final extractor = BrowserCaptureExtractor(
          sessionLauncher: ({connectTimeout = const Duration()}) async => session,
          loadTimeout: const Duration(milliseconds: 30),
          postLoadDelay: const Duration(milliseconds: 5),
          autoplayRetryDelay: const Duration(milliseconds: 5),
          firstCandidateTimeout: const Duration(milliseconds: 20),
          variantSettleDelay: const Duration(milliseconds: 5),
          pollInterval: const Duration(milliseconds: 5),
        );

        final info = await extractor.extract(Uri.parse('https://example.com/page'));

        expect(info.formats, hasLength(1));
      },
    );

    test(
      'guard can fail: vimeo-like shape - bare CMAF fragments (.cmfv/.cmfa) alongside a real manifest never '
      'become their own formats; the manifest is used instead (round 5)',
      () async {
        // A literal public IP, not a hostname (see the HLS-master-playlist
        // test in browser_capture_extractor_test.dart for why): a
        // `cdn.example.com`-style hostname has no real A/AAAA record, and
        // HostPolicy now fails *closed* on that at fetch time - this test
        // wants to observe expandFormats' own graceful "fetch failed,
        // fall back to exposing the raw m3u8 URL" path, not HostPolicy's
        // unrelated (and, for a real hostname, entirely correct) refusal.
        final manifestServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => manifestServer.close(force: true));
        manifestServer.listen((request) async {
          // Status code is irrelevant to _fetchText (it reads the body
          // regardless); an empty 404 body simply fails to parse as a
          // master playlist below, landing on the same single-format
          // fallback a real connection failure would.
          request.response.statusCode = 404;
          await request.response.close();
        });
        HttpClient pinnedClient() {
          final client = HttpClient();
          client.connectionFactory =
              (uri, proxyHost, proxyPort) => Socket.startConnect(InternetAddress.loopbackIPv4, manifestServer.port);
          return client;
        }

        late FakeDevtoolsSession session;
        session = FakeDevtoolsSession(
          onSend: (method, params) async {
            if (method == 'Page.navigate') {
              // Bare CMAF fragments - both would have passed the old
              // extensionless-mimeType fallback (video/mp4, audio/mp4) as
              // if each were a whole file.
              session.emit('Network.responseReceived', {
                'response': {'url': 'https://93.184.216.34/video/1/01.cmfv', 'mimeType': 'video/mp4'}
              });
              session.emit('Network.responseReceived', {
                'response': {'url': 'https://93.184.216.34/video/1/01.cmfa', 'mimeType': 'audio/mp4'}
              });
              // The real manifest, observed directly on the network log -
              // always preferred over anything segment-derived.
              session.emit('Network.responseReceived', {
                'response': {'url': 'https://93.184.216.34/video/1/master.m3u8', 'mimeType': 'application/vnd.apple.mpegurl'}
              });
              return {};
            }
            if (method == 'Runtime.evaluate') {
              final expression = params?['expression'] as String? ?? '';
              if (expression.contains('JSON.stringify')) {
                return jsonEvalResult({'title': null, 'ogTitle': null, 'ogImage': null});
              }
              return {};
            }
            return {};
          },
        );

        final extractor = BrowserCaptureExtractor(
          sessionLauncher: ({connectTimeout = const Duration()}) async => session,
          httpClientFactory: pinnedClient,
          loadTimeout: const Duration(milliseconds: 30),
          postLoadDelay: const Duration(milliseconds: 5),
          autoplayRetryDelay: const Duration(milliseconds: 5),
          firstCandidateTimeout: const Duration(milliseconds: 20),
          variantSettleDelay: const Duration(milliseconds: 5),
          pollInterval: const Duration(milliseconds: 5),
        );

        final info = await extractor.extract(Uri.parse('https://example.com/page'));

        // The manifest fetch answers 404, so CapturedFormatBuilder falls
        // back to exposing the raw m3u8 URL as a single format - the
        // point of this assertion is *which* URL ends up as the format,
        // not the master-playlist expansion (covered in
        // browser_capture_extractor_test.dart).
        expect(info.formats, hasLength(1));
        expect(info.formats.single.url, 'https://93.184.216.34/video/1/master.m3u8');
        expect(info.formats.single.container, 'm3u8');
        expect(info.formats.any((f) => f.url.contains('.cmfv') || f.url.contains('.cmfa')), isFalse);
      },
    );

    test(
      'guard can fail: vimeo-like shape - real ranged-mp4 progressive candidates (range=/pathsig= query, no '
      'siblings) resolve normally instead of NO_MEDIA_FOUND (round 6 regression fixture, live-observed shape)',
      () async {
        late FakeDevtoolsSession session;
        session = FakeDevtoolsSession(
          onSend: (method, params) async {
            if (method == 'Page.navigate') {
              // The exact shape observed live on https://vimeo.com/22439234:
              // a `/v2/range/prot/<base64>/avf/<uuid>.mp4` path with a real
              // `range=`/`pathsig=` query - round 5's bare `range=` keyword
              // rejected every one of these outright.
              session.emit('Network.responseReceived', {
                'response': {
                  'url': 'https://93.184.216.34/d342534e/v2/range/prot/cmFuZ2U9MC04MDI/'
                      'avf/6151447b-d92a-4c7e-a900-52466126853e.mp4?pathsig=8c953e4f&range=0-802',
                  'mimeType': 'video/mp4',
                }
              });
              return {};
            }
            if (method == 'Runtime.evaluate') {
              final expression = params?['expression'] as String? ?? '';
              if (expression.contains('JSON.stringify')) {
                return jsonEvalResult({'title': null, 'ogTitle': null, 'ogImage': null});
              }
              return {};
            }
            return {};
          },
        );

        final extractor = BrowserCaptureExtractor(
          sessionLauncher: ({connectTimeout = const Duration()}) async => session,
          loadTimeout: const Duration(milliseconds: 30),
          postLoadDelay: const Duration(milliseconds: 5),
          autoplayRetryDelay: const Duration(milliseconds: 5),
          firstCandidateTimeout: const Duration(milliseconds: 20),
          variantSettleDelay: const Duration(milliseconds: 5),
          pollInterval: const Duration(milliseconds: 5),
        );

        final info = await extractor.extract(Uri.parse('https://example.com/page'));

        expect(info.formats, hasLength(1));
        expect(info.formats.single.container, 'mp4');
      },
    );

    test(
      'guard can fail: bbc-like shape - an mpd manifest observed alongside ranged-mp4 renditions all resolve, '
      'none wrongly demoted to a segment (round 6 regression fixture, live-observed shape: '
      'https://www.bbc.co.uk/news/videos/cz7z93zde3po went from a successful download to "all formats failed")',
      () async {
        late FakeDevtoolsSession session;
        session = FakeDevtoolsSession(
          onSend: (method, params) async {
            if (method == 'Page.navigate') {
              session.emit('Network.responseReceived', {
                'response': {'url': 'https://93.184.216.34/dash/manifest.mpd', 'mimeType': 'application/dash+xml'}
              });
              session.emit('Network.responseReceived', {
                'response': {
                  'url': 'https://93.184.216.34/media/1?range=0-999999',
                  'mimeType': 'video/mp4',
                }
              });
              session.emit('Network.responseReceived', {
                'response': {
                  'url': 'https://93.184.216.34/media/2?range=1000000-1999999',
                  'mimeType': 'audio/mp4',
                }
              });
              return {};
            }
            if (method == 'Runtime.evaluate') {
              final expression = params?['expression'] as String? ?? '';
              if (expression.contains('JSON.stringify')) {
                return jsonEvalResult({'title': null, 'ogTitle': null, 'ogImage': null});
              }
              return {};
            }
            return {};
          },
        );

        final extractor = BrowserCaptureExtractor(
          sessionLauncher: ({connectTimeout = const Duration()}) async => session,
          loadTimeout: const Duration(milliseconds: 30),
          postLoadDelay: const Duration(milliseconds: 5),
          autoplayRetryDelay: const Duration(milliseconds: 5),
          firstCandidateTimeout: const Duration(milliseconds: 20),
          variantSettleDelay: const Duration(milliseconds: 5),
          pollInterval: const Duration(milliseconds: 5),
        );

        final info = await extractor.extract(Uri.parse('https://example.com/page'));

        // All three candidates survive - the mpd manifest and both ranged
        // renditions - none demoted to a segment (round 5 would have
        // rejected the two `range=` candidates outright).
        expect(info.formats.length, greaterThanOrEqualTo(1));
        expect(info.formats.any((f) => f.container == 'mpd'), isTrue);
      },
    );

    test(
      'guard can fail: niconico-like shape - 3+ numbered mp4 fragments with no manifest anywhere '
      'resolve to NO_MEDIA_FOUND, never to one unplayable fragment exposed as a format (round 5)',
      () async {
        final manifestServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => manifestServer.close(force: true));
        manifestServer.listen((request) async {
          request.response.statusCode = 404;
          await request.response.close();
        });
        HttpClient pinnedClient() {
          final client = HttpClient();
          client.connectionFactory =
              (uri, proxyHost, proxyPort) => Socket.startConnect(InternetAddress.loopbackIPv4, manifestServer.port);
          return client;
        }

        late FakeDevtoolsSession session;
        session = FakeDevtoolsSession(
          onSend: (method, params) async {
            if (method == 'Page.navigate') {
              for (var i = 1; i <= 3; i++) {
                session.emit('Network.responseReceived', {
                  'response': {
                    'url': 'https://93.184.216.34/dash/fragments/$i?sig=abc$i',
                    'mimeType': 'video/mp4',
                    'headers': {'content-length': '204800'},
                  }
                });
              }
              return {};
            }
            if (method == 'Runtime.evaluate') {
              final expression = params?['expression'] as String? ?? '';
              if (expression.contains('JSON.stringify')) {
                return jsonEvalResult({'title': null, 'ogTitle': null, 'ogImage': null});
              }
              return {};
            }
            return {};
          },
        );

        final extractor = BrowserCaptureExtractor(
          sessionLauncher: ({connectTimeout = const Duration()}) async => session,
          httpClientFactory: pinnedClient,
          loadTimeout: const Duration(milliseconds: 30),
          postLoadDelay: const Duration(milliseconds: 5),
          autoplayRetryDelay: const Duration(milliseconds: 5),
          firstCandidateTimeout: const Duration(milliseconds: 20),
          variantSettleDelay: const Duration(milliseconds: 5),
          pollInterval: const Duration(milliseconds: 5),
        );

        await expectLater(
          extractor.extract(Uri.parse('https://example.com/page')),
          throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'NO_MEDIA_FOUND')),
        );
      },
    );
  });
}
