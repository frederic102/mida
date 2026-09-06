/// Synthetic ISO BMFF (fMP4/MP4) byte builders shared by
/// `iso_bmff_reader_test.dart` (pure box-tree parsing) and
/// `mp4_track_sniffer_test.dart` (network + parsing together). Built in
/// code with plain box writers rather than checked-in binary fixtures, per
/// the phase 6 order - every box is hand-assembled from the ISO/IEC
/// 14496-12 layout the parser itself follows, so a fixture and a parser
/// bug in the same direction cannot both hide each other.
library;

import 'dart:typed_data';

Uint8List _box(String type, List<int> content) {
  assert(type.length == 4);
  final size = 8 + content.length;
  final out = BytesBuilder();
  out.add(_u32(size));
  out.add(type.codeUnits);
  out.add(content);
  return out.toBytes();
}

List<int> _u32(int v) => [(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff];

/// `tkhd` content (full box): version(1)+flags(3), then a version-0
/// (32-bit) or version-1 (64-bit) creation/modification/track_ID/reserved/
/// duration block, 2x reserved(4), layer+alternate_group(4),
/// volume+reserved(4), a 3x3 matrix(36), then width/height as 16.16
/// fixed-point (integer part only set here).
List<int> tkhdContent({int version = 0, required int width, required int height}) {
  final idFieldSize = version == 1 ? 8 : 4;
  return [
    version, 0, 0, 0, // version + flags
    ...List.filled(idFieldSize, 0), // creation_time
    ...List.filled(idFieldSize, 0), // modification_time
    ...List.filled(4, 0), // track_ID
    ...List.filled(4, 0), // reserved
    ...List.filled(idFieldSize, 0), // duration
    ...List.filled(8, 0), // reserved x2
    ...List.filled(4, 0), // layer + alternate_group
    ...List.filled(4, 0), // volume + reserved
    ...List.filled(36, 0), // matrix
    ..._u32(width << 16),
    ..._u32(height << 16),
  ];
}

/// `hdlr` content: version/flags(4) + pre_defined(4) + 4-byte ASCII
/// handler_type (`vide`/`soun`) + reserved(12) + an empty (null-terminated)
/// name.
List<int> hdlrContent(String handlerType) {
  assert(handlerType.length == 4);
  return [
    0, 0, 0, 0, // version + flags
    0, 0, 0, 0, // pre_defined
    ...handlerType.codeUnits,
    ...List.filled(12, 0), // reserved
    0, // empty name
  ];
}

/// `stsd` content: version/flags(4) + entry_count(4, =1) + one sample
/// entry (size(4) + 4-byte ASCII format fourcc + minimal
/// reserved/data_reference_index padding).
List<int> stsdContent(String fourCc) {
  final sampleEntry = _box(fourCc, [
    ...List.filled(6, 0), // reserved
    0, 1, // data_reference_index = 1
  ]);
  return [
    0, 0, 0, 0, // version + flags
    0, 0, 0, 1, // entry_count = 1
    ...sampleEntry,
  ];
}

List<int> _ftypContent() => [
      ...'isom'.codeUnits, // major_brand
      0, 0, 0, 1, // minor_version
      ...'isom'.codeUnits, // one compatible brand
    ];

List<int> _trackContent({
  required String handlerType,
  required String fourCc,
  bool includeTkhd = true,
  int tkhdVersion = 0,
  int width = 0,
  int height = 0,
}) {
  final stsd = _box('stsd', stsdContent(fourCc));
  final stbl = _box('stbl', stsd);
  final minf = _box('minf', stbl);
  final hdlr = _box('hdlr', hdlrContent(handlerType));
  final mdia = _box('mdia', [...hdlr, ...minf]);
  final tkhd = includeTkhd ? _box('tkhd', tkhdContent(version: tkhdVersion, width: width, height: height)) : <int>[];
  return _box('trak', [...tkhd, ...mdia]);
}

/// A minimal fast-start fMP4/MP4 init segment: `ftyp` then `moov`
/// containing a video `trak` (when [videoFourCc] is non-null) and/or an
/// audio `trak` (when [audioFourCc] is non-null).
Uint8List buildFmp4Init({
  String? videoFourCc = 'avc1',
  String? audioFourCc = 'mp4a',
  int width = 1280,
  int height = 720,
  int tkhdVersion = 0,
}) {
  final traks = <int>[];
  if (videoFourCc != null) {
    traks.addAll(_trackContent(
      handlerType: 'vide',
      fourCc: videoFourCc,
      tkhdVersion: tkhdVersion,
      width: width,
      height: height,
    ));
  }
  if (audioFourCc != null) {
    traks.addAll(_trackContent(handlerType: 'soun', fourCc: audioFourCc, includeTkhd: false));
  }
  final moov = _box('moov', traks);
  final ftyp = _box('ftyp', _ftypContent());
  return Uint8List.fromList([...ftyp, ...moov]);
}

/// A `moof`-only fragment body (no `moov` anywhere): what a bare CMAF media
/// segment (no init segment in view) looks like.
Uint8List buildMoofOnlyFragment() {
  final ftyp = _box('ftyp', _ftypContent());
  final moof = _box('moof', [0, 0, 0, 0]);
  return Uint8List.fromList([...ftyp, ...moof]);
}

/// A non-fast-start file: `ftyp`, then a large `mdat` filler, then `moov`
/// at the very end - realistic shape for "moov did not fit in the leading
/// window we fetched".
Uint8List buildNonFastStartMp4({int mdatFillerBytes = 200000}) {
  final ftyp = _box('ftyp', _ftypContent());
  final mdat = _box('mdat', List.filled(mdatFillerBytes, 0));
  final moov = _box('moov', _trackContent(handlerType: 'vide', fourCc: 'avc1', width: 640, height: 360));
  return Uint8List.fromList([...ftyp, ...mdat, ...moov]);
}

/// A synthetic fMP4 whose total byte length deliberately straddles
/// `Mp4TrackSniffer`'s 64 KiB read-window boundary (phase 6 round 2,
/// S-R3/S-R5 test support): `ftyp`, then one `moov` containing a small
/// video `trak` near the front, a large inert `free` filler box (never
/// matched as a `trak`, just padding) that pushes the running byte count
/// well past 65536, then an audio `trak` entirely beyond that boundary.
/// `moov`'s own declared size covers all of it, including the trailing
/// audio trak - so a correctly windowed read (never buffering more than
/// 65536 bytes) sees moov's declared end overrun what it actually
/// received and must treat it as incomplete (`IsoBmffReader`'s S-R5 fix),
/// while a read that let a chunk overshoot the cap uncapped would find
/// the trailing audio trak and (incorrectly) report `hasAudio: true`.
Uint8List buildWindowBoundaryStraddlingFmp4() {
  final videoTrak = _trackContent(handlerType: 'vide', fourCc: 'avc1', width: 640, height: 360);
  final filler = _box('free', List.filled(66000, 0));
  final audioTrak = _trackContent(handlerType: 'soun', fourCc: 'mp4a', includeTkhd: false);
  final moov = _box('moov', [...videoTrak, ...filler, ...audioTrak]);
  final ftyp = _box('ftyp', _ftypContent());
  return Uint8List.fromList([...ftyp, ...moov]);
}

/// Minimal box-size-field walker for fixture *patching* only (not a
/// stand-in for `IsoBmffReader` - it only ever needs to locate a box this
/// same file already built correctly, never to parse arbitrary/malformed
/// input): finds [type]'s offset by reading each sibling box's 32-bit
/// size and skipping over it, starting at [start].
int _findBoxOffset(Uint8List bytes, String type, int start, int end) {
  var offset = start;
  while (offset + 8 <= end) {
    final size = ByteData.sublistView(bytes, offset, offset + 4).getUint32(0);
    final boxType = String.fromCharCodes(bytes, offset + 4, offset + 8);
    if (boxType == type) return offset;
    if (size <= 0) break;
    offset += size;
  }
  throw StateError('box "$type" not found in [$start, $end)');
}

/// Returns a copy of [bytes] (as produced by [buildFmp4Init]) with the
/// top-level `moov` box's own 32-bit size field overwritten to [size] -
/// fixture support for `IsoBmffReader`'s S-R5 "incomplete moov" tests
/// (`size: 0` is the ISO BMFF "runs to the end of what we have" case).
Uint8List withMoovSizeOverwritten(Uint8List bytes, int size) {
  final copy = Uint8List.fromList(bytes);
  final moovOffset = _findBoxOffset(copy, 'moov', 0, copy.length);
  copy.setRange(moovOffset, moovOffset + 4, _u32(size));
  return copy;
}

/// Returns a copy of [bytes] (as produced by [buildFmp4Init] with both a
/// video and an audio trak) with the *second* `trak` box's own size field
/// (the audio trak - [buildFmp4Init] always writes the video trak first)
/// overwritten to [size], leaving `moov`'s own declared size untouched -
/// fixture support for `IsoBmffReader`'s S-R5 "a trak whose own declared
/// size overruns its container" test.
Uint8List withSecondTrakSizeOverwritten(Uint8List bytes, int size) {
  final copy = Uint8List.fromList(bytes);
  final moovOffset = _findBoxOffset(copy, 'moov', 0, copy.length);
  final moovSize = ByteData.sublistView(copy, moovOffset, moovOffset + 4).getUint32(0);
  final moovContentStart = moovOffset + 8;
  final moovContentEnd = moovOffset + moovSize;

  final firstTrakOffset = _findBoxOffset(copy, 'trak', moovContentStart, moovContentEnd);
  final firstTrakSize = ByteData.sublistView(copy, firstTrakOffset, firstTrakOffset + 4).getUint32(0);
  final secondTrakOffset = _findBoxOffset(copy, 'trak', firstTrakOffset + firstTrakSize, moovContentEnd);

  copy.setRange(secondTrakOffset, secondTrakOffset + 4, _u32(size));
  return copy;
}

/// Returns a copy of [bytes] with the size field of one box *inside* a
/// `trak` overwritten to [size] - fixture support for `IsoBmffReader`'s
/// phase 6 round 3 (S-R3-2) completeness checks on the inner boxes
/// (`tkhd`/`mdia`/`hdlr`/`minf`/`stbl`/`stsd`), which round 2 read without
/// ever confirming they fit inside their own parent.
///
/// [trakIndex] selects which `trak` under `moov` (0 = the video trak,
/// which [buildFmp4Init] always writes first), and [path] is the chain of
/// box types to descend from that trak's content, e.g.
/// `['mdia', 'minf', 'stbl', 'stsd']`.
Uint8List withTrakDescendantSizeOverwritten(
  Uint8List bytes, {
  required int trakIndex,
  required List<String> path,
  required int size,
}) {
  assert(path.isNotEmpty);
  final copy = Uint8List.fromList(bytes);
  final moovOffset = _findBoxOffset(copy, 'moov', 0, copy.length);
  final moovSize = ByteData.sublistView(copy, moovOffset, moovOffset + 4).getUint32(0);
  var searchStart = moovOffset + 8;
  var searchEnd = moovOffset + moovSize;

  var trakOffset = _findBoxOffset(copy, 'trak', searchStart, searchEnd);
  for (var i = 0; i < trakIndex; i++) {
    final trakSize = ByteData.sublistView(copy, trakOffset, trakOffset + 4).getUint32(0);
    trakOffset = _findBoxOffset(copy, 'trak', trakOffset + trakSize, searchEnd);
  }
  final trakSize = ByteData.sublistView(copy, trakOffset, trakOffset + 4).getUint32(0);
  searchStart = trakOffset + 8;
  searchEnd = trakOffset + trakSize;

  var offset = 0;
  for (final type in path) {
    offset = _findBoxOffset(copy, type, searchStart, searchEnd);
    final boxSize = ByteData.sublistView(copy, offset, offset + 4).getUint32(0);
    searchStart = offset + 8;
    searchEnd = offset + boxSize;
  }
  copy.setRange(offset, offset + 4, _u32(size));
  return copy;
}

/// Returns a copy of [bytes] with the *first sample entry's own* size
/// field (inside the given trak's `stsd`) overwritten to [size], leaving
/// `stsd`'s own declared size untouched - fixture support for
/// `IsoBmffReader`'s phase 6 round 4 (S-R4-3) completeness check on the
/// sample entry itself: unlike overrunning `stsd` (which, via
/// [withTrakDescendantSizeOverwritten], disqualifies the whole track), a
/// sample entry that overruns only `stsd`'s own bounds must leave the
/// track's hasVideo/hasAudio alone and simply report an unknown codec.
Uint8List withFirstSampleEntrySizeOverwritten(
  Uint8List bytes, {
  required int trakIndex,
  required int size,
}) {
  final copy = Uint8List.fromList(bytes);
  final moovOffset = _findBoxOffset(copy, 'moov', 0, copy.length);
  final moovSize = ByteData.sublistView(copy, moovOffset, moovOffset + 4).getUint32(0);
  var trakOffset = _findBoxOffset(copy, 'trak', moovOffset + 8, moovOffset + moovSize);
  for (var i = 0; i < trakIndex; i++) {
    final trakSize = ByteData.sublistView(copy, trakOffset, trakOffset + 4).getUint32(0);
    trakOffset = _findBoxOffset(copy, 'trak', trakOffset + trakSize, moovOffset + moovSize);
  }
  final trakSize = ByteData.sublistView(copy, trakOffset, trakOffset + 4).getUint32(0);

  final mdiaOffset = _findBoxOffset(copy, 'mdia', trakOffset + 8, trakOffset + trakSize);
  final mdiaSize = ByteData.sublistView(copy, mdiaOffset, mdiaOffset + 4).getUint32(0);
  final minfOffset = _findBoxOffset(copy, 'minf', mdiaOffset + 8, mdiaOffset + mdiaSize);
  final minfSize = ByteData.sublistView(copy, minfOffset, minfOffset + 4).getUint32(0);
  final stblOffset = _findBoxOffset(copy, 'stbl', minfOffset + 8, minfOffset + minfSize);
  final stblSize = ByteData.sublistView(copy, stblOffset, stblOffset + 4).getUint32(0);
  final stsdOffset = _findBoxOffset(copy, 'stsd', stblOffset + 8, stblOffset + stblSize);

  // stsd content: version/flags(4) + entry_count(4) = 8 bytes, then the
  // first sample entry begins - its own 32-bit size field sits right there.
  final sampleEntryOffset = stsdOffset + 8 + 8;
  copy.setRange(sampleEntryOffset, sampleEntryOffset + 4, _u32(size));
  return copy;
}
