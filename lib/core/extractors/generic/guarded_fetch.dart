import 'dart:io';

import '../../net/host_policy.dart';
import 'bounded_body.dart';
import 'format_expander.dart';
import 'stage_deadline.dart';

/// The generic family's one guarded GET: [HostPolicy.guardedRequest] (per
/// hop private-network and DNS-rebinding checks), at most [maxBytes] of
/// body ([readBoundedBytes]), the whole request plus body read bounded by
/// [deadline] and [timeout] ([runBounded]), and the client force-closed in
/// every outcome. Shared by `GenericExtractor` (page, embed page, oEmbed,
/// manifest fetches) and `GuardedEmbedHttp` (platform player APIs).
/// [resolveHost] is the DNS seam for the rebinding check (real lookup by
/// default; tests inject a fake answer).
Future<FetchedBody> guardedBoundedGet(
  HttpClient Function() httpClientFactory,
  Uri url, {
  required int maxBytes,
  bool allowPrivateHosts = false,
  void Function(HttpClientRequest request)? configureRequest,
  StageDeadline? deadline,
  Duration? timeout,
  Future<List<InternetAddress>> Function(String host) resolveHost = InternetAddress.lookup,
}) async {
  deadline?.ensureActive();
  final client = httpClientFactory();
  try {
    return await runBounded(deadline, client, () async {
      final response = await HostPolicy.guardedRequest(
        client,
        url,
        useHead: false,
        allowPrivateHosts: allowPrivateHosts,
        configureRequest: configureRequest,
        resolveHost: resolveHost,
      );
      final body = await readBoundedBody(response, maxBytes);
      return FetchedBody(statusCode: response.statusCode, body: body);
    }, timeout: timeout);
  } finally {
    client.close(force: true);
  }
}
