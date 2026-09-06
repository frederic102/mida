import '../extractors/media_models.dart';
import 'mp4_track_sniffer.dart';

/// Contract stub (phase 6, lead-owned signature; Lane S owns the body).
/// Runs before `FormatSelector.rank`: for every format flagged
/// [MediaFormat.capabilitiesUnknown] whose container is `mp4`/`m4a` and
/// protocol `https`, asks [Mp4TrackSniffer] what the file really holds and
/// returns a [MediaInfo] whose formats carry the corrected
/// `hasVideo`/`hasAudio`/`width`/`height`/`videoCodec`/`audioCodec`
/// (and `capabilitiesUnknown: false`). Formats the sniffer could not read
/// are returned untouched. Bounded: at most [maxSniffs] formats per call and [concurrency] in
/// flight; the per-sniff deadline is [Mp4TrackSniffer.timeout], enforced
/// inside `sniff` itself (phase 6 round 3, S-R3-4, Codex #12 - this class
/// deliberately has no `.timeout()` of its own any more, see [resolve]).
/// Never throws.
class FormatCapabilityResolver {
  final Mp4TrackSniffer sniffer;
  final int maxSniffs;
  final int concurrency;

  const FormatCapabilityResolver({
    this.sniffer = const Mp4TrackSniffer(),
    this.maxSniffs = 8,
    this.concurrency = 3,
  });

  /// Selector: [MediaFormat.capabilitiesUnknown] and a container the
  /// sniffer actually understands (`mp4`/`m4a`) and a protocol it can
  /// reach with a plain ranged GET (`https`) - an HLS/DASH manifest
  /// mislabeled this way is `FormatExpander`'s problem, not this one's.
  /// Phase 6 round 2 (S-R4): also re-parses [MediaFormat.url] itself and
  /// requires its own scheme to be `https`, not just the declared
  /// [MediaFormat.protocol] label - the label is metadata an extractor
  /// derived and could disagree with the URL it is actually attached to;
  /// trusting the label alone here would let a plain-http URL be handed
  /// to [Mp4TrackSniffer], which sends caller headers/cookies over it
  /// unencrypted.
  bool _eligible(MediaFormat format) {
    if (!format.capabilitiesUnknown) return false;
    if (format.container != 'mp4' && format.container != 'm4a') return false;
    if (format.protocol != 'https') return false;
    final uri = Uri.tryParse(format.url);
    return uri != null && uri.scheme.toLowerCase() == 'https';
  }

  /// Phase 6 round 3 (S-R3-4, Codex #12): each worker loop only advances
  /// to its next candidate once [Mp4TrackSniffer.sniff] has actually
  /// returned - meaning after `sniff` finished closing its own client. An
  /// external `.timeout()` here (what round 2 had) does not do that: it
  /// abandons *waiting* on the future while the real socket that sniff
  /// opened stays open, so the worker starts a second connection while
  /// the first is still live and the real number of open connections
  /// climbs past [concurrency] exactly when the cap matters most (a slow
  /// or non-responding server). The deadline now lives in exactly one
  /// place, [Mp4TrackSniffer.timeout], which force-closes the client it
  /// owns before completing - so "sniff returned" and "that connection is
  /// gone" are the same instant, and the loop below can trust it.
  Future<MediaInfo> resolve(MediaInfo info) async {
    try {
      final candidateIndexes = <int>[];
      for (var i = 0; i < info.formats.length && candidateIndexes.length < maxSniffs; i++) {
        if (_eligible(info.formats[i])) candidateIndexes.add(i);
      }
      if (candidateIndexes.isEmpty) return info;

      final corrected = <int, MediaFormat>{};
      var next = 0;

      Future<void> worker() async {
        while (true) {
          if (next >= candidateIndexes.length) return;
          final index = candidateIndexes[next];
          next++;

          final format = info.formats[index];
          try {
            Uri uri;
            try {
              uri = Uri.parse(format.url);
            } catch (_) {
              continue; // not a fetchable URL at all; leave this format untouched
            }
            final sniffed = await sniffer.sniff(uri, info.requestHeaders, cookiesByDomain: info.cookiesByDomain);
            if (sniffed == null) continue; // sniffer could not read it (or hit its own deadline); leave untouched

            // MediaFormat.copyWith's nullable parameters mean "keep the
            // existing value" when passed null (it does `param ?? this.param`
            // internally) - it has no way to *clear* a field back to null.
            // That is exactly what we want here: [sniffed]'s dimensions/
            // codec are null only when the box tree did not carry that
            // particular piece (e.g. an audio-only sniff has no
            // width/height at all), and a format flagged
            // capabilitiesUnknown never had a confirmed non-null value for
            // these to begin with (FormatExpander's muxed-default guess
            // never sets width/height/codec) - so passing sniffed's
            // (possibly null) fields straight through can only add
            // information, never silently discard a value we already knew
            // to be true. hasVideo/hasAudio are never null on
            // [Mp4TrackInfo] (they are what this whole resolver exists to
            // correct) so those two always overwrite unconditionally.
            corrected[index] = format.copyWith(
              videoCodec: sniffed.videoCodec,
              audioCodec: sniffed.audioCodec,
              width: sniffed.width,
              height: sniffed.height,
              hasVideo: sniffed.hasVideo,
              hasAudio: sniffed.hasAudio,
              capabilitiesUnknown: false,
              // Round 3 (Codex#2): a format that CLAIMED audio and is now
              // proven audio-less by the sniffer must not be laundered
              // into the selector's silent-source tier as if the source
              // were honestly muted - same marker the pipeline correction
              // and the HLS mapper set for the same situation.
              audioWasStripped: format.audioWasStripped || (format.hasAudio && !sniffed.hasAudio),
            );
          } catch (_) {
            // Any failure for this one format must not stop the rest of
            // the pool, and must not fail resolve() as a whole - the
            // format is simply left as it was. (A sniff that ran out of
            // time does not even reach here: [Mp4TrackSniffer] returns
            // null on its own deadline rather than throwing.)
          }
        }
      }

      final workerCount = concurrency < 1
          ? 1
          : (concurrency > candidateIndexes.length ? candidateIndexes.length : concurrency);
      await Future.wait(List.generate(workerCount, (_) => worker()));

      if (corrected.isEmpty) return info;

      // Phase 6 round 2 (S-R8): goes through `MediaInfo.copyWith` rather
      // than a hand-rolled field-by-field reconstruction - the latter is
      // exactly the shape that dropped `cookiesByDomain` the first time
      // around (round 1's bug this contract now exists to prevent).
      return info.copyWith(
        formats: [for (var i = 0; i < info.formats.length; i++) corrected[i] ?? info.formats[i]],
      );
    } catch (_) {
      // Never throws: any unexpected failure falls back to the original,
      // uncorrected info rather than breaking the whole resolve/rank step.
      return info;
    }
  }
}
