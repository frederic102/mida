/// Data-only description of an InnerTube client configuration. Kept as
/// plain data (no request logic) so adding a new fallback client, or
/// reacting to YouTube blocking one, is a one-file change.
class InnertubeClient {
  final String clientName;
  final String clientVersion;
  final String userAgent;
  final String xYoutubeClientName;
  final String osName;
  final String osVersion;
  final String? deviceMake;
  final String? deviceModel;
  final int? androidSdkVersion;

  const InnertubeClient({
    required this.clientName,
    required this.clientVersion,
    required this.userAgent,
    required this.xYoutubeClientName,
    required this.osName,
    required this.osVersion,
    this.deviceMake,
    this.deviceModel,
    this.androidSdkVersion,
  });

  /// Builds the `context.client` object for the `/youtubei/v1/player`
  /// request body.
  Map<String, dynamic> buildClientContext({String? visitorData}) {
    return {
      'clientName': clientName,
      'clientVersion': clientVersion,
      if (deviceMake != null) 'deviceMake': deviceMake,
      if (deviceModel != null) 'deviceModel': deviceModel,
      'userAgent': userAgent,
      'osName': osName,
      'osVersion': osVersion,
      if (androidSdkVersion != null) 'androidSdkVersion': androidSdkVersion,
      'hl': 'en',
      'timeZone': 'UTC',
      'utcOffsetMinutes': 0,
      if (visitorData != null) 'visitorData': visitorData,
    };
  }
}

/// Primary client. No JS runtime required, and per the 2026-09-05 spike
/// (`docs/spikes/youtube_visionos_spike.dart`) returns direct adaptive
/// format URLs for 144p-2160p.
const visionosClient = InnertubeClient(
  clientName: 'VISIONOS',
  clientVersion: '1.02',
  userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15',
  xYoutubeClientName: '101',
  osName: 'visionOS',
  osVersion: '26.5.23O471',
  deviceMake: 'Apple',
  deviceModel: 'RealityDevice17,1',
);

/// Fallback for videos visionOS cannot play (e.g. "Made for Kids"). Only
/// returns a muxed 360p (itag 18) direct URL.
const androidClient = InnertubeClient(
  clientName: 'ANDROID',
  clientVersion: '21.26.364',
  userAgent: 'com.google.android.youtube/21.26.364 (Linux; U; Android 11) gzip',
  xYoutubeClientName: '3',
  osName: 'Android',
  osVersion: '11',
  androidSdkVersion: 30,
);
