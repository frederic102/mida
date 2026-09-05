# MiDa v2.0 Phase 2c - 범용 추출기 (모든 사이트) 계약

작성 2026-09-05. 유저 오더: "그 어떤 플랫폼의 동영상도 다 다운받을 수 있어야 해."
전용 추출기 (YouTube/X/TikTok/Instagram) 가 못 잡는 URL 은 전부 이 추출기가 받는다.
상위 문서: `plan-native-extractor.md`, `plan-phase2-extractors.md`.

## INTENT

사이트별 코드 없이, 페이지 안의 미디어 주소 (직접 mp4/webm, HLS m3u8, DASH mpd) 를
찾아 받는다. 사이트가 JS 로만 그리는 경우 시스템 브라우저 (Edge/Chrome 헤드리스) 로
렌더링한 DOM 을 다시 훑는다. DRM (Widevine/PlayReady/FairPlay) 은 받을 수 없으니 그렇게
말한다 (yt-dlp 도 동일).

## 탐지 순서 (첫 성공에서 멈춘다)

0. 입력 URL 자체가 미디어인가: 확장자 `.mp4 .webm .mkv .mov .m4v .m3u8 .mpd .mp3 .m4a`
   또는 HEAD/GET 의 Content-Type 이 `video/*`, `audio/*`, `application/vnd.apple.mpegurl`,
   `application/x-mpegURL`, `application/dash+xml` 이면 바로 포맷 1개.
1. 플레인 HTTP GET (Chrome 데스크톱 UA, Accept-Language en) 후 HTML 스니핑:
   - `<video src>` / `<video><source src type>` (상대경로는 페이지 기준으로 절대화)
   - `<meta property="og:video" | og:video:url | og:video:secure_url | twitter:player:stream">`
   - JSON-LD `<script type="application/ld+json">` 의 `VideoObject.contentUrl` (배열/
     `@graph` 중첩 포함), `embedUrl` 은 무시
   - HTML 과 인라인 `<script>` 텍스트에서 정규식으로 `https?://[^"' <>\\]+\.(m3u8|mpd|mp4|webm)(\?[^"' <>\\]*)?`
     (JSON 이스케이프 `\/` 복원, HTML 엔티티 `&amp;` 복원). 중복 제거. 광고/트래커 도메인
     휴리스틱 없음 (단순 유지). 같은 확장자 여러 개면 전부 포맷으로 노출.
   - 제목: og:title > `<title>` > URL 마지막 세그먼트. 썸네일: og:image. 길이: 없으면 null.
2. 1 에서 아무것도 없으면 `BrowserPageFetcher` (Phase 2 문서의 헤드리스 DOM 덤프) 로
   렌더링된 DOM 을 받아 1 의 스니핑을 반복. 브라우저 없으면 그 사실을 에러에 명시.
3. 그래도 없으면: DRM 흔적 (`widevine`, `playready`, `fairplay`, `encrypted-media`,
   `EME`, `license_url`) 이 있으면 `DRM_PROTECTED`, 아니면 `NO_MEDIA_FOUND`
   (what/why/next: "No video found on this page. The site may load video only after
   sign-in or interaction. Try the direct video URL if you have it.").

## 포맷 모델

- 직접 파일: `MediaFormat(container: 확장자, hasVideo/hasAudio: 확장자 기준 추정,
  protocol: 'https')`.
- HLS: `protocol: 'hls'`, url = m3u8. 마스터 플레이리스트면 GET 해서 `#EXT-X-STREAM-INF`
  의 `RESOLUTION`, `BANDWIDTH` 로 변형별 포맷을 만든다 (height, bitrate 채움). 미디어
  플레이리스트면 포맷 1개.
- DASH: `protocol: 'dash'`, url = mpd, 포맷 1개 (변형 파싱은 스코프 밖).
- `MediaFormat.protocol` 필드는 Phase 2b 에서 추가된다 (기본값 'https'). 이 계약의 구현자는
  `media_models.dart` 에 그 필드가 아직 없으면 **추가해도 된다** (optional, 기본값
  'https', 기존 생성자 호출 깨지지 않게).

## 다운로드 (Phase 2b 파이프라인 연결 시 규칙, 여기서는 포맷만 만든다)

- `protocol == 'https'`: 기존 StreamDownloader.
- `protocol == 'hls' | 'dash'`: ffmpeg `-i <url> -c copy -bsf:a aac_adtstoasc <out.mp4>`
  (UA/Referer 는 `-user_agent`, `-headers`). 진행률은 ffmpeg `-progress pipe:1` 의
  `out_time_ms` / duration.

## SCOPE

- `lib/core/extractors/generic/generic_extractor.dart` (오케스트레이션, canHandle 은
  http/https 전부 true. registry 에서는 항상 마지막).
- `lib/core/extractors/generic/html_media_sniffer.dart` (순수 함수: HTML + baseUrl ->
  후보 URL 목록 + 메타).
- `lib/core/extractors/generic/hls_playlist_parser.dart` (순수 함수).
- `lib/core/extractors/generic/media_url_probe.dart` (0단계 Content-Type 판별).
- `BrowserPageFetcher` 는 Phase 2 계약의 것을 쓴다. 아직 없으면 이 계약에서 만든다
  (`lib/core/services/browser_page_fetcher.dart`, 그 문서의 스펙 그대로).
- 테스트: 스니퍼에 HTML fixture 6종 (video src 상대경로 / og:video / JSON-LD 배열 /
  script 안 이스케이프된 m3u8 / 아무것도 없음 / DRM 흔적). HLS 마스터 파싱 fixture.
  0단계 probe 는 로컬 HttpServer 로 Content-Type 응답. 라이브 (`MIDA_LIVE=1`):
  `https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8` (공개 HLS 테스트 스트림, 변형 여러
  개), `https://www.w3schools.com/html/mov_bbb.mp4` (직접 파일), 그리고 Vimeo 공개 영상
  1개 (`https://vimeo.com/76979871`) 는 2단계 (브라우저) 경로 통과 여부만 기록 (실패해도
  라이브 테스트는 skip 처리, 결과를 보고서에).

## OUT OF SCOPE

DASH 변형 파싱, 로그인 사이트, CDP 네트워크 캡처 (Phase 2d 후보), 사이트별 특수 처리.

## DONE

analyze error 0 / 테스트 그린 + 가드 실패 증명 (스니퍼가 트래커 URL 이 아니라 실제
확장자 URL 만 잡는 것) / 라이브 2개 그린 / 400줄 / emdash 없음.
