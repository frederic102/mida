import 'dart:math' as math;
import 'dart:typed_data';

/// Computes the `token` query parameter required by X's public syndication
/// endpoint (`cdn.syndication.twimg.com/tweet-result`), reverse engineered
/// from X's own embedded-tweet widget JS:
/// `token = ((id / 1e15) * PI).toString(36)` with every `0`
/// and `.` character stripped afterwards.
///
/// `Number.prototype.toString(36)` on a non-integer double has no
/// equivalent in `dart:core`. This reimplements V8's
/// `DoubleToRadixCString` free-format algorithm (`src/numbers/
/// conversions.cc`) bit for bit: both JS numbers and Dart `double` are IEEE
/// 754 binary64, so identical arithmetic performed in the same order
/// produces identical bits, including the round-to-even correction (with
/// carry propagation) V8 applies to the final digit.
class SyndicationToken {
  const SyndicationToken._();

  static const _digits = '0123456789abcdefghijklmnopqrstuvwxyz';
  static const _radix = 36;
  static final _stripPattern = RegExp(r'[0.]');

  /// [tweetId] is the numeric status id as a string (as extracted from the
  /// URL). Tweet ids (up to 19 digits) fit in Dart's 64-bit `int` on the
  /// native VM this desktop app runs on, same range as JS's
  /// `Number(twid)`.
  static String forTweetId(String tweetId) {
    final id = int.parse(tweetId);
    final value = (id.toDouble() / 1e15) * math.pi;
    final radixString = _doubleToRadixString(value);
    return radixString.replaceAll(_stripPattern, '');
  }

  /// Port of V8's `DoubleToRadixCString`: splits [value] into an integer
  /// and fractional part, then greedily emits fractional digits until the
  /// accumulated rounding error (`delta`) makes further digits meaningless,
  /// applying round-to-even (with carry propagation back into earlier
  /// digits, and into the integer part if every fractional digit was
  /// already the top digit of the radix) on the final digit. [value] must
  /// be finite.
  static String _doubleToRadixString(double value) {
    final isNegative = value < 0;
    final v = isNegative ? -value : value;

    var integer = v.floorToDouble();
    var fraction = v - integer;
    var delta = 0.5 * (_nextDouble(v) - v);
    final minPositive = _nextDouble(0.0);
    if (delta < minPositive) delta = minPositive;

    final fractionDigits = <int>[];
    if (fraction >= delta) {
      while (true) {
        fraction *= _radix;
        delta *= _radix;
        final digit = fraction.floor();
        fractionDigits.add(digit);
        fraction -= digit;

        final roundsUp = fraction > 0.5 || (fraction == 0.5 && digit.isOdd);
        if (roundsUp && fraction + delta > 1) {
          integer = _carryIntoFractionDigits(fractionDigits, integer);
          break;
        }
        if (fraction < delta) break;
      }
    }

    final buffer = StringBuffer();
    if (isNegative) buffer.write('-');
    buffer.write(_integerDigits(integer));
    if (fractionDigits.isNotEmpty) {
      buffer.write('.');
      for (final digit in fractionDigits) {
        buffer.write(_digits[digit]);
      }
    }
    return buffer.toString();
  }

  /// Applies a rounding carry to the trailing fractional digits (dropping
  /// any that were already the top digit of the radix, i.e. `35`), and
  /// returns [integer] incremented by one if the carry propagated past the
  /// first fractional digit entirely (e.g. `0.999...` rounding up to `1`).
  static double _carryIntoFractionDigits(List<int> fractionDigits, double integer) {
    while (fractionDigits.isNotEmpty && fractionDigits.last == _radix - 1) {
      fractionDigits.removeLast();
    }
    if (fractionDigits.isEmpty) return integer + 1;
    fractionDigits[fractionDigits.length - 1] += 1;
    return integer;
  }

  static String _integerDigits(double integer) {
    var n = integer.toInt();
    if (n == 0) return '0';
    final digits = <String>[];
    while (n > 0) {
      digits.add(_digits[n % _radix]);
      n ~/= _radix;
    }
    return digits.reversed.join();
  }

  /// The next representable `double` above non-negative [value] (like C's
  /// `nextafter`), via direct IEEE 754 bit manipulation. Only ever called
  /// here with [value] >= 0, so incrementing the raw bit pattern by one is
  /// always a step towards positive infinity.
  static double _nextDouble(double value) {
    final bytes = ByteData(8)..setFloat64(0, value);
    final bits = bytes.getUint64(0);
    final next = ByteData(8)..setUint64(0, bits + 1);
    return next.getFloat64(0);
  }
}
