import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mida/core/extractors/media_models.dart';
import 'package:mida/core/services/browser_devtools_session.dart';
import 'package:mida/core/services/cdp_client.dart';

/// Starts a bare-bones fake DevTools WebSocket endpoint (a local
/// `HttpServer` upgraded via `WebSocketTransformer`, no real browser
/// involved), matching the plan's own guidance for testing the CDP client
/// without a browser. The first (and only) accepted socket is handed back
/// through [onSocket] so the test can script replies.
Future<HttpServer> _startFakeDevtoolsServer(void Function(WebSocket socket) onSocket) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final socket = await WebSocketTransformer.upgrade(request);
    onSocket(socket);
  });
  return server;
}

File _writeFakeBrowser(Directory dir, {required String name, required List<String> script}) {
  final file = File('${dir.path}/$name.bat');
  file.writeAsStringSync(script.join('\r\n'));
  return file;
}

/// Minimal `implements Process` stand-in whose `exitCode` is already
/// complete - for exercising `killAndAwaitExit`'s process-tree sweep
/// without spawning (or waiting on) a real OS process.
class _InstantExitFakeProcess implements Process {
  @override
  final int pid;

  /// Shared with a test's own `processTreeKiller` override so the two can
  /// be compared for relative order - see the "process-tree sweep" group
  /// below.
  final List<String>? callOrder;

  _InstantExitFakeProcess({required this.pid, this.callOrder});

  @override
  Stream<List<int>> get stdout => const Stream.empty();

  @override
  Stream<List<int>> get stderr => const Stream.empty();

  @override
  IOSink get stdin => IOSink(StreamController<List<int>>().sink);

  @override
  Future<int> get exitCode => Future.value(0);

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    callOrder?.add('processKill');
    return true;
  }
}

void main() {
  group('CdpClient (fake DevTools WebSocket endpoint)', () {
    late HttpServer server;

    tearDown(() async {
      await server.close(force: true);
    });

    test('send() resolves with the id-correlated result', () async {
      server = await _startFakeDevtoolsServer((socket) {
        socket.listen((raw) {
          final message = jsonDecode(raw as String) as Map<String, dynamic>;
          socket.add(jsonEncode({'id': message['id'], 'result': {'echo': message['method']}}));
        });
      });

      final client = await CdpClient.connect(Uri.parse('ws://127.0.0.1:${server.port}/devtools/browser/fake'));
      final result = await client.send('Foo.bar');

      expect(result, {'echo': 'Foo.bar'});
      await client.close();
    });

    test('sessionId is included in the outgoing frame and on inbound events', () async {
      final receivedSessionIds = <String?>[];
      server = await _startFakeDevtoolsServer((socket) {
        socket.listen((raw) {
          final message = jsonDecode(raw as String) as Map<String, dynamic>;
          receivedSessionIds.add(message['sessionId'] as String?);
          socket.add(jsonEncode({
            'method': 'Network.responseReceived',
            'sessionId': message['sessionId'],
            'params': {
              'response': {'url': 'https://cdn.example.com/v.mp4', 'mimeType': 'video/mp4'}
            },
          }));
          socket.add(jsonEncode({'id': message['id'], 'result': {}}));
        });
      });

      final client = await CdpClient.connect(Uri.parse('ws://127.0.0.1:${server.port}/devtools/browser/fake'));
      final events = <CdpEvent>[];
      final sub = client.events.listen(events.add);

      await client.send('Network.enable', sessionId: 'session-abc');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(receivedSessionIds, contains('session-abc'));
      expect(events, hasLength(1));
      expect(events.single.method, 'Network.responseReceived');
      expect(events.single.sessionId, 'session-abc');

      await sub.cancel();
      await client.close();
    });

    test('send() times out when no reply ever arrives', () async {
      server = await _startFakeDevtoolsServer((socket) {
        socket.listen((_) {}); // Accepts the frame but never replies.
      });

      final client = await CdpClient.connect(Uri.parse('ws://127.0.0.1:${server.port}/devtools/browser/fake'));

      await expectLater(
        client.send('Never.replies', timeout: const Duration(milliseconds: 200)),
        throwsA(isA<TimeoutException>()),
      );

      await client.close();
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('guard can fail: an id mismatch never resolves the waiting completer', () async {
      // Proves the id-correlation in CdpClient._onData is load-bearing: if
      // it matched on anything looser than an exact id, a reply carrying a
      // *different* id would incorrectly complete our pending command and
      // this test would go green with the wrong (empty) result instead of
      // timing out.
      server = await _startFakeDevtoolsServer((socket) {
        socket.listen((raw) {
          final message = jsonDecode(raw as String) as Map<String, dynamic>;
          final wrongId = (message['id'] as int) + 999;
          socket.add(jsonEncode({'id': wrongId, 'result': {'should': 'not-be-seen'}}));
        });
      });

      final client = await CdpClient.connect(Uri.parse('ws://127.0.0.1:${server.port}/devtools/browser/fake'));

      await expectLater(
        client.send('Foo.bar', timeout: const Duration(milliseconds: 200)),
        throwsA(isA<TimeoutException>()),
      );

      await client.close();
    }, timeout: const Timeout(Duration(seconds: 10)));
  });

  group('BrowserDevtoolsSession.launch lifecycle guards', () {
    late Directory workDir;

    setUp(() {
      workDir = Directory.systemTemp.createTempSync('mida_cdp_session_test_');
    });

    tearDown(() {
      if (workDir.existsSync()) workDir.deleteSync(recursive: true);
    });

    // Matches only `BrowserDevtoolsSession.launch`'s own profile-dir
    // naming (`mida_cdp_` + a bare hex suffix, no further underscores -
    // confirmed empirically against `Directory.createTempSync`'s actual
    // output). Deliberately *not* a denylist of this file's own harness
    // prefix (`mida_cdp_session_test_`): `flutter test` runs multiple test
    // files concurrently, and a sibling suite's own harness dirs (e.g.
    // `mida_cdp_identity_test_*`, `mida_cdp_autoattach_test_*` in
    // `browser_devtools_session_attach_test.dart`) can appear and vanish
    // between this test's before/after snapshots purely from that other
    // file's own setUp/tearDown timing - a denylist would need updating
    // every time a new sibling harness prefix is added, and until then
    // would flake exactly like that.
    final productionProfileDirName = RegExp(r'^mida_cdp_[a-z0-9]+$');
    Set<String> midaCdpTempDirs() => Directory.systemTemp
        .listSync()
        .whereType<Directory>()
        .map((d) => d.path)
        .where((p) => productionProfileDirName.hasMatch(p.split(Platform.pathSeparator).last))
        .toSet();

    test('BROWSER_MISSING when no candidate executable exists on disk', () async {
      await expectLater(
        BrowserDevtoolsSession.launch(candidatePaths: () => ['${workDir.path}/does-not-exist.exe']),
        throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'BROWSER_MISSING')),
      );
    });

    test(
      'kills the underlying process and deletes the profile dir when the DevTools port never comes up',
      () async {
        // Round 6 (coordinator flake report): this used to spawn a
        // `ping -n 1 127.0.0.1` (~1 real second per tick) tick loop, wait a
        // real 900ms to sample it, and assert a 10s wall-clock ceiling
        // across a doubled headed+headless attempt - occasionally flaky
        // under load (CI/parallel contention slowing real process
        // scheduling enough to tip either bound). Rewritten to keep real
        // waits under 2s total and to assert on the *recorded* marker-file
        // call count at two fixed, short checkpoints rather than a wall-
        // clock race: `preferHeaded: false` removes the doubled attempt
        // entirely (single connect attempt only), `connectTimeout` is cut
        // to 150ms, and the fake browser ticks via a delay-free loop (as
        // fast as the batch interpreter allows, hundreds of ticks/second)
        // so a short, fixed 200ms sampling window still yields a large,
        // unambiguous tick-count delta when *not* killed - no need for a
        // long real wait to get separation between "still running" and
        // "killed".
        final marker = File('${workDir.path}/beats.txt');
        final bat = _writeFakeBrowser(
          workDir,
          name: 'silent_hang',
          script: [
            '@echo off',
            ':loop',
            'echo tick>>"${marker.path}"',
            'goto loop',
          ],
        );

        final before = midaCdpTempDirs();
        await expectLater(
          BrowserDevtoolsSession.launch(
            candidatePaths: () => [bat.path],
            connectTimeout: const Duration(milliseconds: 150),
            preferHeaded: false,
          ),
          throwsA(isA<MediaExtractionException>().having((e) => e.status, 'status', 'NETWORK')),
        );
        final after = midaCdpTempDirs();

        // Guard 1 (profile cleanup): no *new* mida_cdp_* dir survives a
        // failed launch - `after.difference(before)`, not `after ==
        // before`: `launch()` also fires a fire-and-forget
        // BrowserTempCleanup.sweepStale() that can legitimately delete
        // some *other*, genuinely stale (>1h old) directory from a prior
        // run concurrently with this test's own before/after snapshots;
        // that is a benign shrink, not the leak this guard exists to
        // catch. Commenting out `BrowserTempCleanup.deleteQuietly` in the
        // `launch()` catch block still turns this red (this test's own
        // profile dir would be the one new entry in `after`).
        expect(after.difference(before), isEmpty);

        // Guard 2 (process actually killed, not just our own await
        // returning): the .bat keeps appending to `marker` every tick,
        // as fast as it can, until it is killed. A fixed 200ms window
        // (well under this file's own 2s ceiling) after the throw is
        // plenty of separation - if `process.kill()` were commented out
        // of `launch()`'s catch block, the un-killed loop would keep
        // appending lines throughout that window; a killed process
        // appends exactly zero more.
        final countAtThrow = marker.existsSync() ? marker.readAsLinesSync().length : 0;
        await Future<void>.delayed(const Duration(milliseconds: 200));
        final countLater = marker.existsSync() ? marker.readAsLinesSync().length : 0;
        expect(countLater, countAtThrow);
      },
      timeout: const Timeout(Duration(seconds: 10)),
    );

    test('passes --remote-debugging-address=127.0.0.1, not just the port, to the browser executable', () async {
      final marker = File('${workDir.path}/args.txt');
      final bat = _writeFakeBrowser(
        workDir,
        name: 'echo_args_then_hang',
        script: [
          '@echo off',
          'echo %*>"${marker.path}"',
          ':loop',
          'ping -n 1 127.0.0.1 >nul',
          'goto loop',
        ],
      );

      await expectLater(
        BrowserDevtoolsSession.launch(
          candidatePaths: () => [bat.path],
          connectTimeout: const Duration(milliseconds: 300),
        ),
        throwsA(isA<MediaExtractionException>()),
      );

      final args = marker.readAsStringSync();
      // Guard can fail: removing the address flag from `launch()`'s
      // argument list (leaving only `--remote-debugging-port`) makes this
      // `contains` assertion fail - verified by hand while writing this
      // test, then restored (diffed byte-identical against the pre-check
      // copy before moving on).
      expect(args, contains('--remote-debugging-address=127.0.0.1'));
    }, timeout: const Timeout(Duration(seconds: 15)));
  });

  group('BrowserDevtoolsSession.killAndAwaitExit process-tree sweep', () {
    test('invokes the injected processTreeKiller with the process\'s own pid', () async {
      final process = _InstantExitFakeProcess(pid: 98765);
      int? capturedPid;

      await BrowserDevtoolsSession.killAndAwaitExit(
        process,
        processTreeKiller: (executable, arguments) async {
          capturedPid = int.parse(arguments.last);
          return ProcessResult(0, 0, '', '');
        },
      );

      expect(capturedPid, 98765);
    });

    test('guard can fail: the tree kill is issued before the parent process is killed, not after', () async {
      // Independent review round 2: `taskkill /T` (or `pkill -P` on
      // macOS/Linux) needs a *live* tree to walk - calling it after the
      // parent has already been killed and awaited orphans its children
      // instead of reaching them.
      final callOrder = <String>[];
      final process = _InstantExitFakeProcess(pid: 98765, callOrder: callOrder);

      await BrowserDevtoolsSession.killAndAwaitExit(
        process,
        processTreeKiller: (executable, arguments) async {
          callOrder.add('treeKill');
          return ProcessResult(0, 0, '', '');
        },
      );

      expect(callOrder, ['treeKill', 'processKill']);
    });
  });
}
