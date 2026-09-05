import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/extractors/odysee/odysee_resolve_parser.dart';

void main() {
  group('OdyseeResolveParser.parse against a real captured resolve response', () {
    test('reads name/claim_id/sd_hash/title/author/duration/width/height', () async {
      final raw = await File('test/fixtures/odysee_resolve.json').readAsString();
      final json = jsonDecode(raw) as Map<String, dynamic>;

      final claim = const OdyseeResolveParser().parse(json, lbryUrl: 'lbry://@lbry#3f/odysee#7');
      expect(claim.name, 'odysee');
      expect(claim.claimId, '7a416c44a6888d94fe045241bbac055c726332aa');
      expect(claim.sdHash, startsWith('a27e60ccaef16af441d76471f87d211a1791cc580d2b1dc333f81bab67dca8fa9bfea9'));
      expect(claim.title, 'Introducing Odysee: A Short Video');
      expect(claim.author, '@lbry');
      expect(claim.duration, const Duration(seconds: 143));
      expect(claim.width, 1920);
      expect(claim.height, 1080);
    });

    test('throws NOT_FOUND when the result has no entry for the requested url', () {
      expect(
        () => const OdyseeResolveParser().parse({'result': {}}, lbryUrl: 'lbry://gone'),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'NOT_FOUND')),
      );
    });

    test('throws NOT_FOUND when the entry is an error object', () {
      expect(
        () => const OdyseeResolveParser().parse(
          {
            'result': {
              'lbry://gone': {'error': 'Could not find claim'},
            },
          },
          lbryUrl: 'lbry://gone',
        ),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'NOT_FOUND')),
      );
    });

    test('throws UNSUPPORTED_MEDIA when the claim has no source', () {
      expect(
        () => const OdyseeResolveParser().parse(
          {
            'result': {
              'lbry://@x/y': {
                'claim_id': 'c1',
                'name': 'y',
                'value': {'title': 'a channel post with no video'},
              },
            },
          },
          lbryUrl: 'lbry://@x/y',
        ),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'UNSUPPORTED_MEDIA')),
      );
    });
  });
}
