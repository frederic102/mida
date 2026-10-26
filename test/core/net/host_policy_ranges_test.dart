import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/net/host_policy.dart';

bool _blocked(String host) => HostPolicy.isDisallowedHost(Uri.parse('http://$host/'));

/// Phase 7 round 2 (Bulwark B10, Assay D1). Each disallowed case has an
/// allowed neighbor just outside the range, so a check that blocks too much
/// fails as surely as one that blocks too little.
void main() {
  group('B10: IPv4 ranges', () {
    test('CGNAT 100.64.0.0/10', () {
      expect(_blocked('100.64.0.1'), isTrue);
      expect(_blocked('100.127.255.254'), isTrue);
      expect(_blocked('100.63.255.255'), isFalse);
      expect(_blocked('100.128.0.1'), isFalse);
    });

    test('benchmarking 198.18.0.0/15', () {
      expect(_blocked('198.18.0.1'), isTrue);
      expect(_blocked('198.19.255.254'), isTrue);
      expect(_blocked('198.17.0.1'), isFalse);
      expect(_blocked('198.20.0.1'), isFalse);
    });

    test('multicast 224.0.0.0/4', () {
      expect(_blocked('224.0.0.1'), isTrue);
      expect(_blocked('239.255.255.250'), isTrue);
      expect(_blocked('223.255.255.254'), isFalse);
    });

    test('reserved 240.0.0.0/4 including 255.255.255.255', () {
      expect(_blocked('240.0.0.1'), isTrue);
      expect(_blocked('255.255.255.255'), isTrue);
    });
  });

  group('B10: IPv6 ranges and IPv4 wrappers', () {
    test('NAT64 64:ff9b::/96 wrapping a private IPv4 is blocked, a public one is not', () {
      expect(_blocked('[64:ff9b::7f00:1]'), isTrue); // 127.0.0.1
      expect(_blocked('[64:ff9b::a9fe:a9fe]'), isTrue); // 169.254.169.254
      expect(_blocked('[64:ff9b::808:808]'), isFalse); // 8.8.8.8
    });

    test('6to4 2002::/16 wrapping a private IPv4 is blocked, a public one is not', () {
      expect(_blocked('[2002:c0a8:101::1]'), isTrue); // 192.168.1.1
      expect(_blocked('[2002:0a00:0001::]'), isTrue); // 10.0.0.1
      expect(_blocked('[2002:808:808::1]'), isFalse); // 8.8.8.8
    });

    test('IPv4-compatible ::a.b.c.d wrapping a private IPv4 is blocked, a public one is not', () {
      expect(_blocked('[::7f00:1]'), isTrue); // ::127.0.0.1
      expect(_blocked('[::a00:1]'), isTrue); // ::10.0.0.1
      expect(_blocked('[::808:808]'), isFalse); // ::8.8.8.8
    });

    test('site-local fec0::/10', () {
      expect(_blocked('[fec0::1]'), isTrue);
      expect(_blocked('[feff::1]'), isTrue);
      // A real global unicast literal (Cloudflare DNS) stays allowed.
      expect(_blocked('[2606:4700:4700::1111]'), isFalse);
    });

    test('astra round 2: multicast, documentation and discard-only ranges, plus the audited basics', () {
      for (final host in const [
        '[ff02::1]', // multicast all-nodes
        '[ff05::2]', // multicast site-local
        '[ff0e::1]', // multicast global scope
        '[2001:db8::1]', // documentation
        '[3fff::1]', // documentation (RFC 9637)
        '[100::1]', // discard-only 100::/64
        '[::]', '[::1]', '[fc00::1]', '[fd12:3456::1]', '[fe80::1]',
      ]) {
        expect(_blocked(host), isTrue, reason: host);
      }
      // Neighbors just outside: 100:0:0:1:: is outside 100::/64; 2001:db9:: is not documentation.
      expect(_blocked('[100:0:0:1::1]'), isFalse);
      expect(_blocked('[2001:db9::1]'), isFalse);
      expect(_blocked('[3fff:1000::1]'), isFalse);
    });

    test('astra round 2: a DNS answer of ff02::1 is refused too', () async {
      await expectLater(
        HostPolicy.assertResolvesToPublicHost(Uri.parse('https://cdn.example.test/v'),
            resolveHost: (_) async => [InternetAddress('ff02::1')]),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'UNSUPPORTED_URL')),
      );
    });

    test('a 2002 6to4 with a CGNAT IPv4 and a NAT64 with a multicast IPv4 are both blocked', () {
      expect(_blocked('[2002:6440:0001::]'), isTrue); // 100.64.0.1
      expect(_blocked('[64:ff9b::e000:1]'), isTrue); // 224.0.0.1
    });
  });

  group('Bulwark round 2: documentation/special v4, Teredo, local NAT64, legacy numeric hosts', () {
    test('IPv4 192.0.0.0/24, 192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24, with neighbors allowed', () {
      for (final host in const ['192.0.0.8', '192.0.2.10', '198.51.100.7', '203.0.113.200']) {
        expect(_blocked(host), isTrue, reason: host);
      }
      for (final host in const ['192.0.1.1', '192.0.3.1', '198.51.101.1', '203.0.114.1']) {
        expect(_blocked(host), isFalse, reason: host);
      }
    });

    test('Teredo 2001::/32 and local-use NAT64 64:ff9b:1::/48', () {
      expect(_blocked('[2001:0:4136:e378:8000:63bf:3fff:fdd2]'), isTrue);
      expect(_blocked('[64:ff9b:1::808:808]'), isTrue);
      expect(_blocked('[2001:4860:4860::8888]'), isFalse); // 2001:4860 is not Teredo
    });

    test('decimal, shortened, hex and octal IPv4 forms of loopback are refused', () {
      for (final host in const ['2130706433', '127.1', '0x7f.1', '0x7f000001', '0177.0.0.1', '127.0.1', '0x7F.0.0.1']) {
        expect(HostPolicy.isDisallowedHost(Uri.parse('https://$host/')), isTrue, reason: host);
      }
    });

    test('numeric-looking but invalid forms are refused, never guessed', () {
      for (final host in const ['1.2.3.4.5', '256.1.1.1', '0x1g.1', '09.1.1.1', '4294967296']) {
        expect(HostPolicy.legacyIPv4(host), isEmpty, reason: host);
        expect(_blocked(host), isTrue, reason: host);
      }
    });

    test('a public address in a legacy form normalizes and is allowed; ordinary names are untouched', () {
      expect(HostPolicy.legacyIPv4('134744072'), [8, 8, 8, 8]);
      expect(_blocked('134744072'), isFalse);
      expect(HostPolicy.legacyIPv4('0x8.0x8.0x8.0x8'), [8, 8, 8, 8]);
      expect(HostPolicy.legacyIPv4('cdn1.example.com'), isNull);
      expect(HostPolicy.legacyIPv4('example.com.'), isNull);
    });
  });

  group('D1: assertResolvesToPublicHost statuses', () {
    final url = Uri.parse('https://cdn.example.test/v.mp4?sig=SECRET');

    test('a lookup failure is NETWORK (still fails closed), host named, no query echoed', () async {
      Object? caught;
      try {
        await HostPolicy.assertResolvesToPublicHost(url,
            resolveHost: (_) async => throw const SocketException('Failed host lookup (OS Error: errno = 11001)'));
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<MediaExtractionException>().having((e) => e.status, 'status', 'NETWORK'));
      expect(caught.toString(), contains('cdn.example.test'));
      expect(caught.toString(), isNot(contains('SECRET')));
      expect(caught.toString(), isNot(contains('errno')));
    });

    test('a DNS answer naming a private address is still UNSUPPORTED_URL', () async {
      await expectLater(
        HostPolicy.assertResolvesToPublicHost(url,
            resolveHost: (_) async => [InternetAddress('100.64.0.7')]),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'UNSUPPORTED_URL')),
      );
    });

    test('a public DNS answer passes', () async {
      await HostPolicy.assertResolvesToPublicHost(url, resolveHost: (_) async => [InternetAddress('93.184.216.34')]);
    });
  });
}
