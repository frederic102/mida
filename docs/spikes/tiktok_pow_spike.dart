import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';

const ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36';

String? attrClass(String html, String id) {
  final m = RegExp('<[^>]+\\bid="$id"[^>]*>').firstMatch(html);
  if (m == null) return null;
  return RegExp('class="([^"]*)"').firstMatch(m.group(0)!)?.group(1);
}

Future<(int, String, List<Cookie>)> get(HttpClient http, Uri uri, Map<String, String> cookies) async {
  final r = await http.getUrl(uri);
  r.headers.set('User-Agent', ua);
  r.headers.set('Accept', 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8');
  r.headers.set('Accept-Language', 'en-US,en;q=0.9');
  if (cookies.isNotEmpty) r.headers.set('Cookie', cookies.entries.map((e) => '${e.key}=${e.value}').join('; '));
  final res = await r.close();
  final body = await res.transform(utf8.decoder).join();
  return (res.statusCode, body, res.cookies);
}

Future<void> main(List<String> args) async {
  final url = Uri.parse(args.isNotEmpty ? args[0] : 'https://www.tiktok.com/@hankgreen1/video/7047596209028074758');
  final http = HttpClient();
  final jar = <String, String>{};
  var (status, html, setCookies) = await get(http, url, jar);
  for (final c in setCookies) jar[c.name] = c.value;
  print('GET1 HTTP $status bytes=${html.length} universal=${html.contains('__UNIVERSAL_DATA_FOR_REHYDRATION__')} challenge=${html.contains('id="cs"')} cookies=${jar.keys.toList()}');
  if (!html.contains('__UNIVERSAL_DATA_FOR_REHYDRATION__')) {
    final cs = attrClass(html, 'cs');
    if (cs == null) { print('no challenge data; body head: ${html.substring(0, html.length.clamp(0, 300))}'); return; }
    final challenge = jsonDecode(utf8.decode(base64.decode('$cs==='.substring(0, (cs.length + 3) ~/ 4 * 4)))) as Map<String, dynamic>;
    final v = challenge['v'] as Map<String, dynamic>;
    final expected = base64.decode(v['c'] as String);
    final seed = base64.decode(v['a'] as String);
    final sw = Stopwatch()..start();
    String? found;
    for (var i = 0; i <= 1000000; i++) {
      final d = sha256.convert([...seed, ...utf8.encode('$i')]).bytes;
      var eq = d.length == expected.length;
      if (eq) { for (var k = 0; k < d.length; k++) { if (d[k] != expected[k]) { eq = false; break; } } }
      if (eq) { found = '$i'; break; }
    }
    print('PoW solved=$found in ${sw.elapsedMilliseconds}ms');
    if (found == null) return;
    challenge['d'] = base64.encode(utf8.encode(found));
    final wci = attrClass(html, 'wci') ?? '_wafchallengeid';
    final rci = attrClass(html, 'rci');
    final rs = attrClass(html, 'rs');
    jar[wci] = base64.encode(utf8.encode(jsonEncode(challenge)));
    if (rci != null && rs != null) jar[rci] = rs;
    print('cookie names: wci=$wci rci=$rci');
    (status, html, setCookies) = await get(http, url, jar);
    for (final c in setCookies) jar[c.name] = c.value;
    print('GET2 HTTP $status bytes=${html.length} universal=${html.contains('__UNIVERSAL_DATA_FOR_REHYDRATION__')} challenge=${html.contains('id="cs"')} login=${html.contains('/login')}');
  }
  final m = RegExp(r'<script[^>]+\bid="__UNIVERSAL_DATA_FOR_REHYDRATION__"[^>]*>(.*?)</script>', dotAll: true).firstMatch(html);
  if (m == null) { print('no universal data'); http.close(); return; }
  final data = jsonDecode(m.group(1)!) as Map<String, dynamic>;
  final detail = (data['__DEFAULT_SCOPE__'] as Map)['webapp.video-detail'] as Map?;
  final item = ((detail?['itemInfo'] as Map?)?['itemStruct']) as Map?;
  print('statusCode=${detail?['statusCode']} desc=${item?['desc']} duration=${(item?['video'] as Map?)?['duration']}');
  final bitrates = ((item?['video'] as Map?)?['bitrateInfo'] as List?) ?? [];
  for (final b in bitrates) {
    final pa = (b as Map)['PlayAddr'] as Map;
    print('  ${pa['UrlKey']} ${b['Bitrate']} ${pa['Width']}x${pa['Height']} urls=${(pa['UrlList'] as List).length}');
  }
  if (bitrates.isNotEmpty) {
    final pa = (bitrates.first as Map)['PlayAddr'] as Map;
    final u = Uri.parse((pa['UrlList'] as List).first as String);
    final r = await http.getUrl(u);
    r.headers.set('User-Agent', ua);
    r.headers.set('Referer', 'https://www.tiktok.com/');
    r.headers.set('Range', 'bytes=0-1023');
    r.headers.set('Cookie', jar.entries.map((e) => '${e.key}=${e.value}').join('; '));
    final rr = await r.close();
    await rr.drain();
    print('stream Range GET -> HTTP ${rr.statusCode} ${rr.headers.value('content-type')}');
  }
  http.close();
}
