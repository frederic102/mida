import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/generic/hls_master_format_mapper.dart';
import 'package:mida/core/extractors/media_models.dart';

/// Residual follow-up (`docs/plan-phase6-av-pairing.md` "라운드 4 판결",
/// "중복 format id 테스트"). `HlsMasterFormatMapper.formatsFor`/
/// `formatsForVariants` derive each variant's own `MediaFormat.id` from its
/// *own* master URL plus its position in the list it was given
/// (`<masterUrl>#<i>`) - never from anything that could tell two different
/// calls' results apart. Two extractors that independently mapped the
/// *same* master URL (a redirect chain landing back on an identical
/// playlist URL from two different starting points is exactly how this
/// happens live) therefore emit formats whose ids collide across those two
/// calls, even though the underlying variant URLs differ. Neither this
/// mapper nor anything downstream may quietly collapse that collision -
/// there is no `Map<String, MediaFormat>`/`Set<String>` keyed on id
/// anywhere on this path, and this test is the guard that a future "helpful"
/// id-keyed dedup does not reintroduce one.
void main() {
  group('HlsMasterFormatMapper - duplicate format ids across two calls', () {
    test('two formatsFor calls that happen to assign the same id both survive being combined into one list', () {
      const masterUrl = 'https://cdn.example.com/streams/master.m3u8';
      const playlistA = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,CODECS="avc1.42c01e,mp4a.40.2"
variant_a.m3u8
''';
      const playlistB = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=900000,RESOLUTION=640x360,CODECS="avc1.42c01e,mp4a.40.2"
variant_b.m3u8
''';

      final formatsA = HlsMasterFormatMapper.formatsFor(masterUrl, playlistA);
      final formatsB = HlsMasterFormatMapper.formatsFor(masterUrl, playlistB);

      // Both calls assign the same id to their single variant - the whole
      // point of this fixture (same master URL, same list position).
      expect(formatsA.single.id, formatsB.single.id);
      expect(formatsA.single.url, isNot(formatsB.single.url));

      final combined = <MediaFormat>[...formatsA, ...formatsB];

      expect(combined, hasLength(2), reason: 'a duplicate id must never collapse two distinct formats into one');
      expect(combined.map((f) => f.url), containsAll([formatsA.single.url, formatsB.single.url]));
    });
  });
}
