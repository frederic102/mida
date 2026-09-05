import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/bilibili/bilibili_wbi_signer.dart';

void main() {
  group('BilibiliWbiSigner against a real img/sub key pair fetched live 2026-09-05', () {
    // Real values from a live `x/web-interface/nav` response
    // (`docs/plan-phase5-coverage.md` Lane D follow-up):
    // wbi_img.img_url = https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png
    // wbi_img.sub_url = https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png
    const imgKey = '7cd084941338484aae1ad9425b84077c';
    const subKey = '4932caff0ff746eab6f01bf08b70ac45';

    test('derives the documented mixin key from a real img/sub pair', () {
      // Guard-can-fail: independently verified with a Python reference
      // implementation of the same public mixin-key-table algorithm
      // (`hashlib`/`urllib.parse`, no Dart code involved) - transposing
      // any two entries in BilibiliWbiSigner's table changes this value.
      expect(
        const BilibiliWbiSigner().mixinKey(imgKey, subKey),
        'ea1db124af3c7062474693fa704f4ff8',
      );
    });

    test('signs playurl params into the exact w_rid a live Python reference computed', () {
      final signed = const BilibiliWbiSigner().sign(
        {'bvid': 'BV1GJ411x7h7', 'cid': '66279060', 'qn': '80', 'fnval': '16', 'fourk': '1'},
        imgKey,
        subKey,
        now: () => DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000),
      );

      expect(signed['wts'], '1700000000');
      // Independently computed: hashlib.md5(
      //   b'bvid=BV1GJ411x7h7&cid=66279060&fnval=16&fourk=1&qn=80&'
      //   b'wts=1700000000ea1db124af3c7062474693fa704f4ff8'
      // ).hexdigest()
      expect(signed['w_rid'], 'f680296662d9204eb625be8a03ea461d');
    });

    test('strips !\'()* from values before signing (matches the public JS implementation)', () {
      final withSpecials = const BilibiliWbiSigner().sign(
        {'title': "a!'b(c)*d"},
        imgKey,
        subKey,
        now: () => DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000),
      );
      final withoutSpecials = const BilibiliWbiSigner().sign(
        {'title': 'abcd'},
        imgKey,
        subKey,
        now: () => DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000),
      );
      expect(withSpecials['w_rid'], withoutSpecials['w_rid']);
    });
  });

  group('BilibiliWbiSigner.keyFromUrl', () {
    test('extracts the filename without extension', () {
      expect(
        BilibiliWbiSigner.keyFromUrl('https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png'),
        '7cd084941338484aae1ad9425b84077c',
      );
    });
  });
}
