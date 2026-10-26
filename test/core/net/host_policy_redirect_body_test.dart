import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_extractor.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/net/host_policy.dart';

const _secretPath = 'KSPATHSECRET';
const _secretQuery = 'QUERYSECRET';

/// Catch-all stand-in that runs one HostPolicy check on the URL it gets.
class _GuardedExtractor implements MediaExtractor {
  final Future<void> Function(Uri url) check;
  _GuardedExtractor(this.check);

  @override
  bool canHandle(Uri url) => true;

  @override
  Future<MediaInfo> extract(Uri url) async {
    await check(url);
    throw StateError('unreachable: the check must refuse');
  }
}

Matcher _refusedWithoutSecrets() => isA<MediaExtractionException>()
    .having((e) => e.status, 'status', 'UNSUPPORTED_URL')
    .having((e) => e.reason, 'reason', isNot(contains(_secretPath)))
    .having((e) => e.reason, 'reason', isNot(contains(_secretQuery)))
    .having((e) => e.reason, 'reason', isNot(contains('/ks/')));

/// astra round 2 (host_policy.dart P2 x2): a redirect body is discarded
/// without being read, and refusal reasons name the host only.
void main() {
  group('redirect bodies are discarded, not drained', () {
    late HttpServer server;
    final openResponses = <HttpResponse>[];

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final response = request.response
          ..statusCode = HttpStatus.found
          ..headers.set('location', 'http://127.0.0.1:${server.port}/ks/$_secretPath/next?token=$_secretQuery')
          ..bufferOutput = false;
        response.headers.chunkedTransferEncoding = true;
        // Headers plus a first chunk, then the body never finishes.
        openResponses.add(response);
        response.add(List<int>.filled(4096, 0x41));
        try {
          await response.flush();
        } catch (_) {
          // The client dropping the connection mid-body is the expected outcome.
        }
      });
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('a 302 with an unfinished body is followed to the next-hop check promptly', () async {
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final stopwatch = Stopwatch()..start();
      Object? caught;
      try {
        // Hop 0 (the local fixture) is exempt; the redirect hop is not, so it
        // is refused. Before the fix the never-ending body was drained first,
        // so this never got to the refusal and the 10 s bound below fired.
        await HostPolicy.guardedRequest(
          client,
          Uri.parse('http://127.0.0.1:${server.port}/start'),
          useHead: false,
          allowPrivateHosts: true,
        ).timeout(const Duration(seconds: 10));
      } catch (e) {
        caught = e;
      }
      expect(caught, _refusedWithoutSecrets());
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 10)));
      expect(openResponses, hasLength(1), reason: 'the server sent exactly one unfinished redirect');
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  group('refusal reasons are host-only, also through the registry', () {
    final secretUrl = Uri.parse('https://127.0.0.1/ks/$_secretPath/x?token=$_secretQuery');

    test('guardedRequest refusing a literal private host (no connection is made)', () async {
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final registry = ExtractorRegistry([
        _GuardedExtractor((url) => HostPolicy.guardedRequest(client, url, useHead: true)),
      ]);
      await expectLater(registry.resolveInfo(secretUrl), throwsA(_refusedWithoutSecrets()));
    });

    test('assertResolvesToPublicHost refusing a private DNS answer', () async {
      final url = Uri.parse('https://cdn.example.test/ks/$_secretPath/v.mp4?token=$_secretQuery');
      final registry = ExtractorRegistry([
        _GuardedExtractor((u) => HostPolicy.assertResolvesToPublicHost(u,
            resolveHost: (_) async => [InternetAddress('10.0.0.5')])),
      ]);
      Object? caught;
      try {
        await registry.resolveInfo(url);
      } catch (e) {
        caught = e;
      }
      expect(caught, _refusedWithoutSecrets());
      expect(caught.toString(), contains('cdn.example.test'));
    });
  });
}
