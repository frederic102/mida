import 'dart:convert';
import 'dart:io';
const ua = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15';
Future<void> main(List<String> args) async {
  final http = HttpClient();
  for (final videoId in args) {
    // 1. watch page: collect cookies + visitorData
    final pr = await http.getUrl(Uri.parse('https://www.youtube.com/watch?v=$videoId'));
    pr.headers.set('User-Agent', ua);
    pr.headers.set('Accept-Language', 'en-us,en;q=0.5');
    pr.headers.set('Cookie', 'SOCS=CAI; PREF=hl=en&tz=UTC');
    final pres = await pr.close();
    final cookies = <String, String>{'SOCS': 'CAI', 'PREF': 'hl=en&tz=UTC'};
    for (final c in pres.cookies) { cookies[c.name] = c.value; }
    final html = await pres.transform(utf8.decoder).join();
    final vd = RegExp(r'"visitorData":"([^"]+)"').firstMatch(html)?.group(1);
    print('[$videoId] page HTTP ${pres.statusCode} cookies=${cookies.keys.toList()} visitorData=${vd != null}');
    final cookieHeader = cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
    // 2. visionos player with cookies + visitorData
    final body = jsonEncode({
      'context': {'client': {'clientName': 'VISIONOS', 'clientVersion': '1.02', 'deviceMake': 'Apple', 'deviceModel': 'RealityDevice17,1', 'osName': 'visionOS', 'osVersion': '26.5.23O471', 'userAgent': ua, 'hl': 'en', if (vd != null) 'visitorData': vd}},
      'videoId': videoId, 'contentCheckOk': true, 'racyCheckOk': true,
      'playbackContext': {'contentPlaybackContext': {'html5Preference': 'HTML5_PREF_WANTS'}},
    });
    final req = await http.postUrl(Uri.parse('https://www.youtube.com/youtubei/v1/player?prettyPrint=false'));
    req.headers.set('Content-Type', 'application/json');
    req.headers.set('User-Agent', ua);
    req.headers.set('X-YouTube-Client-Name', '101');
    req.headers.set('X-YouTube-Client-Version', '1.02');
    req.headers.set('Origin', 'https://www.youtube.com');
    req.headers.set('Accept-Language', 'en-us,en;q=0.5');
    req.headers.set('Cookie', cookieHeader);
    if (vd != null) req.headers.set('X-Goog-Visitor-Id', vd);
    req.write(body);
    final res = await req.close();
    final json = jsonDecode(await res.transform(utf8.decoder).join()) as Map<String, dynamic>;
    final ps = json['playabilityStatus'] as Map?;
    final sd = json['streamingData'] as Map?;
    final all = [...((sd?['formats'] as List?) ?? []), ...((sd?['adaptiveFormats'] as List?) ?? [])];
    final withUrl = all.where((f) => (f as Map).containsKey('url')).length;
    final hs = all.where((f) => (f as Map)['height'] != null).map((f) => (f as Map)['height'] as int).toSet().toList()..sort();
    print('    player status=${ps?['status']} ${ps?['reason'] ?? ''} formats=${all.length} url=$withUrl heights=$hs');
    final checks = <int>[];
    for (final itag in [137, 140, 251, 18]) {
      final f = all.cast<Map>().where((m) => m['itag'] == itag && m.containsKey('url')).firstOrNull;
      if (f == null) continue;
      final r = await http.getUrl(Uri.parse(f['url']));
      r.headers.set('User-Agent', ua);
      r.headers.set('Range', 'bytes=0-1023');
      final rr = await r.close(); await rr.drain();
      checks.add(rr.statusCode);
    }
    print('    range checks (137,140,251,18): $checks');
  }
  http.close();
}
