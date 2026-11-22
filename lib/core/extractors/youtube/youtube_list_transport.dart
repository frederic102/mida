import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../media_models.dart';

/// The two public YouTube web calls the lister needs. An interface so tests
/// can feed captured pages without a socket.
abstract class YoutubeListTransport {
  /// GET a public page or feed as text.
  Future<String> getText(Uri url);

  /// POST `/youtubei/v1/browse` with [body]; the decoded JSON object.
  Future<Map<String, dynamic>> postBrowse(Map<String, dynamic> body);

  void close();
}

/// Plain `dart:io` transport: a desktop-browser User-Agent, the same seed
/// cookies as [YoutubeSession], no login, no challenge handling.
class YoutubeHttpTransport implements YoutubeListTransport {
  static const _userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
  static const _maxBytes = 12 * 1024 * 1024;

  final HttpClient _client;
  final Duration _timeout;

  YoutubeHttpTransport({HttpClient? client, Duration timeout = const Duration(seconds: 30)})
      : _client = client ?? HttpClient(),
        _timeout = timeout;

  @override
  Future<String> getText(Uri url) async {
    final request = await _client.getUrl(url).timeout(_timeout);
    _headers(request);
    return _read(await request.close().timeout(_timeout));
  }

  @override
  Future<Map<String, dynamic>> postBrowse(Map<String, dynamic> body) async {
    final request = await _client
        .postUrl(Uri.parse('https://www.youtube.com/youtubei/v1/browse?prettyPrint=false'))
        .timeout(_timeout);
    _headers(request);
    request.headers.set('Content-Type', 'application/json');
    request.headers.set('Origin', 'https://www.youtube.com');
    request.headers.set('X-YouTube-Client-Name', '1');
    request.write(jsonEncode(body));
    final text = await _read(await request.close().timeout(_timeout));
    try {
      final json = jsonDecode(text);
      if (json is Map<String, dynamic>) return json;
    } on FormatException {
      // falls through to the error below
    }
    throw const MediaExtractionException('PARSE_ERROR', 'The browse response is not a JSON object.');
  }

  void _headers(HttpClientRequest request) {
    request.headers.set('User-Agent', _userAgent);
    request.headers.set('Accept-Language', 'en-US,en;q=0.9');
    request.headers.set('Cookie', 'SOCS=CAI; PREF=hl=en&tz=UTC');
  }

  Future<String> _read(HttpClientResponse response) async {
    final status = response.statusCode;
    if (status == 429) throw const MediaExtractionException('RATE_LIMITED', 'YouTube is rate limiting this client.');
    if (status == 404) throw const MediaExtractionException('NOT_FOUND', 'YouTube has no such page.');
    if (status >= 400) throw MediaExtractionException('NETWORK', 'YouTube answered HTTP $status.');
    final bytes = <int>[];
    await for (final chunk in response.timeout(_timeout)) {
      bytes.addAll(chunk);
      if (bytes.length > _maxBytes) throw const MediaExtractionException('PARSE_ERROR', 'The response is too large.');
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  @override
  void close() => _client.close(force: true);
}
