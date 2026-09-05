import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/net/host_policy.dart';

/// Consolidated from `test/core/extractors/generic/host_policy_test.dart`
/// and `test/core/extractors/browser_capture/host_policy_test.dart` (both
/// deleted) now that `lib/core/net/host_policy.dart` is the single
/// implementation (council follow-up F1).
void main() {
  group('HostPolicy.isDisallowedHost', () {
    test('public hostname is allowed', () {
      expect(HostPolicy.isDisallowedHost(Uri.parse('https://vimeo.com/76979871')), isFalse);
    });

    test('public IPv4 is allowed', () {
      expect(HostPolicy.isDisallowedHost(Uri.parse('http://93.184.216.34/')), isFalse);
    });

    test('IPv4 loopback (127.0.0.1) is disallowed', () {
      expect(HostPolicy.isDisallowedHost(Uri.parse('http://127.0.0.1:9222/json/version')), isTrue);
    });

    test('IPv4 loopback range (127.5.5.5) is disallowed', () {
      expect(HostPolicy.isDisallowedHost(Uri.parse('http://127.5.5.5/')), isTrue);
    });

    test('0.0.0.0 is disallowed', () {
      expect(HostPolicy.isDisallowedHost(Uri.parse('http://0.0.0.0/')), isTrue);
    });

    test('RFC1918 10.0.0.0/8 is disallowed', () {
      expect(HostPolicy.isDisallowedHost(Uri.parse('http://10.1.2.3/')), isTrue);
    });

    test('RFC1918 172.16.0.0/12 is disallowed', () {
      expect(HostPolicy.isDisallowedHost(Uri.parse('http://172.16.0.5/')), isTrue);
      expect(HostPolicy.isDisallowedHost(Uri.parse('http://172.31.255.255/')), isTrue);
    });

    test('172.15.x.x and 172.32.x.x are outside 172.16.0.0/12 and allowed', () {
      expect(HostPolicy.isDisallowedHost(Uri.parse('http://172.15.0.1/')), isFalse);
      expect(HostPolicy.isDisallowedHost(Uri.parse('http://172.32.0.1/')), isFalse);
    });

    test('RFC1918 192.168.0.0/16 is disallowed', () {
      expect(HostPolicy.isDisallowedHost(Uri.parse('http://192.168.1.1/')), isTrue);
    });

    test('link-local 169.254.0.0/16 (cloud metadata range) is disallowed', () {
      expect(HostPolicy.isDisallowedHost(Uri.parse('http://169.254.169.254/latest/meta-data/')), isTrue);
    });

    test('IPv6 loopback (::1) and unspecified (::) are disallowed', () {
      expect(HostPolicy.isDisallowedHost(Uri.parse('http://[::1]:9222/')), isTrue);
      expect(HostPolicy.isDisallowedHost(Uri.parse('http://[::]/')), isTrue);
    });

    test('IPv6 link-local (fe80::/10) is disallowed', () {
      expect(HostPolicy.isDisallowedHost(Uri.parse('http://[fe80::1]/')), isTrue);
      expect(HostPolicy.isDisallowedHost(Uri.parse('http://[fe80:1234::5678]/')), isTrue);
    });

    test('IPv6 unique-local (fc00::/7, includes fd00::/8) is disallowed', () {
      expect(HostPolicy.isDisallowedHost(Uri.parse('http://[fc00::1]/')), isTrue);
      expect(HostPolicy.isDisallowedHost(Uri.parse('http://[fd12:3456::1]/')), isTrue);
      expect(HostPolicy.isDisallowedHost(Uri.parse('http://[fd00::1]/')), isTrue);
    });

    test('IPv4-mapped IPv6 loopback (::ffff:127.0.0.1) is disallowed', () {
      expect(HostPolicy.isDisallowedHost(Uri.parse('http://[::ffff:127.0.0.1]/')), isTrue);
    });

    test('IPv4-mapped IPv6 cloud-metadata address (::ffff:169.254.169.254) is disallowed', () {
      expect(HostPolicy.isDisallowedHost(Uri.parse('http://[::ffff:169.254.169.254]/')), isTrue);
    });

    test('public IPv6 is allowed', () {
      expect(HostPolicy.isDisallowedHost(Uri.parse('http://[2606:4700:4700::1111]/')), isFalse);
    });

    test('"localhost" and "*.localhost" are disallowed', () {
      expect(HostPolicy.isDisallowedHost(Uri.parse('http://localhost:8080/')), isTrue);
      expect(HostPolicy.isDisallowedHost(Uri.parse('HTTP://LOCALHOST/')), isTrue);
      expect(HostPolicy.isDisallowedHost(Uri.parse('http://foo.localhost/')), isTrue);
    });

    test('a hostname that merely contains a private-looking substring is allowed (syntactic check only)', () {
      expect(HostPolicy.isDisallowedHost(Uri.parse('http://10.0.0.1.example.com/')), isFalse);
    });

    // Guard-can-fail evidence (see report): temporarily short-circuiting
    // `_isDisallowedIPv6`'s mapped-IPv6 unwrap (making `isV4Mapped` always
    // false) made the "::ffff:127.0.0.1" and "::ffff:169.254.169.254"
    // tests above go red (both flipped to `isFalse`, i.e. allowed),
    // proving the unwrap is load-bearing rather than decorative.

    group('a hostless URI (blob:/data:/mailto:) is disallowed', () {
      // Live-caught (coordinator repro, coverage probe): a browser-captured
      // `blob:` URL survived into `MediaInfo.formats` for one site, and
      // `HttpClient.getUrl` throws a raw `ArgumentError` ("No host
      // specified in URI ...") for it rather than any typed exception this
      // app catches - a Dart `Error`, not an `Exception`, so
      // `MediaDownloadPipeline`'s per-candidate `on Exception` handler
      // does not catch it and the whole download crashes instead of just
      // that one candidate failing. `isDisallowedHost` returning true here
      // (rather than the old `host.isEmpty -> false`) is what turns that
      // into a clean, catchable refusal at the single choke point every
      // fetch already goes through.
      test('guard can fail: a blob: URI (no host at all) is disallowed', () {
        expect(HostPolicy.isDisallowedHost(Uri.parse('blob:https://example.com/3088eec3-c0ca-4021-8b54')), isTrue);
      });

      test('guard can fail: a data: URI is disallowed', () {
        expect(HostPolicy.isDisallowedHost(Uri.parse('data:text/plain;base64,SGVsbG8=')), isTrue);
      });

      test('assertAllowedHost throws for a hostless URI, not a raw ArgumentError from further down the chain', () {
        expect(
          () => HostPolicy.assertAllowedHost(Uri.parse('blob:https://x/y'), context: 'a captured media URL'),
          throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'UNSUPPORTED_URL')),
        );
      });
    });
  });

  group('HostPolicy.assertAllowedHost', () {
    test('does nothing for an allowed host', () {
      expect(
        () => HostPolicy.assertAllowedHost(Uri.parse('https://vimeo.com/x'), context: 'this page'),
        returnsNormally,
      );
    });

    test('throws UNSUPPORTED_URL with what/why/next for a disallowed host', () {
      expect(
        () => HostPolicy.assertAllowedHost(Uri.parse('http://169.254.169.254/'), context: 'a captured media URL'),
        throwsA(
          isA<MediaExtractionException>()
              .having((e) => e.status, 'status', 'UNSUPPORTED_URL')
              .having((e) => e.reason, 'reason', contains('a captured media URL'))
              .having((e) => e.reason, 'reason', contains('169.254.169.254'))
              .having((e) => e.reason, 'reason', contains('public http(s) URL')),
        ),
      );
    });
  });

  group('HostPolicy.guardedRequest: redirect from an allowed entry host to a private target', () {
    late HttpServer entryServer;
    late HttpServer privateTargetServer;
    var privateTargetRequestCount = 0;

    setUp(() async {
      privateTargetRequestCount = 0;
      privateTargetServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      privateTargetServer.listen((request) async {
        privateTargetRequestCount++;
        request.response.statusCode = 200;
        request.response.write('should never be reached');
        await request.response.close();
      });

      entryServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      entryServer.listen((request) async {
        request.response.statusCode = 302;
        request.response.headers.set('Location', 'http://127.0.0.1:${privateTargetServer.port}/reached');
        await request.response.close();
      });
    });

    tearDown(() async {
      await entryServer.close(force: true);
      await privateTargetServer.close(force: true);
    });

    test(
      'the redirect target is rejected with UNSUPPORTED_URL and never receives a request',
      () async {
        final client = HttpClient();
        addTearDown(() => client.close(force: true));

        await expectLater(
          HostPolicy.guardedRequest(
            client,
            Uri.parse('http://127.0.0.1:${entryServer.port}/start'),
            useHead: false,
            allowPrivateHosts: true, // exempts only hop 0 (the entry URL)
          ),
          throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'UNSUPPORTED_URL')),
        );

        expect(privateTargetRequestCount, 0, reason: 'the redirect target must never be contacted');
      },
    );

    // Guard-can-fail evidence (see report): temporarily changing
    // `guardedRequest`'s per-hop check to exempt every hop (not just hop
    // 0) when `allowPrivateHosts` is true made this test fail: the
    // redirect target received exactly 1 request and no exception was
    // thrown.
  });

  group('HostPolicy.guardedRequest: a hostless URI (blob:) is refused, not a raw ArgumentError', () {
    test(
      'guard can fail: throws MediaExtractionException(UNSUPPORTED_URL), never reaches HttpClient.getUrl at all',
      () async {
        final client = HttpClient();
        addTearDown(() => client.close(force: true));

        // Guard can fail (verified, see report): temporarily reverting
        // `isDisallowedHost`'s `host.isEmpty` branch to `return false` (the
        // pre-fix behavior) made this test fail - `guardedRequest` fell
        // through to `client.getUrl(uri)`, which threw a bare
        // `ArgumentError: Invalid argument(s): No host specified in URI
        // blob:...` instead of the expected `MediaExtractionException`.
        await expectLater(
          HostPolicy.guardedRequest(
            client,
            Uri.parse('blob:https://example.com/3088eec3-c0ca-4021-8b54'),
            useHead: false,
          ),
          throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'UNSUPPORTED_URL')),
        );
      },
    );
  });

  group('HostPolicy.guardedRequest: DNS-rebinding guard', () {
    test(
      'a syntactically public hostname whose injected resolver answers with a loopback address is '
      'rejected before any request is sent',
      () async {
        final client = HttpClient();
        addTearDown(() => client.close(force: true));

        var lookupCalls = 0;
        Future<List<InternetAddress>> fakeResolve(String host) async {
          lookupCalls++;
          expect(host, 'looks-public.example.test');
          return [InternetAddress('127.0.0.1')];
        }

        await expectLater(
          HostPolicy.guardedRequest(
            client,
            Uri.parse('http://looks-public.example.test/video.mp4'),
            useHead: false,
            resolveHost: fakeResolve,
          ),
          throwsA(
            isA<MediaExtractionException>()
                .having((e) => e.status, 'status', 'UNSUPPORTED_URL')
                .having((e) => e.reason, 'reason', contains('127.0.0.1')),
          ),
        );
        expect(lookupCalls, 1);
      },
    );

    test('a literal-IP target never invokes resolveHost at all (isDisallowedHost already covers it)', () async {
      var lookupCalls = 0;
      Future<List<InternetAddress>> shouldNeverRun(String host) async {
        lookupCalls++;
        throw const SocketException('resolveHost must not be called for a literal IP host');
      }

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.write('ok');
        await request.response.close();
      });

      final client = HttpClient();
      addTearDown(() => client.close(force: true));

      final response = await HostPolicy.guardedRequest(
        client,
        Uri.parse('http://127.0.0.1:${server.port}/ok'),
        useHead: false,
        allowPrivateHosts: true,
        resolveHost: shouldNeverRun,
      );
      expect(response.statusCode, 200);
      expect(lookupCalls, 0);
    });

    // Guard-can-fail evidence (verified, see report): temporarily making
    // `assertResolvesToPublicHost` a no-op (as if the DNS-rebinding check
    // did not exist, i.e. the pre-fix behavior) made the first test above
    // fail: `guardedRequest` proceeded straight to `client.getUrl(...)`,
    // which - because `looks-public.example.test` is not a real domain in
    // this sandbox - threw a bare `SocketException` instead of the
    // expected `MediaExtractionException(UNSUPPORTED_URL)`, and
    // `lookupCalls` stayed 0 instead of 1. Reverted immediately after
    // confirming the failure.

    test('a lookup failure fails CLOSED (refused), not proceeds as inconclusive', () async {
      final client = HttpClient();
      addTearDown(() => client.close(force: true));

      Future<List<InternetAddress>> failingResolve(String host) async {
        throw const SocketException('simulated DNS failure (offline sandbox / transient error / NXDOMAIN)');
      }

      await expectLater(
        HostPolicy.guardedRequest(
          client,
          Uri.parse('http://this-will-never-resolve.example.test/video.mp4'),
          useHead: false,
          resolveHost: failingResolve,
        ),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'UNSUPPORTED_URL')),
      );
    });

    // Guard-can-fail evidence (see report): reverting `assertResolvesToPublicHost`'s
    // catch clause to `catch (_) { return; }` (the pre-fix "treat a lookup
    // failure as inconclusive" behavior) makes the test above fail: the
    // call falls through to a real `client.getUrl(...)` against a
    // hostname that cannot resolve, throwing a bare `SocketException`
    // instead of the expected `MediaExtractionException(UNSUPPORTED_URL)`.
  });

  group('HostPolicy.assertResolvesToPublicHost (direct, no fetch)', () {
    test('a hostname resolving to a public address returns normally', () async {
      await expectLater(
        HostPolicy.assertResolvesToPublicHost(
          Uri.parse('https://looks-public.example.test/seg.ts'),
          resolveHost: (host) async => [InternetAddress('93.184.216.34')],
        ),
        completes,
      );
    });

    test('a hostname resolving to a private address (10.0.0.1) is rejected', () async {
      await expectLater(
        HostPolicy.assertResolvesToPublicHost(
          Uri.parse('https://looks-public.example.test/seg.ts'),
          resolveHost: (host) async => [InternetAddress('10.0.0.1')],
        ),
        throwsA(
          isA<MediaExtractionException>()
              .having((e) => e.status, 'status', 'UNSUPPORTED_URL')
              .having((e) => e.reason, 'reason', contains('10.0.0.1')),
        ),
      );
    });

    test('a literal-IP host never invokes resolveHost at all', () async {
      var lookupCalls = 0;
      await HostPolicy.assertResolvesToPublicHost(
        Uri.parse('https://93.184.216.34/seg.ts'),
        resolveHost: (host) async {
          lookupCalls++;
          return [InternetAddress('93.184.216.34')];
        },
      );
      expect(lookupCalls, 0);
    });
  });
}
