import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/cli/cli_sites.dart';

/// Extractor class name -> the id `mida-cli sites` prints for it.
const _idByClass = {
  'YoutubeExtractor': 'youtube',
  'TwitterExtractor': 'x',
  'TikTokExtractor': 'tiktok',
  'InstagramExtractor': 'instagram',
  'NaverExtractor': 'naver-tv',
  'ChzzkExtractor': 'chzzk',
  'KakaoExtractor': 'kakao',
  'DailymotionExtractor': 'dailymotion',
  'TwitchExtractor': 'twitch',
  'RedditExtractor': 'reddit',
  'SoundCloudExtractor': 'soundcloud',
  'BilibiliExtractor': 'bilibili',
  'DouyinExtractor': 'douyin',
  'NiconicoExtractor': 'niconico',
  'OdyseeExtractor': 'odysee',
  'VimeoExtractor': 'vimeo',
  'FacebookExtractor': 'facebook',
  'PinterestExtractor': 'pinterest',
  'SoopExtractor': 'soop',
  'LinkedInExtractor': 'linkedin',
  'XiaohongshuExtractor': 'xiaohongshu',
  'TelegramExtractor': 'telegram',
  'RumbleExtractor': 'rumble',
  'StreamableExtractor': 'streamable',
  'BlueskyExtractor': 'bluesky',
};

/// The registry exposes no listing API and constructing it is not free, so
/// this reads the builder's source: every `XxxExtractor(` in the primary
/// list before the catch-all `GenericExtractor`.
List<String> _nativeClassesInBuilder() {
  final source = File('lib/core/extractors/extractor_registry_builder.dart').readAsStringSync();
  final body = source.substring(source.indexOf('return ExtractorRegistry('));
  final primary = body.substring(0, body.indexOf('GenericExtractor('));
  return [for (final m in RegExp(r'\b(\w+Extractor)\(').allMatches(primary)) m.group(1)!];
}

void main() {
  test('sites list matches the registry builder, in order', () {
    final classes = _nativeClassesInBuilder();
    expect(classes, isNotEmpty);
    final unknown = classes.where((c) => !_idByClass.containsKey(c)).toList();
    expect(unknown, isEmpty, reason: 'new extractor: add it to nativeSiteIds and _idByClass');
    expect(nativeSiteIds, [for (final c in classes) _idByClass[c]]);
  });

  test('measured_live is exactly what docs/coverage-corpus.md recorded as downloaded', () {
    final doc = File('docs/coverage-corpus.md').readAsStringSync();
    // Corpus table: site key -> tier text.
    final tierByKey = {
      for (final m in RegExp(r'^\| ([a-z0-9-]+) \| \S+.*?\| ([^|]+) \|', multiLine: true).allMatches(doc))
        m.group(1)!: m.group(2)!.trim(),
    };
    final downloaded = RegExp(r'^Downloaded: ([^.]+)\.', multiLine: true)
        .firstMatch(doc)!
        .group(1)!
        .split(RegExp(r',\s*'))
        .map((k) => k.trim())
        .toList();
    // The v2.3.0 five-site rerun: "4/5 now download" names its sites in
    // the next sentence ("niconico 15.7MB, pinterest 0.7MB, ...").
    final rerun = RegExp(r'4/5 now download with both streams\*\* - (.+?MB)\. ')
        .firstMatch(doc.replaceAll('\n', ' '))!
        .group(1)!
        .split(RegExp(r',\s*'))
        .map((s) => s.trim().split(' ').first)
        .toList();
    expect(downloaded, hasLength(19));
    expect(rerun, ['niconico', 'pinterest', 'ted', 'facebook']);

    const nativeByTier = {
      'Native (YouTube)': 'youtube',
      'Native (X/Twitter)': 'x',
      'Native (TikTok)': 'tiktok',
      'Native (Instagram)': 'instagram',
      'Native (Naver TV)': 'naver-tv',
      'Native (CHZZK)': 'chzzk',
      'Native (SoundCloud)': 'soundcloud',
      'Native (Douyin)': 'douyin',
      'Native (Odysee)': 'odysee',
    };
    String idFor(String key) {
      // w3schools is listed as "w3schools" in the result line but keyed
      // "w3schools-mp4" in the table.
      final tier = tierByKey[key] ?? tierByKey['$key-mp4'] ?? tierByKey['$key-public'];
      expect(tier, isNotNull, reason: 'no corpus row for $key');
      if (tier == 'Generic analysis') return 'generic';
      if (tier == 'Browser capture') return 'browser-capture';
      expect(nativeByTier, contains(tier), reason: '$key: $tier');
      return nativeByTier[tier]!;
    }

    final expected = {for (final k in downloaded) idFor(k)};
    // The rerun's niconico went through browser capture (the native parser
    // failed), and pinterest/ted/facebook through the generic or capture
    // tiers: they add tiers, never a native.
    expect(doc, contains('niconico passes through the **browser capture** tier, not the native extractor'));
    for (final k in rerun) {
      final id = k == 'niconico' ? 'browser-capture' : idFor(k);
      expect(id == 'generic' || id == 'browser-capture', isTrue, reason: k);
      expected.add(id);
    }
    expect(measuredLiveSiteIds.toSet(), expected);
    expect(measuredLiveSiteIds, hasLength(expected.length));
    for (final id in measuredLiveSiteIds) {
      expect([...nativeSiteIds, ...siteTiers], contains(id));
    }
    for (final v240 in ['facebook', 'pinterest', 'soop', 'linkedin', 'xiaohongshu', 'telegram', 'rumble', 'streamable', 'bluesky']) {
      expect(measuredLiveSiteIds, isNot(contains(v240)), reason: '$v240 is a v2.4.0 native, not measured live');
    }
  });

  test('ids are unique, lowercase and shell friendly', () {
    expect(nativeSiteIds.toSet(), hasLength(nativeSiteIds.length));
    for (final id in [...nativeSiteIds, ...siteTiers]) {
      expect(id, matches(RegExp(r'^[a-z0-9-]+$')));
    }
  });
}
