import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/twitter/syndication_token.dart';

// Reference values generated with:
//   node -e "function tok(id){const n=(Number(id)/1e15)*Math.PI;
//     return n.toString(36).replace(/[0.]/g,'');}console.log(tok('<id>'))"
void main() {
  group('SyndicationToken.forTweetId', () {
    test('matches the plan doc worked example (captainamerica test tweet)', () {
      expect(SyndicationToken.forTweetId('719944021058060289'), '1qtrrnvqpw');
    });

    test('matches a second real tweet id (starwars card tweet)', () {
      expect(SyndicationToken.forTweetId('665052190608723968'), '1m1bmpg2m2t');
    });

    test('matches a third real tweet id (NASA card tweet)', () {
      expect(SyndicationToken.forTweetId('623160978427936768'), '1idpugrdw8w');
    });

    test('handles a tiny id that needs many leading zero-stripped fraction digits '
        'and exercises the round-to-even carry path', () {
      // Without the carry-propagation correction in _doubleToRadixString
      // this produces a one-character mismatch against Node ("...f28m"
      // instead of "...f28n"), caught while building this parser.
      expect(SyndicationToken.forTweetId('1'), 'bhi2ay3f28n');
    });

    test('handles an id near the 64-bit integer ceiling, also a carry case', () {
      expect(SyndicationToken.forTweetId('9223372036854775807'), 'mcw2svce2ao');
    });
  });
}
