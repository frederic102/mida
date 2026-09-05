import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Policy note (`docs/plan-phase5-coverage.md` Lane D review round 2):
/// this reproduces Bilibili's own public web-player signing contract -
/// a public signing constant (the mixin-key table below) shipped in
/// Bilibili's own JavaScript and republished by every third-party
/// client, applied the same documented way Bilibili's own player applies
/// it. No challenge solving, no fingerprint spoofing. If Bilibili changes
/// this contract, this stops working and we stop - we do not evade.
///
/// Signs a Bilibili API request's query parameters with the "WBI"
/// (`w_rid`/`wts`) scheme most of `api.bilibili.com`'s player/interface
/// endpoints have required since 2023, including the DASH `playurl` this
/// extractor calls at `qn=120` and above.
///
/// The mixin key table below is a long-stable, widely published constant
/// (not a secret this app is bypassing anything to obtain - every
/// third-party Bilibili client republishes the same 64 indices; see
/// `docs/plan-phase5-coverage.md` Lane D follow-up report for the source
/// of this pass's copy) that permutes the two filename fragments from
/// `x/web-interface/nav`'s `wbi_img.img_url`/`sub_url` into a 32-char
/// mixin key. Verified live 2026-09-05: this class's [sign] output for a
/// fixed param set + a real `img`/`sub` key pair fetched from `nav` that
/// day matches an independent Python reference implementation of the same
/// public algorithm byte for byte (`test/core/extractors/bilibili/
/// bilibili_wbi_signer_test.dart`) - the guard-can-fail evidence for this
/// file: transposing any two entries in [_mixinKeyEncTab] changes the
/// mixin key and makes that test fail.
class BilibiliWbiSigner {
  const BilibiliWbiSigner();

  static const _mixinKeyEncTab = [
    46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49, //
    33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40, 61, //
    26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36, //
    20, 34, 44, 52,
  ];

  /// Characters Bilibili's own signer strips from every param value before
  /// url-encoding it (observed in the public JS implementation this port
  /// is based on) - not a security measure, just part of matching the
  /// exact string the server re-derives `w_rid` from.
  static final _stripPattern = RegExp(r"[!'()*]");

  /// Derives the 32-char mixin key from the filename fragment of
  /// `wbi_img.img_url` and `wbi_img.sub_url` (the path segment before the
  /// extension, e.g. `7cd084941338484aae1ad9425b84077c` out of
  /// `https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png`).
  String mixinKey(String imgKey, String subKey) {
    final raw = imgKey + subKey;
    final buffer = StringBuffer();
    for (final index in _mixinKeyEncTab) {
      if (index < raw.length) buffer.write(raw[index]);
    }
    final mixed = buffer.toString();
    return mixed.length > 32 ? mixed.substring(0, 32) : mixed;
  }

  /// Returns [params] with `wts` (unix seconds) and `w_rid` (the MD5 of
  /// every param - itself included - sorted by key, url-encoded, joined
  /// with `&`, then the mixin key appended) added. [now] is injectable so
  /// tests can pin the timestamp the way `RetryPolicy`'s `sleeper`/
  /// `random` are pinned elsewhere in this codebase.
  Map<String, String> sign(
    Map<String, String> params,
    String imgKey,
    String subKey, {
    DateTime Function()? now,
  }) {
    final wts = ((now ?? DateTime.now)().millisecondsSinceEpoch / 1000).floor().toString();
    final withWts = {...params, 'wts': wts};

    final sortedKeys = withWts.keys.toList()..sort();
    final query = sortedKeys
        .map((key) => '$key=${Uri.encodeQueryComponent(withWts[key]!.replaceAll(_stripPattern, ''))}')
        .join('&');

    final mixin = mixinKey(imgKey, subKey);
    final wRid = md5.convert(utf8.encode(query + mixin)).toString();

    return {...withWts, 'w_rid': wRid};
  }

  /// Extracts the filename-without-extension fragment `mixinKey` needs
  /// from a `wbi_img.img_url`/`sub_url` value.
  static String keyFromUrl(String url) {
    final fileName = url.split('/').last;
    final dot = fileName.lastIndexOf('.');
    return dot < 0 ? fileName : fileName.substring(0, dot);
  }
}
