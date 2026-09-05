# MiDa v2.0 Phase 2d - 브라우저 네트워크 캡처 추출기 (계약)

작성 2026-09-05. 목적: "어떤 사이트든" 을 실제로 만족시키는 마지막 그물. 범용 추출기
(Phase 2c) 가 정적 DOM 스니핑으로 못 잡는 경우 (JS 챌린지 후 로드되는 페이지, iframe
플레이어, XHR 로 받아오는 매니페스트) 를 잡는다. 실측: TikTok 과 Vimeo 는 2c 로 실패,
Instagram 은 2c 로 URL 은 잡히나 브라우저 세션 쿠키가 있어야 안전하다.

## 원리

시스템 브라우저 (Edge/Chrome) 를 `--headless=new --remote-debugging-port=<빈 포트>` 로
띄우고 Chrome DevTools Protocol (CDP) 에 dart:io `WebSocket` 으로 붙는다. 페이지를
로드하는 동안 브라우저가 실제로 요청/응답한 미디어 URL 을 `Network.responseReceived`
이벤트에서 수집한다. 브라우저가 JS 를 다 실행하므로 사이트별 챌린지/플레이어 로직은
브라우저 몫이다. 우리는 결과만 읽는다.

## 시퀀스

1. 실행파일 탐색은 `BrowserPageFetcher` 의 것을 재사용 (같은 파일에 `launchWithDevtools`
   추가 또는 `lib/core/services/browser_devtools_session.dart` 신설).
2. 빈 포트 확보 (`ServerSocket.bind(127.0.0.1, 0)` 후 닫기). 브라우저 실행 인자:
   `--headless=new --disable-gpu --no-first-run --no-default-browser-check
   --user-data-dir=<고유 임시> --remote-debugging-port=<port> --mute-audio
   --autoplay-policy=no-user-gesture-required about:blank`.
3. `http://127.0.0.1:<port>/json/version` 을 폴링 (최대 10초, 200ms 간격) 해서
   `webSocketDebuggerUrl` 획득. 연결 후 `Target.createTarget {url: about:blank}` ->
   `Target.attachToTarget {targetId, flatten: true}` -> sessionId 로 `Network.enable`,
   `Page.enable`, `Runtime.enable`, 그리고 `Network.setUserAgentOverride` 는 하지 않는다
   (실제 브라우저 UA 유지).
4. `Page.navigate {url}`. 이후 최대 20초 동안 이벤트 수집:
   - `Network.responseReceived`: `response.mimeType` 이 `video/*`, `audio/*`,
     `application/vnd.apple.mpegurl`, `application/x-mpegurl`, `application/dash+xml`,
     `application/octet-stream` 이면서 URL 에 `.mp4|.m3u8|.mpd|.webm|.m4s` 가 있는 것,
     또는 URL 경로/쿼리에 `.m3u8`/`.mpd` 가 있는 것. 각 항목: url, mimeType, 요청
     헤더 (`Network.requestWillBeSent` 의 `request.headers` 에서 Referer/Origin/UA),
     `response.headers` 의 content-length.
   - `Page.loadEventFired` 후 3초 더 기다리고, 그 시점까지 미디어가 0개면 `Runtime.evaluate`
     로 `document.querySelector('video')?.play()` 를 시도하고 5초 더 수집 (자동재생
     차단 대비). 그래도 0개면 `Runtime.evaluate document.documentElement.outerHTML` 로
     DOM 을 받아 Phase 2c 의 `HtmlMediaSniffer` 로 한 번 더 훑는다.
5. `Network.getCookies {urls: [page url, media urls]}` 로 쿠키 수집 ->
   `MediaInfo.requestHeaders` 에 `Cookie`, `Referer` (page url), `User-Agent` (브라우저
   `Browser.getVersion` 의 userAgent) 를 넣는다.
6. 제목: `Runtime.evaluate document.title` (og:title 우선). 썸네일: og:image.
7. `Browser.close` 후 프로세스 kill 보장, 임시 프로필 삭제 (finally).

## 포맷 규칙

- `.m3u8`: 마스터면 Phase 2c 의 `HlsPlaylistParser` 로 변형 확장 (요청 헤더를 붙여서
  GET). 미디어 플레이리스트면 1개. `.m4s`/세그먼트 URL 은 포맷으로 만들지 않는다
  (그 매니페스트를 찾는 단서로만).
- `.mpd`: 1개. `.mp4`/`.webm` 직접: 1개씩 (같은 파일의 Range 조각 요청은 URL 에서
  `range=`/`bytes=` 쿼리를 떼고 dedupe).
- 후보가 여러 개면 전부 노출하고 정렬은 파이프라인의 FormatSelector 몫.

## 배치

`ExtractorRegistry` 에서 순서: 전용 추출기들 -> Generic (2c) -> **BrowserCapture (2d)**.
단, 2c 가 `NO_MEDIA_FOUND` 를 던지면 2d 로 넘기는 체인은 Phase 2b 배선에서 한다.
이 계약에서는 `BrowserCaptureExtractor implements MediaExtractor` 만 만든다
(`canHandle` 은 http/https 전부).

## SCOPE / 파일

- `lib/core/services/browser_devtools_session.dart` (CDP 클라이언트: 실행, 연결, send/await
  by id, 이벤트 스트림, 타임아웃, 종료). 400줄 넘으면 `cdp_client.dart` 분리.
- `lib/core/extractors/browser_capture/browser_capture_extractor.dart`,
  `captured_media_classifier.dart` (순수 함수: (url, mimeType) -> 후보/무시).
- 테스트: classifier 표 (mp4/m3u8/mpd/m4s/png/js/octet-stream+mp4), 요청 dedupe (range
  쿼리 제거), CDP 클라이언트는 로컬 `HttpServer` + `WebSocketTransformer` 로 가짜
  DevTools 엔드포인트를 띄워 handshake/이벤트/타임아웃 검증 (실제 브라우저 없이).
  가드 실패 증명: 타임아웃 시 프로세스 kill + 프로필 삭제.
- 라이브 (`MIDA_LIVE=1`, `test/live/browser_capture_live_test.dart`):
  `https://vimeo.com/76979871`, `https://www.tiktok.com/@hankgreen1/video/7047596209028074758`,
  `https://www.instagram.com/reel/Chunk8-jurw/`. 각각 포맷 1개 이상 + 첫 포맷 Range GET
  (requestHeaders 포함) 206 또는 200. 셋 중 하나라도 실패하면 그 사이트 이름과 원인을
  보고서에 (테스트는 그 사이트만 skip 처리 아님, 실패로 남긴다).

## OUT OF SCOPE

DRM, 로그인, 무한 스크롤 페이지, 여러 영상 중 선택 UI (첫 영상 또는 전체 노출 후
FormatSelector).

## DONE

analyze error 0 / 테스트 그린 + 가드 증명 / 라이브 3사이트 결과 보고 / 400줄 / emdash 없음.
