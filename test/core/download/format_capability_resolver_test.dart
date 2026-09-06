import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/download/format_capability_resolver.dart';
import 'package:mida/core/download/mp4_track_sniffer.dart';
import 'package:mida/core/extractors/media_models.dart';

/// Stand-in for the real network sniffer: `Mp4TrackSniffer` is a plain
/// (non-sealed) class, so extending it and overriding [sniff] lets these
/// tests exercise the resolver's selection/cap/concurrency/field-merge
/// logic with zero real network involved.
class _FakeSniffer extends Mp4TrackSniffer {
  final Map<String, Mp4TrackInfo?> responses;
  final Duration delay;
  final bool alwaysThrow;
  final List<String> urlsSniffed = [];
  int _current = 0;
  int maxObservedConcurrency = 0;

  _FakeSniffer(this.responses, {this.delay = Duration.zero, this.alwaysThrow = false}) : super();

  @override
  Future<Mp4TrackInfo?> sniff(
    Uri url,
    Map<String, String> headers, {
    Map<String, List<CookieEntry>>? cookiesByDomain,
  }) async {
    urlsSniffed.add(url.toString());
    _current++;
    if (_current > maxObservedConcurrency) maxObservedConcurrency = _current;
    if (delay > Duration.zero) await Future.delayed(delay);
    _current--;
    if (alwaysThrow) throw StateError('simulated sniffer failure');
    return responses[url.toString()];
  }
}

MediaFormat _unknownMp4(String id, {int? width, int? height, String? videoCodec}) => MediaFormat(
      id: id,
      url: 'https://example.invalid/$id.mp4',
      container: 'mp4',
      width: width,
      height: height,
      videoCodec: videoCodec,
      hasVideo: true,
      hasAudio: true,
      capabilitiesUnknown: true,
    );

MediaInfo _infoWith(List<MediaFormat> formats) => MediaInfo(
      id: 'v1',
      title: 'test video',
      author: 'someone',
      thumbnailUrl: 'https://example.invalid/thumb.jpg',
      duration: const Duration(seconds: 42),
      formats: formats,
      captions: const [CaptionTrack(languageCode: 'en', url: 'https://example.invalid/en.vtt')],
      translatableLanguageCodes: const ['fr', 'de'],
      sourceUrl: Uri.parse('https://example.invalid/watch'),
      requestHeaders: const {'User-Agent': 'mida-test'},
      cookiesByDomain: const {
        'example.invalid': [CookieEntry(domain: 'example.invalid', path: '/', secure: true, name: 'sid', value: 'x')],
      },
    );

void main() {
  group('FormatCapabilityResolver.resolve', () {
    test('a format not flagged capabilitiesUnknown is left completely untouched', () async {
      const known = MediaFormat(
        id: 'known',
        url: 'https://example.invalid/known.mp4',
        container: 'mp4',
        hasVideo: true,
        hasAudio: true,
      );
      final sniffer = _FakeSniffer({});
      final resolver = FormatCapabilityResolver(sniffer: sniffer);

      final result = await resolver.resolve(_infoWith([known]));

      expect(sniffer.urlsSniffed, isEmpty);
      expect(result.formats.single, same(known));
    });

    test('guard can fail: capabilitiesUnknown but wrong container (webm) is never sniffed', () async {
      const webm = MediaFormat(
        id: 'webm1',
        url: 'https://example.invalid/webm1.webm',
        container: 'webm',
        hasVideo: true,
        hasAudio: true,
        capabilitiesUnknown: true,
      );
      final sniffer = _FakeSniffer({'https://example.invalid/webm1.webm': const Mp4TrackInfo(hasVideo: true, hasAudio: false)});
      final resolver = FormatCapabilityResolver(sniffer: sniffer);

      final result = await resolver.resolve(_infoWith([webm]));

      expect(sniffer.urlsSniffed, isEmpty, reason: 'the container gate must exclude non-mp4/m4a containers');
      expect(result.formats.single.hasAudio, isTrue, reason: 'left untouched, not corrected to hasAudio:false');
    });

    test('guard can fail: capabilitiesUnknown mp4 but protocol hls (a manifest, not this sniffer\'s job) is never sniffed',
        () async {
      const mislabeled = MediaFormat(
        id: 'hls1',
        url: 'https://example.invalid/master.m3u8',
        container: 'mp4', // mislabeled container, but protocol says the truth
        protocol: 'hls',
        hasVideo: true,
        hasAudio: true,
        capabilitiesUnknown: true,
      );
      final sniffer = _FakeSniffer({});
      final resolver = FormatCapabilityResolver(sniffer: sniffer);

      await resolver.resolve(_infoWith([mislabeled]));

      expect(sniffer.urlsSniffed, isEmpty);
    });

    test('m4a is accepted, not just mp4', () async {
      const format = MediaFormat(
        id: 'audio1',
        url: 'https://example.invalid/audio1.m4a',
        container: 'm4a',
        hasVideo: true,
        hasAudio: true,
        capabilitiesUnknown: true,
      );
      final sniffer = _FakeSniffer({
        'https://example.invalid/audio1.m4a': const Mp4TrackInfo(hasVideo: false, hasAudio: true, audioCodec: 'mp4a'),
      });
      final resolver = FormatCapabilityResolver(sniffer: sniffer);

      final result = await resolver.resolve(_infoWith([format]));

      expect(result.formats.single.hasVideo, isFalse);
      expect(result.formats.single.hasAudio, isTrue);
      expect(result.formats.single.capabilitiesUnknown, isFalse);
    });

    test('a successful sniff corrects hasVideo/hasAudio/dims/codec and clears capabilitiesUnknown', () async {
      final format = _unknownMp4('a');
      final sniffer = _FakeSniffer({
        'https://example.invalid/a.mp4': const Mp4TrackInfo(
          hasVideo: false,
          hasAudio: true,
          audioCodec: 'mp4a',
        ),
      });
      final resolver = FormatCapabilityResolver(sniffer: sniffer);

      final result = await resolver.resolve(_infoWith([format]));
      final corrected = result.formats.single;

      expect(corrected.hasVideo, isFalse);
      expect(corrected.hasAudio, isTrue);
      expect(corrected.audioCodec, 'mp4a');
      expect(corrected.capabilitiesUnknown, isFalse);
    });

    test(
      'a sniff result missing dims/codec (copyWith null-preserving semantics) does not clobber an already-known '
      'non-null value with null',
      () async {
        // The original already carries a (hypothetical) non-null width/
        // height/videoCodec despite being flagged capabilitiesUnknown; the
        // sniffer only managed to confirm hasVideo/hasAudio this time, not
        // read the dims. copyWith's null-coalescing must mean those three
        // survive untouched rather than being wiped to null.
        final format = _unknownMp4('b', width: 999, height: 888, videoCodec: 'avc1');
        final sniffer = _FakeSniffer({
          'https://example.invalid/b.mp4': const Mp4TrackInfo(hasVideo: true, hasAudio: false),
        });
        final resolver = FormatCapabilityResolver(sniffer: sniffer);

        final result = await resolver.resolve(_infoWith([format]));
        final corrected = result.formats.single;

        expect(corrected.hasVideo, isTrue);
        expect(corrected.hasAudio, isFalse);
        expect(corrected.width, 999, reason: 'a null sniff field must not clobber the pre-existing value');
        expect(corrected.height, 888);
        expect(corrected.videoCodec, 'avc1');
      },
    );

    test('a format the sniffer could not read (returns null) is left completely untouched', () async {
      final format = _unknownMp4('c');
      final sniffer = _FakeSniffer({'https://example.invalid/c.mp4': null});
      final resolver = FormatCapabilityResolver(sniffer: sniffer);

      final result = await resolver.resolve(_infoWith([format]));

      expect(result.formats.single, same(format));
    });

    test('a sniffer that throws for one format does not fail resolve() as a whole', () async {
      final formats = [_unknownMp4('d'), _unknownMp4('e')];
      final sniffer = _FakeSniffer(
        {'https://example.invalid/e.mp4': const Mp4TrackInfo(hasVideo: false, hasAudio: true)},
        alwaysThrow: true,
      );
      final resolver = FormatCapabilityResolver(sniffer: sniffer);

      // alwaysThrow makes every call throw regardless of the map, so both
      // are expected to be left untouched - this is really testing that a
      // thrown exception from the sniffer does not propagate out of
      // resolve() or abort the rest of the pool.
      final result = await resolver.resolve(_infoWith(formats));

      expect(result.formats[0].capabilitiesUnknown, isTrue);
      expect(result.formats[1].capabilitiesUnknown, isTrue);
    });

    test(
      'a slow sniff is waited out, never abandoned by a resolver-side timeout (round 3, S-R3-4, Codex #12)',
      () async {
        final format = _unknownMp4('slow');
        final sniffer = _FakeSniffer(
          {'https://example.invalid/slow.mp4': const Mp4TrackInfo(hasVideo: false, hasAudio: true)},
          delay: const Duration(milliseconds: 120),
        );
        final resolver = FormatCapabilityResolver(sniffer: sniffer);

        final result = await resolver.resolve(_infoWith([format]));

        // Round 2's external `.timeout()` would have given up here and
        // left this uncorrected. The only deadline now is
        // `Mp4TrackSniffer.timeout` inside `sniff`, which owns (and
        // force-closes) the connection it bounds.
        expect(result.formats.single.capabilitiesUnknown, isFalse);
        expect(result.formats.single.hasVideo, isFalse);
        expect(result.formats.single.hasAudio, isTrue);
      },
    );

    test(
      'a worker never starts its next sniff until the previous one has returned (round 3, S-R3-4)',
      () async {
        final formats = List.generate(3, (i) => _unknownMp4('s$i'));
        final sniffer = _FakeSniffer(
          {for (final f in formats) f.url: const Mp4TrackInfo(hasVideo: true, hasAudio: false)},
          delay: const Duration(milliseconds: 40),
        );
        final resolver = FormatCapabilityResolver(sniffer: sniffer, concurrency: 1, maxSniffs: 3);

        final result = await resolver.resolve(_infoWith(formats));

        // An external `.timeout()` shorter than the delay was the only
        // way a single worker could overlap two sniffs; there is none now.
        expect(sniffer.maxObservedConcurrency, 1);
        expect(sniffer.urlsSniffed, hasLength(3));
        for (final format in result.formats) {
          expect(format.capabilitiesUnknown, isFalse);
        }
      },
    );

    test('guard can fail: caps at maxSniffs even when more candidates are eligible', () async {
      final formats = List.generate(5, (i) => _unknownMp4('m$i'));
      final sniffer = _FakeSniffer({
        for (final f in formats) f.url: const Mp4TrackInfo(hasVideo: false, hasAudio: true),
      });
      final resolver = FormatCapabilityResolver(sniffer: sniffer, maxSniffs: 3);

      final result = await resolver.resolve(_infoWith(formats));

      expect(sniffer.urlsSniffed.length, 3, reason: 'must not sniff more than maxSniffs candidates');
      // First 3 corrected, last 2 left exactly as they were (still flagged
      // unknown) - proves the cap picks a prefix, not "give up entirely".
      expect(result.formats[0].capabilitiesUnknown, isFalse);
      expect(result.formats[1].capabilitiesUnknown, isFalse);
      expect(result.formats[2].capabilitiesUnknown, isFalse);
      expect(result.formats[3].capabilitiesUnknown, isTrue);
      expect(result.formats[4].capabilitiesUnknown, isTrue);
    });

    test('guard can fail: never runs more than concurrency sniffs in flight at once', () async {
      final formats = List.generate(6, (i) => _unknownMp4('c$i'));
      final sniffer = _FakeSniffer(
        {for (final f in formats) f.url: const Mp4TrackInfo(hasVideo: false, hasAudio: true)},
        delay: const Duration(milliseconds: 20),
      );
      final resolver = FormatCapabilityResolver(sniffer: sniffer, concurrency: 2, maxSniffs: 6);

      await resolver.resolve(_infoWith(formats));

      expect(sniffer.maxObservedConcurrency, lessThanOrEqualTo(2));
    });

    test(
      'guard can fail: concurrency actually parallelizes (not silently serial) - observed concurrency '
      'exceeds 1 with a concurrency of 3',
      () async {
        final formats = List.generate(6, (i) => _unknownMp4('p$i'));
        final sniffer = _FakeSniffer(
          {for (final f in formats) f.url: const Mp4TrackInfo(hasVideo: false, hasAudio: true)},
          delay: const Duration(milliseconds: 20),
        );
        final resolver = FormatCapabilityResolver(sniffer: sniffer, concurrency: 3, maxSniffs: 6);

        await resolver.resolve(_infoWith(formats));

        expect(sniffer.maxObservedConcurrency, greaterThan(1));
        expect(sniffer.maxObservedConcurrency, lessThanOrEqualTo(3));
      },
    );

    test('a concurrency of exactly 1 sniffs strictly one at a time', () async {
      final formats = List.generate(4, (i) => _unknownMp4('s$i'));
      final sniffer = _FakeSniffer(
        {for (final f in formats) f.url: const Mp4TrackInfo(hasVideo: false, hasAudio: true)},
        delay: const Duration(milliseconds: 10),
      );
      final resolver = FormatCapabilityResolver(sniffer: sniffer, concurrency: 1, maxSniffs: 4);

      await resolver.resolve(_infoWith(formats));

      expect(sniffer.maxObservedConcurrency, 1);
    });

    test('every MediaInfo field besides formats survives the round trip (cookiesByDomain included)', () async {
      final format = _unknownMp4('f');
      final sniffer = _FakeSniffer({
        'https://example.invalid/f.mp4': const Mp4TrackInfo(hasVideo: false, hasAudio: true),
      });
      final resolver = FormatCapabilityResolver(sniffer: sniffer);
      final original = _infoWith([format]);

      final result = await resolver.resolve(original);

      expect(result.id, original.id);
      expect(result.title, original.title);
      expect(result.author, original.author);
      expect(result.thumbnailUrl, original.thumbnailUrl);
      expect(result.duration, original.duration);
      expect(result.captions, original.captions);
      expect(result.translatableLanguageCodes, original.translatableLanguageCodes);
      expect(result.sourceUrl, original.sourceUrl);
      expect(result.requestHeaders, original.requestHeaders);
      expect(result.cookiesByDomain, original.cookiesByDomain);
    });

    test('a MediaInfo with no eligible formats at all returns unchanged (no sniffing attempted)', () async {
      final muxed = MediaFormat(
        id: 'muxed',
        url: 'https://example.invalid/muxed.mp4',
        container: 'mp4',
        hasVideo: true,
        hasAudio: true,
      );
      final sniffer = _FakeSniffer({});
      final resolver = FormatCapabilityResolver(sniffer: sniffer);
      final original = _infoWith([muxed]);

      final result = await resolver.resolve(original);

      expect(sniffer.urlsSniffed, isEmpty);
      expect(result.formats, original.formats);
    });

    test(
      'guard can fail: capabilitiesUnknown mp4 with protocol "https" but a plain-http URL '
      '(disagreeing metadata) is never sniffed (S-R4)',
      () async {
        const mislabeled = MediaFormat(
          id: 'http1',
          url: 'http://example.invalid/a.mp4', // scheme disagrees with the declared protocol label below
          container: 'mp4',
          protocol: 'https',
          hasVideo: true,
          hasAudio: true,
          capabilitiesUnknown: true,
        );
        final sniffer = _FakeSniffer({'http://example.invalid/a.mp4': const Mp4TrackInfo(hasVideo: true, hasAudio: false)});
        final resolver = FormatCapabilityResolver(sniffer: sniffer);

        final result = await resolver.resolve(_infoWith([mislabeled]));

        expect(sniffer.urlsSniffed, isEmpty, reason: 'the URL\'s own scheme, not just the protocol label, must be https');
        expect(result.formats.single.hasAudio, isTrue, reason: 'left untouched, not corrected');
      },
    );

    test('a malformed format URL is skipped rather than throwing', () async {
      final malformed = MediaFormat(
        id: 'bad',
        url: 'https://example.invalid/%zz', // invalid percent-encoding: Uri.parse throws FormatException
        container: 'mp4',
        hasVideo: true,
        hasAudio: true,
        capabilitiesUnknown: true,
      );
      final sniffer = _FakeSniffer({});
      final resolver = FormatCapabilityResolver(sniffer: sniffer);

      await expectLater(resolver.resolve(_infoWith([malformed])), completes);
    });
  });
}
