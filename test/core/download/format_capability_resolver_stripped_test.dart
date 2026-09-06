import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/download/format_capability_resolver.dart';
import 'package:mida/core/download/mp4_track_sniffer.dart';
import 'package:mida/core/extractors/media_models.dart';

/// Phase 6 round 3, Codex cross-review #2 (blocker): when the sniffer proves
/// that a format which CLAIMED audio has none, the resolver must mark it
/// [MediaFormat.audioWasStripped] so `FormatSelector`'s silent-source tier
/// refuses it. Without the marker the corrected format looked exactly like
/// an honestly muted source and a silent file shipped as a success without
/// ever reaching the pipeline's own mismatch correction. Split out of
/// `format_capability_resolver_test.dart` only because that file sits at
/// the 400-line cap.
class _FixedSniffer extends Mp4TrackSniffer {
  final Map<String, Mp4TrackInfo?> responses;

  _FixedSniffer(this.responses) : super();

  @override
  Future<Mp4TrackInfo?> sniff(
    Uri url,
    Map<String, String> headers, {
    Map<String, List<CookieEntry>>? cookiesByDomain,
  }) async =>
      responses[url.toString()];
}

MediaFormat _claimsMuxed(String id) => MediaFormat(
      id: id,
      url: 'https://example.invalid/$id.mp4',
      container: 'mp4',
      hasVideo: true,
      hasAudio: true,
      capabilitiesUnknown: true,
    );

MediaInfo _infoWith(List<MediaFormat> formats) => MediaInfo(
      id: 'v1',
      title: 'test video',
      formats: formats,
      sourceUrl: Uri.parse('https://example.invalid/watch'),
    );

void main() {
  test('guard can fail: a format that claimed audio and is sniffed video-only is marked audioWasStripped', () async {
    final resolver = FormatCapabilityResolver(
      sniffer: _FixedSniffer({
        'https://example.invalid/a.mp4': const Mp4TrackInfo(hasVideo: true, hasAudio: false, videoCodec: 'avc1'),
      }),
    );

    final result = await resolver.resolve(_infoWith([_claimsMuxed('a')]));
    final corrected = result.formats.single;

    expect(corrected.hasAudio, isFalse);
    expect(corrected.audioWasStripped, isTrue,
        reason: 'guard can fail: without the marker the silent-source tier accepts this as an honestly muted '
            'source and the verifier signs off on a silent file');
  });

  test('a format the sniffer confirms as muxed is not marked stripped', () async {
    final resolver = FormatCapabilityResolver(
      sniffer: _FixedSniffer({
        'https://example.invalid/b.mp4': const Mp4TrackInfo(hasVideo: true, hasAudio: true),
      }),
    );

    final result = await resolver.resolve(_infoWith([_claimsMuxed('b')]));

    expect(result.formats.single.hasAudio, isTrue);
    expect(result.formats.single.audioWasStripped, isFalse);
  });

  test('a format that never claimed audio and is sniffed audio-less stays an honest silent source', () async {
    final honestlySilent = _claimsMuxed('c').copyWith(hasAudio: false);
    final resolver = FormatCapabilityResolver(
      sniffer: _FixedSniffer({
        'https://example.invalid/c.mp4': const Mp4TrackInfo(hasVideo: true, hasAudio: false),
      }),
    );

    final result = await resolver.resolve(_infoWith([honestlySilent]));

    expect(result.formats.single.audioWasStripped, isFalse,
        reason: 'only a claim that turned out false is stripping; a source that said "no audio" up front is '
            'exactly the case the silent-source tier exists for');
  });

  test('an already-stripped marker survives a sniff that agrees there is no audio', () async {
    final stripped = _claimsMuxed('d').copyWith(hasAudio: false, audioWasStripped: true);
    final resolver = FormatCapabilityResolver(
      sniffer: _FixedSniffer({
        'https://example.invalid/d.mp4': const Mp4TrackInfo(hasVideo: true, hasAudio: false),
      }),
    );

    final result = await resolver.resolve(_infoWith([stripped]));

    expect(result.formats.single.audioWasStripped, isTrue);
  });
}
