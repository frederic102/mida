# MiDa v2.0 Phase 2b - 추출기 통합 배선 (계약, 초안)

작성 2026-09-05. Phase 1 (YouTube), Phase 2 (X), Phase 2c (범용) 의 추출기를 한 파이프라인에
연결한다. 이 문서는 각 레인 보고서의 "Phase 2b 요청" 을 받아 최종 확정한다.

## INTENT

URL 하나 -> `ExtractorRegistry` 가 추출기 선택 -> 공통 `MediaDownloadPipeline` 이
포맷 선택/다운로드/병합/자막 -> 파일. yt-dlp 경로는 이 단계에서 **호출되지 않게** 만들고
(코드 삭제는 Phase 3), 모든 플랫폼이 네이티브 경로를 탄다.

## SCOPE (확정분)

1. `media_models.dart`: `MediaFormat.protocol` (String, 기본 'https', 'hls' | 'dash').
2. `ExtractorRegistry` 구성 (한 곳, `lib/core/extractors/extractor_registry_builder.dart`):
   순서 YouTube -> Twitter -> (TikTok, Instagram 이 있으면) -> Generic (항상 마지막).
3. `YoutubeDownloadPipeline` -> `MediaDownloadPipeline` 로 일반화 (파일명도 변경).
   입력은 `MediaInfo` 만. YouTube 전용 가정 제거 (자막 tlang 은 captions 가 있을 때만).
   HLS/DASH 포맷은 ffmpeg 로 받는다 (`-user_agent`, `-headers "Referer: ..."`,
   `-i url -c copy -bsf:a aac_adtstoasc out.mp4`, 오디오 전용이면 `-vn` + 코덱 변환).
   진행률: ffmpeg `-progress pipe:1` 의 `out_time_ms` / `MediaInfo.duration`.
4. `download_service_io.dart`: `fetchVideoInfo` 와 `download` 는 registry 만 사용.
   추출기 없음 (registry null) 은 이론상 불가 (Generic 이 전부 받음).
   `ytdlp_legacy_download_backend.dart` 는 호출부 제거 (파일은 Phase 3 에서 삭제).
5. `url_parser.dart`: 각 추출기 폴더의 URL 파싱을 여기로 합치거나, 반대로
   `PlatformType` 판별을 registry 의 `canHandle` 로 대체 (UI 의 플랫폼 아이콘 표시용
   `detectPlatform` 은 유지).
6. 테스트: registry 순서 (같은 URL 을 Generic 과 YouTube 둘 다 받을 때 YouTube 선택),
   HLS 포맷의 ffmpeg 인자 빌더, 진행률 파서 (`out_time_ms` 라인), 서비스 라우팅
   (가짜 registry 로 fetchVideoInfo/download 가 yt-dlp 를 절대 호출하지 않음: 가짜 legacy
   backend 가 호출되면 실패하는 테스트).
7. 라이브 (`MIDA_LIVE=1`): YouTube 1080p mp4 + ko 자막, X mp4, HLS 테스트 스트림 mp4
   (`https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8`), 직접 mp4 URL. 각각 ffprobe 로
   스트림 확인.

## 레인 보고서 반영 (확정)

- Phase 1: `download_service_io.dart` 는 이미 MediaInfo 를 한 번만 받아 재사용하고
  에러를 what/why/next 로 통일함. `NoDownloadableFormatsException` 존재. 자막 tlang 은
  구현됨 (라이브는 429 로 미확인, 코드 경로는 단위 테스트됨).
- X: `TwitterExtractor` (`lib/core/extractors/twitter/`), 에러 코드 `UNSUPPORTED_MEDIA`
  를 "인식된 포스트지만 재생 가능한 것 없음" 공통 코드로 채택. `extractTweetId` 의
  경로 규칙을 `url_parser.dart` 로 승격 (`extractTwitterStatusId`).
- 범용: `GenericExtractor` (`lib/core/extractors/generic/`), 컨테이너는 URL 확장자에서
  추정 (`m3u8`, `mpd`, `mp4`...). `protocol` 필드 추가 시 `container == 'm3u8'` ->
  'hls', `'mpd'` -> 'dash' 로 매핑해 채운다 (생성 지점 한 곳: registry 빌더 또는 파이프
  라인 입구의 normalize 함수).
- 2d (진행 중, 완료 시 추가): `BrowserCaptureExtractor`
  (`lib/core/extractors/browser_capture/`). 존재하면 registry 마지막에 등록하고, Generic 이
  `NO_MEDIA_FOUND` 를 던지면 2d 로 넘기는 체인을 registry 빌더가 아니라 파이프라인
  `resolveInfo(url)` 에서 처리한다. 파일이 아직 없으면 그 자리에 명확한 TODO 한 줄과
  빈 훅 (`List<MediaExtractor> fallbacks`) 만 둔다.

## OUT OF SCOPE

yt-dlp 코드/바이너리 삭제와 인스톨러 (Phase 3), 취소 UI, 재생목록.
