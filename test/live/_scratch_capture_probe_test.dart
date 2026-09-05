// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:mida/core/services/browser_devtools_session.dart';

/// THROWAWAY investigation script, not part of any lane's deliverables.
/// Deleted before this task is reported done. Opens one URL in a headless
/// browser and dumps every request/response URL seen, so the Naver/Kakao/
/// CHZZK playback API can be identified without guessing.
void main() {
  final isLive = Platform.environment['MIDA_LIVE'] == '1';
  final targetUrl = Platform.environment['PROBE_URL'];

  test(
    'scratch probe',
    () async {
      final session = await BrowserDevtoolsSession.launch();
      final seen = <String>{};
      final matchSubstr = Platform.environment['PROBE_BODY_MATCH'];
      final sub = session.events.listen((event) {
        if (event.method == 'Network.requestWillBeSent') {
          final url = event.params['request']?['url'] as String?;
          if (url != null && seen.add(url)) {
            print('REQ: $url');
          }
        }
        if (event.method == 'Network.responseReceived') {
          final url = event.params['response']?['url'] as String?;
          final mimeType = event.params['response']?['mimeType'] as String?;
          final requestId = event.params['requestId'] as String?;
          if (url != null) {
            print('RES[$mimeType]: $url');
          }
          if (matchSubstr != null && url != null && url.contains(matchSubstr) && requestId != null) {
            Future<void>.delayed(const Duration(milliseconds: 500), () async {
              try {
                final body = await session.send('Network.getResponseBody', {'requestId': requestId});
                print('BODY[$url]:${body['body']}');
              } catch (e) {
                print('BODY_ERR[$url]: $e');
              }
            });
          }
        }
      });

      await session.send('Page.navigate', {'url': targetUrl});
      await Future<void>.delayed(const Duration(seconds: 4));

      // Try to nudge playback.
      try {
        await session.send('Runtime.evaluate', {
          'expression':
              'document.querySelector("video")?.play(); document.querySelector("[class*=play]")?.click();',
        });
      } catch (_) {}

      await Future<void>.delayed(const Duration(seconds: 12));

      try {
        final result = await session.send('Runtime.evaluate', {
          'expression':
              'JSON.stringify(Array.from(document.querySelectorAll("a[href*=\\"/v/\\"]")).map(a=>a.getAttribute("href")).slice(0,20))',
          'returnByValue': true,
        });
        print('LINKS: ${result['result']?['value']}');
      } catch (e) {
        print('LINKS_ERR: $e');
      }

      await sub.cancel();
      await session.close();
    },
    skip: isLive ? false : 'set MIDA_LIVE=1 and PROBE_URL=<url>',
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
