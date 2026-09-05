import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/utils/file_utils.dart';

void main() {
  group('FileUtils.sanitizeFileName reserved Windows device names', () {
    for (final reserved in ['CON', 'PRN', 'AUX', 'NUL', 'COM1', 'COM9', 'LPT1', 'LPT9']) {
      test('$reserved is prefixed so it is not a device name', () {
        expect(FileUtils.sanitizeFileName(reserved), '_$reserved');
      });

      test('${reserved.toLowerCase()} (lowercase) is prefixed too', () {
        expect(FileUtils.sanitizeFileName(reserved.toLowerCase()), '_${reserved.toLowerCase()}');
      });

      test('$reserved with an extension is still prefixed', () {
        expect(FileUtils.sanitizeFileName('$reserved.txt'), '_$reserved.txt');
      });
    }

    test('a name that merely contains a reserved word is left alone', () {
      expect(FileUtils.sanitizeFileName('CONcert Tour'), 'CONcert Tour');
      expect(FileUtils.sanitizeFileName('My CON Video'), 'My CON Video');
    });

    test('a normal title is unaffected', () {
      expect(FileUtils.sanitizeFileName('My Vacation Video'), 'My Vacation Video');
    });
  });

  group('FileUtils.sanitizeFileName trailing dots/spaces', () {
    test('trailing dots are stripped', () {
      expect(FileUtils.sanitizeFileName('Title...'), 'Title');
    });

    test('trailing spaces (after collapsing internal whitespace) are stripped', () {
      expect(FileUtils.sanitizeFileName('Title   '), 'Title');
    });

    test('a name that becomes empty after stripping falls back to a single underscore', () {
      expect(FileUtils.sanitizeFileName('...'), '_');
    });
  });

  group('FileUtils.sanitizeFileName length cap', () {
    test('a name over 150 chars is truncated to 150', () {
      final longName = 'a' * 300;
      final result = FileUtils.sanitizeFileName(longName);
      expect(result.length, lessThanOrEqualTo(150));
    });

    test('truncation does not leave a trailing dot/space from the cut point', () {
      final longName = '${'a' * 149}. more text that gets cut off';
      final result = FileUtils.sanitizeFileName(longName);
      expect(result.length, lessThanOrEqualTo(150));
      expect(result.endsWith('.'), isFalse);
      expect(result.endsWith(' '), isFalse);
    });
  });

  group('FileUtils.sanitizeFileName existing behavior (unchanged)', () {
    test('illegal Windows characters are replaced with underscore', () {
      expect(FileUtils.sanitizeFileName('a<b>c:d"e/f\\g|h?i*j'), 'a_b_c_d_e_f_g_h_i_j');
    });

    test('internal whitespace runs collapse to a single space', () {
      expect(FileUtils.sanitizeFileName('a    b'), 'a b');
    });
  });

  group('FileUtils.sanitizeFileName invisible/control character stripping (security)', () {
    test('a right-to-left override (RLO, U+202E) used for extension spoofing is stripped', () {
      // Classic attack: "evil<RLO>gnp.exe" renders right-to-left after the
      // override, displaying as if it ended in "...exe.png" while the
      // bytes on disk are still ".exe". The override itself must not
      // survive into the name written to disk. Written as a `\u` escape
      // (not a literal bidi character in source) per the project's
      // byte-level-verification rule for invisible characters.
      final spoofed = 'evil${String.fromCharCode(0x202E)}gnp.exe';
      final result = FileUtils.sanitizeFileName(spoofed);
      expect(result, 'evilgnp.exe');
      // Byte-level check: confirm the override is truly gone from the
      // UTF-16 code units, not just invisible to a naive string compare.
      expect(result.codeUnits.contains(0x202E), isFalse);
    });

    test('every bidi override/zero-width/format character in the denylist is stripped', () {
      const codePoints = [
        0x200B, 0x200C, 0x200D, 0x200E, 0x200F, // zero-width + bidi marks
        0x202A, 0x202B, 0x202C, 0x202D, 0x202E, // bidi embeds/overrides
        0x2066, 0x2067, 0x2068, 0x2069, // bidi isolates
        0xFEFF, // BOM / zero-width no-break space
      ];
      for (final codePoint in codePoints) {
        final char = String.fromCharCode(codePoint);
        final result = FileUtils.sanitizeFileName('a${char}b');
        expect(result, 'ab', reason: 'U+${codePoint.toRadixString(16)} was not stripped');
      }
    });

    test('raw control bytes (e.g. NUL, BEL) are stripped, not substituted with underscore', () {
      final result = FileUtils.sanitizeFileName('a\x00b\x07c');
      expect(result, 'abc');
    });

    test('a normal accented/non-Latin title is left untouched (only Cf/Cc chars are targeted)', () {
      expect(FileUtils.sanitizeFileName('Café 日本語 Résumé'), 'Café 日本語 Résumé');
    });
  });

  group('FileUtils.sanitizeFileName rune-safe truncation (no split surrogate pairs)', () {
    test('an emoji (astral, 2 code units) landing exactly at the 150 cap is kept whole', () {
      const emoji = '😀'; // U+1F600, a surrogate pair in UTF-16
      final title = ('a' * 148) + emoji; // 148 + 2 = 150 code units exactly
      expect(title.length, 150);

      final result = FileUtils.sanitizeFileName(title);
      expect(result.length, 150);
      expect(result.endsWith(emoji), isTrue, reason: 'the emoji must survive whole, not as a lone surrogate');
    });

    test('an emoji landing one code unit over the cap is dropped whole, not split', () {
      const emoji = '😀';
      final title = ('a' * 149) + emoji; // 149 + 2 = 151 code units, one over cap
      expect(title.length, 151);

      final result = FileUtils.sanitizeFileName(title);
      expect(result.length, lessThanOrEqualTo(150));
      expect(result, 'a' * 149, reason: 'the emoji does not fit and must be dropped entirely');
      // Directly verify no lone surrogate half was left dangling at the end.
      final lastUnit = result.codeUnitAt(result.length - 1);
      expect(lastUnit < 0xD800 || lastUnit > 0xDFFF, isTrue, reason: 'result ends mid-surrogate-pair');
    });
  });

  group('FileUtils folder-opener test seam (never spawn a real OS window from a test)', () {
    tearDown(() {
      FileUtils.folderOpenerOverride = null;
    });

    test('openFolder calls the override instead of the real OS opener', () async {
      final calls = <String>[];
      FileUtils.folderOpenerOverride = (path) async => calls.add(path);

      await FileUtils.openFolder('/tmp/some/download/dir');

      expect(calls, ['/tmp/some/download/dir'],
          reason: 'the override must be invoked with the exact path, and be '
              'the only thing invoked, i.e. no real Process.run happened '
              '(that would hang/pop a window and this test would never '
              'reach this assertion in a sandboxed CI runner)');
    });

    test('openFileLocation calls the override instead of the real OS opener', () async {
      final calls = <String>[];
      FileUtils.folderOpenerOverride = (path) async => calls.add(path);

      await FileUtils.openFileLocation('/tmp/some/download/dir/video.mp4');

      expect(calls, ['/tmp/some/download/dir/video.mp4']);
    });

    test('with no override set, running under flutter test still does not throw '
        '(FLUTTER_TEST safety net)', () async {
      // Belt-and-suspenders: even if a caller forgets folderOpenerOverride,
      // FileUtils must not attempt a real Process.run while FLUTTER_TEST=true
      // (set by the flutter test runner itself). This completing at all,
      // quickly and without spawning anything, is the assertion.
      await FileUtils.openFolder('/tmp/whatever');
      await FileUtils.openFileLocation('/tmp/whatever/file.txt');
    });
  });

  group('FileUtils.fitBaseNameToPath', () {
    // Live-caught (coordinator repro, coverage probe): a `PathAccessException`
    // on the final rename for a long page title combined with a long output
    // directory - this trims the base name so the combined path stays under
    // the 240-char budget rather than leaving that to a rename-time failure.
    test('a short base name under a short outputDir is left untouched', () {
      expect(FileUtils.fitBaseNameToPath('/tmp/out', 'My Vacation Video'), 'My Vacation Video');
    });

    test('guard can fail: a base name that would push the combined path past the budget is trimmed', () {
      final outputDir = '/tmp/${'d' * 100}'; // 105 chars
      final longTitle = 'A' * 200;

      final fitted = FileUtils.fitBaseNameToPath(outputDir, longTitle, maxTotalLength: 240);

      expect(fitted.length, lessThan(longTitle.length));
      // 240 total - 105 (outputDir) - 24 (reserved for separator/extension/suffix)
      expect(fitted.length, 111);
      expect('$outputDir/$fitted.mp4'.length, lessThanOrEqualTo(240),
          reason: 'the real separator + extension are shorter than the reserved headroom, so the combined '
              'path must clear the 240-char budget');
    });

    test('an outputDir so long it eats the entire budget falls back to a single-character name, not empty '
        'or negative-length', () {
      final outputDir = '/tmp/${'d' * 300}';
      expect(FileUtils.fitBaseNameToPath(outputDir, 'anything'), '_');
    });

    test('a base name exactly at the budget boundary is left untouched (no off-by-one over-trim)', () {
      const outputDir = '/tmp/out'; // 8 chars
      // budget = 240 - 8 - 24 = 208
      final exactlyAtBudget = 'A' * 208;
      expect(FileUtils.fitBaseNameToPath(outputDir, exactlyAtBudget), exactlyAtBudget);
    });

    test('trimming never splits a surrogate pair (astral-plane characters, e.g. emoji, in the title)', () {
      final outputDir = '/tmp/${'d' * 100}';
      final emojiTitle = '\u{1F600}' * 200; // grinning face emoji, 2 UTF-16 code units each
      final fitted = FileUtils.fitBaseNameToPath(outputDir, emojiTitle);
      // Every code point in the fitted string must still be a complete,
      // valid rune - String.runes throws on a dangling lone surrogate.
      expect(() => fitted.runes.toList(), returnsNormally);
    });
  });
}
