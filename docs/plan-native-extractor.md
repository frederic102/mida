# MiDa v2.0 - yt-dlp 제거, 네이티브 추출기 (오더 다이제스트)

작성 2026-09-05. 오더: "yt-dlp 의존성 제거. 새 아키텍처. 방법을 찾아라."
이 문서가 계약이다. 이전 문서 `plan-ytdlp-auto-update.md` (A안) 는 폐기 예정.
그 산출물 (ytdlp_manager 등) 은 Phase 3 에서 통째로 삭제한다.

## INTENT

MiDa 가 yt-dlp 바이너리 없이, 순수 Dart (dart:io) 로 플랫폼 추출 + 다운로드를 하고
ffmpeg 로 병합/변환한다. ffmpeg 는 유지 (오더에 없음).

## Phase 순서

1. **Phase 1 (이 문서)**: YouTube 네이티브 추출기 + 다운로더 + ffmpeg 병합. YouTube URL 은
   새 경로, 나머지 플랫폼은 당분간 기존 yt-dlp 경로 유지 (앱이 계속 동작해야 함).
2. Phase 2: X / TikTok / Instagram (별도 계약, `docs/extractor-research.md` 기반).
3. Phase 3: yt-dlp 경로/바이너리/스크립트/자동갱신 코드 전부 삭제, 인스톨러 정리.

## 실측 근거 (2026-09-05, 리드 직접, 재검증 불필요)

- 최신 yt-dlp (2026.08.19) 기본 클라이언트는 `visionos` (JS 런타임 불필요) + `web`.
  tv 클라이언트는 yt-dlp 자체도 "The page needs to be reloaded" 로 죽어 있음. 쓰지 않는다.
- 순수 Dart 로 아래 시퀀스가 3개 영상 (dQw4w9WgXcQ, aqz-KE-bpKQ, kJQP7kiw5Fk) 모두 성공.
  포맷 25-32개, 144p-2160p 직접 URL, Range GET 206. 참고 구현:
  `docs/spikes/youtube_visionos_spike.dart` (그대로 옮기지 말고 구조화해서 구현).
- 시퀀스:
  1. `GET https://www.youtube.com/watch?v=<id>` (UA 는 아래 visionos UA, `Accept-Language:
     en-us,en;q=0.5`, `Cookie: SOCS=CAI; PREF=hl=en&tz=UTC`). 응답 Set-Cookie 전부 수집
     (VISITOR_INFO1_LIVE, YSC, __Secure-* 등). HTML 에서 `"visitorData":"..."` 추출.
     **이 단계 없이 player 를 치면 2/3 확률로 봇체크 (LOGIN_REQUIRED) 에 걸린다.**
  2. `POST https://www.youtube.com/youtubei/v1/player?prettyPrint=false`
     헤더: Content-Type application/json, User-Agent (visionos UA), X-YouTube-Client-Name 101,
     X-YouTube-Client-Version 1.02, Origin https://www.youtube.com, Accept-Language,
     Cookie (1단계 수집 전부), X-Goog-Visitor-Id (visitorData).
     바디:
     `{"context":{"client":{"clientName":"VISIONOS","clientVersion":"1.02",
     "deviceMake":"Apple","deviceModel":"RealityDevice17,1","userAgent":<UA>,
     "osName":"visionOS","osVersion":"26.5.23O471","hl":"en","timeZone":"UTC",
     "utcOffsetMinutes":0,"visitorData":<vd>}},"videoId":<id>,
     "playbackContext":{"contentPlaybackContext":{"html5Preference":"HTML5_PREF_WANTS"}},
     "contentCheckOk":true,"racyCheckOk":true}`
     visionos UA (정확히 이 값):
     `Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15`
  3. 응답 `playabilityStatus.status == OK` 확인. `streamingData.formats` (muxed) +
     `streamingData.adaptiveFormats` (DASH) 의 각 항목: itag, url, mimeType
     (`video/mp4; codecs="avc1.640028"` 형식), width, height, fps, bitrate,
     averageBitrate, contentLength, audioQuality, approxDurationMs. `videoDetails`:
     title, lengthSeconds, thumbnail.thumbnails[].url (최대 해상도 선택), author.
     `captions.playerCaptionsTracklistRenderer.captionTracks[]`: baseUrl, languageCode,
     kind ("asr" = 자동자막).
  4. 스트림 GET: 같은 UA, `Range: bytes=a-b` 로 10MB 청크 순차 (yt-dlp 도 youtube 는
     청크 다운로드). 응답 206.
- 폴백 (visionos 가 OK 가 아닐 때, 순서대로):
  a. 세션 새로 만들어 (1단계부터) 1회 재시도.
  b. `android` 클라이언트: clientName ANDROID, clientVersion 21.26.364, androidSdkVersion 30,
     osName Android, osVersion 11, UA `com.google.android.youtube/21.26.364 (Linux; U;
     Android 11) gzip`, X-YouTube-Client-Name 3. 직접 URL 은 itag 18 (360p muxed) 만 나옴.
     "Made for kids" 등 visionos 불가 영상용.
  c. 전부 실패 시 유저 에러: 무엇 (이 영상을 가져오지 못함) / 왜 (YouTube 응답 status
     + reason 그대로) / 다음 (URL 확인, 잠시 후 재시도).

## SCOPE (Phase 1)

### 1. 추출기 레이어 `lib/core/extractors/`

- `media_extractor.dart`: `abstract class MediaExtractor { bool canHandle(Uri url);
  Future<MediaInfo> extract(Uri url); }` + `ExtractorRegistry` (URL -> 추출기, 없으면 null).
- `media_models.dart`: `MediaInfo` (id, title, author, thumbnailUrl, duration,
  formats, captions, sourceUrl, requestHeaders), `MediaFormat` (id, url, container
  mp4/webm/m4a..., videoCodec?, audioCodec?, width?, height?, fps?, bitrate, contentLength?,
  hasVideo, hasAudio), `CaptionTrack` (languageCode, url, isAuto).
- `youtube/youtube_extractor.dart`: 위 시퀀스. URL 파싱은 기존
  `core/utils/url_parser.dart` 의 `extractYouTubeVideoId` 재사용 (shorts/`youtu.be`/
  `watch?v=` 지원, `/shorts/<id>` 는 url_parser 에 추가).
- `youtube/youtube_session.dart`: 쿠키 수집 + visitorData. HttpClient 는 주입 가능
  (테스트용). dart:io HttpClient 는 쿠키를 자동 관리하지 않으므로 직접 헤더 조립.
- `youtube/innertube_clients.dart`: visionos / android 설정을 데이터로 (문자열 상수 한
  곳). `youtube/player_response_parser.dart`: JSON -> MediaInfo (순수 함수, 테스트 대상).
- `format_selector.dart`: `DownloadOptions` (기존 enum 그대로) -> 선택 결과
  `{video?: MediaFormat, audio?: MediaFormat, muxed?: MediaFormat}`.
  규칙: 목표 컨테이너 mp4 이면 avc1/av01 + mp4a 우선, webm 이면 vp9/av01 + opus, mkv 는
  최고 비트레이트 무관. `height <= 요청` 중 최대. 오디오 전용은 최고 비트레이트 오디오.
  적응형이 없으면 muxed 폴백. 순수 함수, 테스트 대상.

### 2. 다운로더 `lib/core/download/`

- `stream_downloader.dart`: 한 포맷을 파일로. 10MB Range 청크 순차, 청크별 재시도 3회
  (지수 백오프 1s/2s/4s), 진행률 콜백 (received/total), 취소 토큰. contentLength 없으면
  단일 GET. 임시파일 `.part` 로 받고 완료 시 rename.
- `media_merger.dart`: ffmpeg 호출 빌더 + 실행 (기존 `_getFFmpegPath` 로직 재사용해서
  `core/services/ffmpeg_locator.dart` 로 뽑아내고 compress/extract 서비스도 그걸 쓰게
  1줄씩만 바꿈). 케이스: (a) video+audio -> `-c copy` 병합, 컨테이너 mp4/webm/mkv,
  (b) audio -> mp3/m4a/opus/flac/wav 변환 (기존 AudioQuality kbps 매핑: best 는 코덱
  기본, 그 외 `-b:a Nk`), (c) muxed 만 있으면 컨테이너만 맞춤 (`-c copy`, 불가 시 재인코딩
  없이 확장자 유지 + 로그).
- `caption_downloader.dart`: captionTrack.baseUrl + `&fmt=vtt` -> 파일, ffmpeg 로 srt 변환.
  기존 SubtitleOption (none/ko/en/ko,en) 매핑. 요청 언어 없으면 조용히 건너뜀 (실패 아님).

### 3. `download_service_io.dart` 개편

- 공개 API (DownloadOptions/DownloadTask/DownloadStatus/fetchVideoInfo/download/history/
  notifyListeners 패턴) 는 그대로 -> 화면 코드 무수정.
- `fetchVideoInfo`: YouTube 면 `YoutubeExtractor.extract` 로 title/thumbnail/duration.
  아니면 기존 yt-dlp `--dump-json` 경로 (Phase 2 까지 유지).
- `download`: YouTube 면 파이프라인 [extract -> select -> download (진행률: 다운로드 0-90%,
  병합 90-100%) -> merge -> caption], 파일명은 기존 규칙 (`title.ext`, 파일명 불가 문자
  `\ / : * ? " < > |` 를 `_` 로, 기존 FileUtils 에 헬퍼 있으면 재사용). 아니면 기존 경로.
- 파이프라인은 `lib/features/download/services/youtube_download_pipeline.dart` 로 분리
  (400줄 룰). download_service_io.dart 는 라우팅만.
- 취소: DownloadTask 에 cancel 추가는 스코프 밖 (UI 없음). 다운로더 API 에는 토큰만 둔다.

### 4. 테스트 `test/core/extractors/`, `test/core/download/`

- player_response_parser: 실제 응답 fixture 1개 (`test/fixtures/youtube_player_visionos.json`,
  없으면 구현자가 스파이크 스크립트로 받아서 저장, 크기 200KB 이하로 불필요 키 제거)
  -> 포맷 수, 높이 집합, title, duration, captions 파싱 검증. `LOGIN_REQUIRED` /
  `UNPLAYABLE` fixture 로 에러 매핑.
- youtube_session: Set-Cookie 여러 개 -> Cookie 헤더 조립, visitorData 정규식 (없을 때 null).
- format_selector: 1080p mp4 요청 -> avc1 137 + m4a 140 / webm 요청 -> vp9 + opus /
  480p 요청 시 height<=480 최대 / 오디오 전용 / 적응형 없고 muxed 만.
- stream_downloader: 로컬 `HttpServer` 로 Range 지원 서버 띄워 3청크 파일 다운로드 검증,
  1회 500 응답 후 성공하는 재시도 검증, 청크 경계 바이트 일치 (sha256 비교).
  **guard must be able to fail**: 재시도 로직 끄면 빨개지는 것 보고서에 증명.
- media_merger: 인자 빌더 순수 함수 검증 (실제 ffmpeg 실행은 라이브 검증에서).
- url_parser: shorts URL id 추출.
- 라이브 테스트 (`test/live/youtube_live_test.dart`): `MIDA_LIVE=1` 환경변수 있을 때만
  실행. dQw4w9WgXcQ extract -> 포맷 20개 이상, 1080p 존재, 첫 1KB Range 206.

### 5. 문서

- CHANGELOG `[2.0.0-alpha.1]` (Unreleased) "YouTube downloads no longer use yt-dlp".
  버전 bump 는 Phase 3 에서.

## OUT OF SCOPE (Phase 1)

X/TikTok/Instagram 네이티브 / yt-dlp 삭제 / 자동갱신 코드 삭제 / 재생목록 / 라이브
스트림 / DRM / 로그인·쿠키 가져오기 / SABR / JS 챌린지 (web 클라이언트) / 취소 UI /
withOpacity 등 기존 lint info.

## DONE 기준

1. `flutter analyze` error 0, info 는 53 이하.
2. `flutter test` 전부 그린 (라이브 제외). 가드 실패 증명 포함.
3. `MIDA_LIVE=1 flutter test test/live` 그린.
4. `flutter build windows --release` 성공.
5. 리드 라이브 실측: 빌드된 앱에서 YouTube URL 1080p mp4 다운로드 -> ffprobe 로 비디오
   +오디오 스트림 확인 / 오디오 mp3 다운로드 / 자막 ko srt. 이때 `yt-dlp.exe` 를 앱 폴더에서
   지운 상태로 YouTube 가 되는지 확인.
6. 파일 전부 400줄 이하. emdash/이모지 없음. 회사 정보 없음.

## 리스크

- YouTube 가 visionos 도 막으면: innertube_clients.dart 한 파일 + parser 만 고치면 되는
  구조로. 그때 web 클라이언트 + JS 솔버 (QuickJS 내장, `quickjs_engine` 패키지 후보,
  솔버 스크립트는 Unlicense 라 번들 가능) 를 추가한다. 이번엔 안 한다.
- 봇체크는 세션 재생성으로 대부분 풀림 (실측). 같은 IP 과다 요청 시 지속될 수 있음.
