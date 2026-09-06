import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/download/iso_bmff_reader.dart';

import 'mp4_fixture_bytes.dart';

void main() {
  group('IsoBmffReader.parse', () {
    test('a muxed fast-start init segment yields both tracks with dims and codecs', () {
      final bytes = buildFmp4Init(videoFourCc: 'avc1', audioFourCc: 'mp4a', width: 1920, height: 1080);

      final info = IsoBmffReader.parse(bytes);

      expect(info, isNotNull);
      expect(info!.hasVideo, isTrue);
      expect(info.hasAudio, isTrue);
      expect(info.width, 1920);
      expect(info.height, 1080);
      expect(info.videoCodec, 'avc1');
      expect(info.audioCodec, 'mp4a');
    });

    test('a video-only init segment (no audio trak) reports hasAudio false and no audioCodec', () {
      final bytes = buildFmp4Init(videoFourCc: 'hvc1', audioFourCc: null, width: 640, height: 360);

      final info = IsoBmffReader.parse(bytes);

      expect(info, isNotNull);
      expect(info!.hasVideo, isTrue);
      expect(info.hasAudio, isFalse);
      expect(info.videoCodec, 'hvc1');
      expect(info.audioCodec, isNull);
    });

    test('an audio-only init segment (no video trak) reports hasVideo false and no dims', () {
      final bytes = buildFmp4Init(videoFourCc: null, audioFourCc: 'ec-3');

      final info = IsoBmffReader.parse(bytes);

      expect(info, isNotNull);
      expect(info!.hasVideo, isFalse);
      expect(info.hasAudio, isTrue);
      expect(info.width, isNull);
      expect(info.height, isNull);
      expect(info.audioCodec, 'ec-3');
    });

    test('tkhd version 1 (64-bit fields) is parsed at the shifted width/height offsets', () {
      final bytes = buildFmp4Init(videoFourCc: 'av01', audioFourCc: null, width: 3840, height: 2160, tkhdVersion: 1);

      final info = IsoBmffReader.parse(bytes);

      expect(info, isNotNull);
      expect(info!.width, 3840);
      expect(info.height, 2160);
      expect(info.videoCodec, 'av01');
    });

    for (final fourCc in ['avc1', 'hvc1', 'hev1', 'av01', 'vp09']) {
      test('recognizes video sample-entry fourcc $fourCc', () {
        final info = IsoBmffReader.parse(buildFmp4Init(videoFourCc: fourCc, audioFourCc: null));
        expect(info?.videoCodec, fourCc);
      });
    }

    for (final fourCc in ['mp4a', 'ec-3', 'ac-3', 'Opus']) {
      test('recognizes audio sample-entry fourcc $fourCc', () {
        final info = IsoBmffReader.parse(buildFmp4Init(videoFourCc: null, audioFourCc: fourCc));
        expect(info?.audioCodec, fourCc);
      });
    }

    test('a moof-only fragment (no moov anywhere) returns null', () {
      final info = IsoBmffReader.parse(buildMoofOnlyFragment());
      expect(info, isNull);
    });

    test('guard-can-fail: a non-fast-start file whose moov sits after the fetch window returns null, '
        'not the (absent) moov\'s tracks', () {
      final fullFile = buildNonFastStartMp4(mdatFillerBytes: 200000);
      // Simulates what the sniffer's own 64 KiB window would have received:
      // everything up to moov, but not moov itself.
      final window = fullFile.sublist(0, 65536);

      final info = IsoBmffReader.parse(window);

      expect(info, isNull);
      // Guard-can-fail evidence (manually verified, see report): parsing the
      // *full* file (moov included) for the same bytes does find the track,
      // proving this null is specifically "moov was not in the window we
      // gave it", not "the parser can never find a video trak at all".
      final fullInfo = IsoBmffReader.parse(fullFile);
      expect(fullInfo?.hasVideo, isTrue);
    });

    test('garbage bytes (not a box tree at all) return null rather than throwing', () {
      final garbage = Uint8List.fromList([1, 2, 3]);
      expect(() => IsoBmffReader.parse(garbage), returnsNormally);
      expect(IsoBmffReader.parse(garbage), isNull);
    });

    test('an empty byte array returns null rather than throwing', () {
      expect(IsoBmffReader.parse(Uint8List(0)), isNull);
    });

    test('a box that lies about its size (larger than remaining bytes) is clamped, not a crash', () {
      // size says 999999 but there are nowhere near that many bytes; the
      // reader must clamp the content window to what actually exists.
      final lyingFtyp = Uint8List.fromList([0, 15, 66, 64, ...'ftyp'.codeUnits, 0, 0, 0, 0]);
      expect(() => IsoBmffReader.parse(lyingFtyp), returnsNormally);
      expect(IsoBmffReader.parse(lyingFtyp), isNull); // no moov present either way
    });

    test('a trailing truncated box header (fewer than 8 bytes left) is ignored, not a crash', () {
      final bytes = buildFmp4Init();
      final truncated = Uint8List.fromList([...bytes, 1, 2, 3]); // 3 stray trailing bytes after a real tree
      expect(() => IsoBmffReader.parse(truncated), returnsNormally);
      expect(IsoBmffReader.parse(truncated)?.hasVideo, isTrue);
    });

    group('incomplete moov/trak handling (phase 6 round 2, S-R5)', () {
      test(
        'guard can fail: a moov whose declared size overruns the bytes actually available (a window that cut '
        'it off mid-trak) returns null, even though a well-formed video trak sits near the front',
        () {
          final full = buildFmp4Init(videoFourCc: 'avc1', audioFourCc: 'mp4a');
          // Chops the tail off well inside moov's own declared content
          // (its trak list), so moov's own size field - unchanged - now
          // claims more bytes than this shorter buffer actually has.
          final truncated = full.sublist(0, full.length - 10);

          final info = IsoBmffReader.parse(truncated);

          expect(info, isNull);
          // Guard-can-fail evidence: the exact same bytes, not truncated,
          // parse fine and find the video trak - proving this null is
          // specifically "moov's declared end overran what we had", not
          // "this fixture can never be parsed at all".
          final fullInfo = IsoBmffReader.parse(full);
          expect(fullInfo?.hasVideo, isTrue);
        },
      );

      test(
        'guard can fail: a moov with a literal size of 0 (\'runs to the end of what we have\') is treated as '
        'incomplete, never a confirmed end, and returns null',
        () {
          final withZeroSizeMoov = withMoovSizeOverwritten(buildFmp4Init(), 0);

          final info = IsoBmffReader.parse(withZeroSizeMoov);

          expect(info, isNull);
        },
      );

      test(
        'guard can fail: an otherwise well-formed but empty moov (zero traks) returns null rather than a '
        'confirmed hasVideo:false/hasAudio:false - an empty moov must never look like a source known to '
        'have neither track',
        () {
          final emptyMoov = buildFmp4Init(videoFourCc: null, audioFourCc: null);

          final info = IsoBmffReader.parse(emptyMoov);

          expect(info, isNull);
        },
      );

      test('a trak whose own declared size overruns moov\'s bounds is skipped, not trusted', () {
        // The video trak is complete and near the front; the audio trak's
        // own size field is overwritten to claim far more than actually
        // follows it, inside an otherwise-complete moov. Only the video
        // trak should be trusted.
        final bytes = buildFmp4Init(videoFourCc: 'hvc1', audioFourCc: 'mp4a');
        final withLyingAudioTrakSize = withSecondTrakSizeOverwritten(bytes, 999999);

        final info = IsoBmffReader.parse(withLyingAudioTrakSize);

        expect(info, isNotNull);
        expect(info!.hasVideo, isTrue);
        expect(info.videoCodec, 'hvc1');
        expect(info.hasAudio, isFalse, reason: 'the truncated/lying audio trak must not be trusted');
      });
    });

    group('incomplete inner boxes on the walked path (phase 6 round 3, S-R3-2, Codex #6)', () {
      // Every box `IsoBmffReader` actually descends through, one case
      // each. In all of them the *video* trak is untouched and complete,
      // so a result that still reports hasVideo proves the fixture is
      // otherwise sound and only the named audio-trak box was poisoned.
      for (final path in [
        ['mdia'],
        ['mdia', 'hdlr'],
        ['mdia', 'minf'],
        ['mdia', 'minf', 'stbl'],
        ['mdia', 'minf', 'stbl', 'stsd'],
      ]) {
        test('an audio trak whose ${path.join('>')} overruns its parent is ignored entirely', () {
          final bytes = withTrakDescendantSizeOverwritten(
            buildFmp4Init(videoFourCc: 'avc1', audioFourCc: 'mp4a'),
            trakIndex: 1,
            path: path,
            size: 999999,
          );

          final info = IsoBmffReader.parse(bytes);

          expect(info, isNotNull);
          expect(info!.hasVideo, isTrue);
          expect(info.videoCodec, 'avc1');
          expect(
            info.hasAudio,
            isFalse,
            reason: 'a half-read ${path.last} must not produce a confident audio track',
          );
          expect(info.audioCodec, isNull);
        });
      }

      test('a video trak whose tkhd overruns its parent contributes nothing, not bogus dimensions', () {
        final bytes = withTrakDescendantSizeOverwritten(
          buildFmp4Init(videoFourCc: 'avc1', audioFourCc: 'mp4a', width: 1920, height: 1080),
          trakIndex: 0,
          path: ['tkhd'],
          size: 999999,
        );

        final info = IsoBmffReader.parse(bytes);

        expect(info, isNotNull);
        expect(info!.hasAudio, isTrue, reason: 'the untouched audio trak still counts');
        expect(info.hasVideo, isFalse);
        expect(info.width, isNull);
        expect(info.height, isNull);
      });

      test('when the only trak has an incomplete stsd, parse returns null rather than a false-false result', () {
        final bytes = withTrakDescendantSizeOverwritten(
          buildFmp4Init(videoFourCc: 'avc1', audioFourCc: null),
          trakIndex: 0,
          path: ['mdia', 'minf', 'stbl', 'stsd'],
          size: 999999,
        );

        // Zero tracks we can vouch for is "unknown", never "confirmed no
        // video and no audio" - the latter is exactly what FormatSelector
        // would read as a genuinely silent, videoless source.
        expect(IsoBmffReader.parse(bytes), isNull);
      });
    });

    group('stsd sample entry parsed as a box (phase 6 round 4, S-R4-3, Codex #10)', () {
      test(
        'guard can fail: an audio trak whose first sample entry declares a size that overruns stsd '
        'still counts toward hasAudio, but its codec comes back null rather than a half-read fourcc',
        () {
          final bytes = withFirstSampleEntrySizeOverwritten(
            buildFmp4Init(videoFourCc: 'avc1', audioFourCc: 'mp4a'),
            trakIndex: 1, // the audio trak
            size: 999999,
          );

          final info = IsoBmffReader.parse(bytes);

          expect(info, isNotNull);
          expect(info!.hasVideo, isTrue);
          expect(info.videoCodec, 'avc1', reason: 'the untouched video trak is unaffected');
          expect(info.hasAudio, isTrue,
              reason: 'unlike an incomplete stsd box itself, a truncated sample entry inside an otherwise '
                  'complete stsd must not disqualify the whole track');
          // Guard-can-fail (manually verified, see report): reverting
          // `_findStsdFourCc` to read four bytes at the fixed content
          // offset 12 without checking the sample entry's own declared
          // size makes this assertion fail - it comes back 'mp4a' (the
          // real fourcc bytes are still technically readable at that
          // offset) instead of null, even though the sample entry's own
          // size field claims to run far past what stsd actually has.
          expect(info.audioCodec, isNull);
        },
      );

      test('a video trak whose first sample entry declares a size that overruns stsd keeps its dimensions', () {
        final bytes = withFirstSampleEntrySizeOverwritten(
          buildFmp4Init(videoFourCc: 'hvc1', audioFourCc: null, width: 1920, height: 1080),
          trakIndex: 0,
          size: 999999,
        );

        final info = IsoBmffReader.parse(bytes);

        expect(info, isNotNull);
        expect(info!.hasVideo, isTrue);
        expect(info.width, 1920);
        expect(info.height, 1080);
        expect(info.videoCodec, isNull, reason: 'the sample entry itself could not be confirmed complete');
      });

      test('a well-formed sample entry (unmodified fixture) still reports the correct fourcc', () {
        final bytes = buildFmp4Init(videoFourCc: 'av01', audioFourCc: 'ec-3');

        final info = IsoBmffReader.parse(bytes);

        expect(info?.videoCodec, 'av01');
        expect(info?.audioCodec, 'ec-3');
      });
    });
  });
}
