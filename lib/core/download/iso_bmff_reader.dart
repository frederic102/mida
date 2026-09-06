import 'dart:typed_data';

/// Pure ISO BMFF (MP4/QuickTime box format) reader, split out of
/// `Mp4TrackSniffer` purely to keep that file (network I/O) under the
/// project's 400-line cap and to make the box-tree parsing itself directly
/// unit-testable against synthetic byte fixtures, no network involved.
///
/// Only ever walks `moov > trak > {tkhd, mdia > {hdlr, minf > stbl > stsd}}`
/// - the minimum needed to answer "does this MP4 have a video/audio track,
/// what size, what codec". Never throws: every bounds/format problem is
/// treated as "this piece is missing" rather than an error, and [parse]
/// itself is wrapped in a catch-all as a last line of defense.
class IsoBmffTrackData {
  final bool hasVideo;
  final bool hasAudio;
  final int? width;
  final int? height;
  final String? videoCodec;
  final String? audioCodec;

  const IsoBmffTrackData({
    required this.hasVideo,
    required this.hasAudio,
    this.width,
    this.height,
    this.videoCodec,
    this.audioCodec,
  });
}

/// One box's type and the byte range of its *content* (i.e. everything
/// after the 8-byte, or 16-byte with a 64-bit largesize, box header).
///
/// [complete] is false (phase 6 round 2, S-R5) when this box's true end
/// could not be confirmed from the bytes we actually have: either its
/// declared size runs past the end of the region we were scanning (`bytes`
/// is a leading network window, not necessarily the whole file - a
/// `moov`/`trak` that says it is bigger than what we got back is exactly
/// the shape a truncated fetch produces), or its size field was the
/// literal `0` ("this box's content runs to the end of what we have"),
/// which for a *possibly-partial* window is never distinguishable from
/// "we simply do not know how much more content there is meant to be".
class _Box {
  final String type;
  final int contentStart;
  final int contentEnd;
  final bool complete;

  const _Box(this.type, this.contentStart, this.contentEnd, {required this.complete});
}

/// Raised internally (never escapes [IsoBmffReader.parse]) when a box on
/// the path being walked is present but not [_Box.complete] - see
/// [IsoBmffReader._require].
class _IncompleteBoxException implements Exception {
  const _IncompleteBoxException();
}

class IsoBmffReader {
  const IsoBmffReader._();

  /// Parses [bytes] (a leading window of an MP4/fMP4 file, not necessarily
  /// the whole file) looking for `moov`. Returns null when no `moov` box is
  /// found anywhere in [bytes] - either because the window ended before
  /// `moov` (a non-fast-start file whose `moov` sits after `mdat`), or
  /// because [bytes] is a `moof`-only fragment body with no init segment in
  /// view at all. When `moov` is present, aggregates every `trak` inside it
  /// into one combined result (hasVideo/hasAudio true if *any* track's
  /// `hdlr` says so; width/height/codec taken from the first track of each
  /// kind that has them).
  static IsoBmffTrackData? parse(Uint8List bytes) {
    try {
      final topBoxes = _readBoxes(bytes, 0, bytes.length);
      final moov = _find(topBoxes, 'moov');
      if (moov == null) return null;
      // An incomplete moov (S-R5) means the trak list we would read out of
      // it cannot be trusted at all - its own declared bounds do not match
      // what we actually have, so there is no honest way to tell "this
      // moov genuinely has no audio trak" apart from "the audio trak's
      // bytes were simply cut off by the fetch window". Bail out to null
      // rather than derive anything from it.
      if (!moov.complete) return null;

      final traks = _findAll(_readBoxes(bytes, moov.contentStart, moov.contentEnd), 'trak');

      var hasVideo = false;
      var hasAudio = false;
      int? width;
      int? height;
      String? videoCodec;
      String? audioCodec;

      for (final trak in traks) {
        // Same reasoning as the moov check above, one level down (S-R5):
        // a trak whose own declared size overran the bytes we have cannot
        // be trusted to tell us it has (or lacks) a given handler type -
        // skip it rather than let a truncated trak masquerade as "no
        // video/audio trak here at all".
        if (!trak.complete) continue;
        try {
          // Phase 6 round 3 (S-R3-2, Codex #6): every box on the path we
          // actually walk gets the same completeness check `moov`/`trak`
          // already had, and any incomplete one disqualifies the whole
          // track (via [_IncompleteBoxException] below), not just the one
          // field it would have fed. Round 2 checked only the outer two
          // levels, so a `mdia`/`hdlr`/`minf`/`stbl`/`stsd`/`tkhd` whose
          // declared size ran past the fetch window was read as if its
          // clamped, partial content were the real thing - which is how a
          // truncated window could still yield a confident
          // "hasAudio: false" or a wrong codec fourcc. Nothing is
          // committed to the aggregate until the whole track parsed
          // cleanly.
          final trakChildren = _readBoxes(bytes, trak.contentStart, trak.contentEnd);
          final mdia = _require(_find(trakChildren, 'mdia'));
          if (mdia == null) continue;

          final mdiaChildren = _readBoxes(bytes, mdia.contentStart, mdia.contentEnd);
          final hdlr = _require(_find(mdiaChildren, 'hdlr'));
          if (hdlr == null) continue;
          final handlerType = _readHandlerType(bytes, hdlr);
          if (handlerType != 'vide' && handlerType != 'soun') continue;

          final minf = _require(_find(mdiaChildren, 'minf'));
          final codec = _findStsdFourCc(bytes, minf);

          if (handlerType == 'vide') {
            final tkhd = _require(_find(trakChildren, 'tkhd'));
            final dims = tkhd == null ? null : _readTkhdDims(bytes, tkhd);
            hasVideo = true;
            width ??= dims?.$1;
            height ??= dims?.$2;
            videoCodec ??= codec;
          } else {
            hasAudio = true;
            audioCodec ??= codec;
          }
        } on _IncompleteBoxException {
          // A box on this track's path could not be confirmed complete
          // inside the window we have - the honest answer for this track
          // is "unknown", so it contributes nothing at all rather than a
          // half-read guess. Other tracks are unaffected.
          continue;
        } catch (_) {
          // One malformed track must not throw away what earlier tracks
          // already found; skip just this one.
          continue;
        }
      }

      // No trak contributed anything at all (S-R5): either moov genuinely
      // has no traks, or every trak we saw was incomplete/unrecognized.
      // Either way this is "we found nothing we can vouch for", not "we
      // confirmed there is neither a video nor an audio track" - the two
      // read identically as a plain false/false result, and the latter is
      // exactly the shape `FormatSelector` would otherwise treat as a
      // confirmed silent/videoless file. Returning null here instead lets
      // the caller (`Mp4TrackSniffer`) treat this the same as any other
      // "could not sniff this one" outcome.
      if (!hasVideo && !hasAudio) return null;

      return IsoBmffTrackData(
        hasVideo: hasVideo,
        hasAudio: hasAudio,
        width: width,
        height: height,
        videoCodec: videoCodec,
        audioCodec: audioCodec,
      );
    } catch (_) {
      return null;
    }
  }

  /// Walks sibling boxes in `[start, end)`, handling both the normal
  /// 32-bit size and the `size == 1` 64-bit largesize extension, and
  /// treating `size == 0` as "extends to the end of the data we have"
  /// (there is no true end-of-file visible in a partial window, so the end
  /// of what we were given is the closest honest answer). Never throws:
  /// any box whose declared header does not fit in the remaining bytes
  /// ends the walk rather than reading out of bounds, and a box that
  /// claims to extend past [end] is clamped to [end].
  static List<_Box> _readBoxes(Uint8List bytes, int start, int end) {
    final boxes = <_Box>[];
    var offset = start;

    while (offset + 8 <= end) {
      final size32 = _readUint32(bytes, offset);
      if (size32 == null) break;
      final type = _readFourCc(bytes, offset + 4);
      if (type == null) break;

      var headerSize = 8;
      int boxSize;
      if (size32 == 1) {
        final largesize = _readUint64(bytes, offset + 8);
        if (largesize == null) break; // not enough bytes for the 64-bit size field
        boxSize = largesize;
        headerSize = 16;
      } else if (size32 == 0) {
        boxSize = end - offset;
      } else {
        boxSize = size32;
      }

      if (boxSize < headerSize) break; // corrupt/unreasonable, stop rather than misread
      final contentStart = offset + headerSize;
      if (contentStart > end) break;
      final rawContentEnd = offset + boxSize;
      final contentEnd = rawContentEnd > end ? end : rawContentEnd;
      // S-R5: `size == 0` is always ambiguous ("runs to the end of what
      // we have") - never treated as a confirmed true end, since the only
      // real caller of this reader (`Mp4TrackSniffer`) always hands it a
      // leading network window, not a whole file. Otherwise, complete
      // exactly when the box's own declared size actually fit inside
      // [end] (a lying/truncated size does not).
      final complete = size32 != 0 && rawContentEnd <= end;

      boxes.add(_Box(type, contentStart, contentEnd, complete: complete));

      if (boxSize <= 0) break; // guard against a zero/negative-size infinite loop
      offset += boxSize;
    }

    return boxes;
  }

  /// Passes [box] through unchanged when it is absent (nothing to vouch
  /// for either way - the caller decides what a missing box means) or
  /// confirmed complete, and throws [_IncompleteBoxException] when it is
  /// present but its true end could not be confirmed inside the window
  /// (phase 6 round 3, S-R3-2).
  static _Box? _require(_Box? box) {
    if (box == null) return null;
    if (!box.complete) throw const _IncompleteBoxException();
    return box;
  }

  static _Box? _find(List<_Box> boxes, String type) {
    for (final box in boxes) {
      if (box.type == type) return box;
    }
    return null;
  }

  static List<_Box> _findAll(List<_Box> boxes, String type) => boxes.where((b) => b.type == type).toList();

  /// `hdlr` (fullbox): version/flags (4 bytes) + pre_defined (4 bytes),
  /// then the 4-byte ASCII handler_type (`vide`/`soun`/...) at content
  /// offset 8.
  static String? _readHandlerType(Uint8List bytes, _Box hdlr) {
    const offset = 8;
    if (hdlr.contentStart + offset + 4 > hdlr.contentEnd) return null;
    return _readFourCc(bytes, hdlr.contentStart + offset);
  }

  /// `tkhd` (fullbox): version (1 byte) at content offset 0 selects the
  /// layout. Version 0 packs a 20-byte creation/modification/track_ID/
  /// reserved/duration block (32-bit fields); version 1 packs the same
  /// fields as 64-bit (32 bytes), pushing width/height 12 bytes later.
  /// Width/height are each a 32-bit 16.16 fixed-point value; only the
  /// integer (high 16 bits) is returned.
  static (int, int)? _readTkhdDims(Uint8List bytes, _Box tkhd) {
    if (tkhd.contentEnd <= tkhd.contentStart) return null;
    final version = bytes[tkhd.contentStart];
    final widthOffset = version == 1 ? 88 : 76;
    final heightOffset = version == 1 ? 92 : 80;

    final width = _readUint32(bytes, tkhd.contentStart + widthOffset, end: tkhd.contentEnd);
    final height = _readUint32(bytes, tkhd.contentStart + heightOffset, end: tkhd.contentEnd);
    if (width == null || height == null) return null;
    return (width >> 16, height >> 16);
  }

  /// `stsd` (fullbox): version/flags (4 bytes) + entry_count (4 bytes),
  /// then the first sample entry. Throws [_IncompleteBoxException]
  /// (S-R3-2) when `stbl`/`stsd` itself is present but its declared size
  /// overran the window - a clamped `stsd` can still expose readable bytes
  /// that are simply not the real sample-entry content.
  ///
  /// The sample entry itself is box-shaped (size (4 bytes) + a 4-byte
  /// ASCII format fourcc, e.g. `avc1`/`hvc1`/`mp4a`) starting at stsd
  /// content offset 8, so phase 6 round 4 (S-R4-3, Codex #10) parses it
  /// with the same [_readBoxes] walker as every other box rather than
  /// reading four bytes at a fixed offset - a sample entry whose declared
  /// size runs past `stsd`'s own (already-confirmed-complete) bounds must
  /// not be trusted for its fourcc either, even though that fourcc sits at
  /// an offset that might still be technically readable: a truncated fetch
  /// is not required to cut cleanly on a box boundary. Unlike an
  /// incomplete `stsd` itself, an incomplete sample entry does not
  /// disqualify the whole track (S-R3-2's [_require]/throw) - it only
  /// means this one track's codec could not be confirmed, so this returns
  /// null rather than throwing.
  static String? _findStsdFourCc(Uint8List bytes, _Box? minf) {
    if (minf == null) return null;
    final stbl = _require(_find(_readBoxes(bytes, minf.contentStart, minf.contentEnd), 'stbl'));
    if (stbl == null) return null;
    final stsd = _require(_find(_readBoxes(bytes, stbl.contentStart, stbl.contentEnd), 'stsd'));
    if (stsd == null) return null;

    const entriesOffset = 8;
    if (stsd.contentStart + entriesOffset > stsd.contentEnd) return null;
    final entries = _readBoxes(bytes, stsd.contentStart + entriesOffset, stsd.contentEnd);
    if (entries.isEmpty) return null;
    final firstEntry = entries.first;
    if (!firstEntry.complete) return null;
    return firstEntry.type;
  }

  /// Big-endian uint32 at [offset], bounds-checked against [end] (defaults
  /// to [bytes]'s own length) rather than relying on a thrown `RangeError` -
  /// this is the guard a disabled/removed check would turn into a crash
  /// instead of a clean null (see the sniffer test's guard-can-fail note).
  static int? _readUint32(Uint8List bytes, int offset, {int? end}) {
    final limit = end ?? bytes.length;
    if (offset < 0 || offset + 4 > limit) return null;
    return ByteData.sublistView(bytes, offset, offset + 4).getUint32(0);
  }

  /// Big-endian uint64 (used only for the rare 64-bit box largesize).
  static int? _readUint64(Uint8List bytes, int offset, {int? end}) {
    final limit = end ?? bytes.length;
    if (offset < 0 || offset + 8 > limit) return null;
    return ByteData.sublistView(bytes, offset, offset + 8).getUint64(0);
  }

  static String? _readFourCc(Uint8List bytes, int offset, {int? end}) {
    final limit = end ?? bytes.length;
    if (offset < 0 || offset + 4 > limit) return null;
    return String.fromCharCodes(bytes, offset, offset + 4);
  }
}
