import 'dart:convert';
import 'dart:io';

import '../media_models.dart';

/// Starts a Niconico DMC/DMS playback session
/// (`POST api.dmc.nico/api/sessions?_format=json`) from the `session_api`
/// object [NiconicoWatchDataParser] reads out of the watch page, and
/// returns the `content_uri` (an HLS or MP4 URL) the response carries.
///
/// Best-effort, not live-confirmed (`docs/plan-phase5-coverage.md` Lane D
/// report - see `NiconicoWatchDataParser`'s doc for why: the legacy page
/// shape this reads from was not observed on the current live site within
/// this pass's budget). The request body shape here matches the
/// long-documented DMC session contract; field names/required nesting
/// may have drifted since - flagged as the lowest-confidence piece of
/// this pass's Niconico support, a priority follow-up once the current
/// site's `nvapi.nicovideo.jp` auth requirement is understood.
///
/// Deliberately does not implement the periodic heartbeat POST a DMC
/// session needs to stay alive for a long download (`heartbeat_lifetime`
/// in the response, typically ~2 minutes) - out of scope for a first
/// pass; a short clip download can finish inside one lifetime window, a
/// long one currently cannot and needs that follow-up.
class NiconicoDmcSessionClient {
  final HttpClient Function() _httpClientFactory;

  /// Rewrites the session-create endpoint URL. Identity by default; tests
  /// point it at a local `HttpServer`.
  final Uri Function(Uri url) _requestUrlBuilder;

  NiconicoDmcSessionClient({
    HttpClient Function()? httpClientFactory,
    Uri Function(Uri url)? requestUrlBuilder,
  })  : _httpClientFactory = httpClientFactory ?? HttpClient.new,
        _requestUrlBuilder = requestUrlBuilder ?? _identity;

  static Uri _identity(Uri url) => url;

  static const _defaultEndpoint = 'https://api.dmc.nico/api/sessions?_format=json';

  /// Throws [MediaExtractionException] (`UNSUPPORTED_MEDIA`) when
  /// [sessionApi] is missing a field this needs to build a request at
  /// all, and (`NETWORK`/`PARSE_ERROR`) for transport/decode failures.
  Future<String> startSession(Map<String, dynamic> sessionApi) async {
    final videos = sessionApi['videos'];
    final audios = sessionApi['audios'];
    final contentId = sessionApi['contentId'] ?? sessionApi['content_id'];
    final token = sessionApi['token'];
    final signature = sessionApi['signature'];
    if (videos is! List || videos.isEmpty || contentId == null || token == null || signature == null) {
      throw const MediaExtractionException(
        'UNSUPPORTED_MEDIA',
        'This Niconico video\'s session data is missing fields MiDa needs '
            'to start playback.',
      );
    }

    final requestBody = {
      'session': {
        'recipe_id': sessionApi['recipeId'] ?? sessionApi['recipe_id'],
        'content_id': contentId,
        'content_type': 'movie',
        'content_src_id_sets': [
          {
            'content_src_ids': [
              {
                'src_id_to_mux': {
                  'video_src_ids': videos,
                  'audio_src_ids': audios is List ? audios : const [],
                },
              },
            ],
          },
        ],
        'timing_constraint': 'unlimited',
        'keep_method': {
          'heartbeat': {'lifetime': sessionApi['heartbeatLifetime'] ?? sessionApi['heartbeat_lifetime'] ?? 120000},
        },
        'protocol': {
          'name': 'http',
          'parameters': {
            'http_parameters': {
              'parameters': {
                'http_output_download_parameters': {
                  'use_well_known_port': 'yes',
                  'use_ssl': 'yes',
                },
              },
            },
          },
        },
        'content_uri': '',
        'session_operation_auth': {
          'session_operation_auth_by_signature': {'token': token, 'signature': signature},
        },
        'content_auth': {
          'auth_types': {'http': 'ht2'},
          'service_id': 'nicovideo',
          'service_user_id': sessionApi['serviceUserId'] ?? sessionApi['service_user_id'] ?? '',
        },
        'client_info': {'player_id': sessionApi['playerId'] ?? sessionApi['player_id'] ?? ''},
        'priority': sessionApi['priority'] ?? 0,
      },
    };

    final httpClient = _httpClientFactory();
    try {
      final request = await httpClient.postUrl(_requestUrlBuilder(Uri.parse(_defaultEndpoint)));
      request.headers.set('Content-Type', 'application/json');
      request.add(utf8.encode(jsonEncode(requestBody)));
      final response = await request.close();
      final raw = await response.transform(utf8.decoder).join();

      if (response.statusCode != 200 && response.statusCode != 201) {
        throw MediaExtractionException(
          'NETWORK',
          'Niconico returned HTTP ${response.statusCode} while starting playback.',
        );
      }

      final Map<String, dynamic> json;
      try {
        json = jsonDecode(raw) as Map<String, dynamic>;
      } on FormatException {
        throw const MediaExtractionException(
          'PARSE_ERROR',
          'Niconico returned a response MiDa could not read as JSON.',
        );
      }

      final responseData = json['data'];
      final session = responseData is Map ? responseData['session'] : null;
      final contentUri = session is Map ? session['content_uri'] as String? : null;
      if (contentUri == null) {
        throw const MediaExtractionException(
          'PARSE_ERROR',
          'Niconico did not return a playable stream URL for this session.',
        );
      }
      return contentUri;
    } finally {
      httpClient.close(force: true);
    }
  }
}
