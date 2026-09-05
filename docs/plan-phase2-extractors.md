# MiDa v2.0 Phase 2 - X / TikTok / Instagram 네이티브 추출기 (계약)

작성 2026-09-05. 상위 문서: `plan-native-extractor.md` (Phase 1, YouTube). 이 문서는 Phase 2.
리서치 원문: `extractor-research.md` (X 검증 결과는 그대로 유효. TikTok "PARTIAL" 과
Instagram "NOT WITHOUT TLS" 판정은 리드 스파이크로 뒤집혔다. 아래 실측이 우선한다).

## INTENT

X, TikTok, Instagram 공개 영상 포스트를 yt-dlp 없이 받는다. yt-dlp 삭제는 Phase 3.

## 실측 근거 (2026-09-05, 리드 직접)

### X (Twitter)
- `GET https://cdn.syndication.twimg.com/tweet-result?id=<id>&token=<token>`,
  헤더 `User-Agent: Googlebot` 만. 인증/쿠키 없음. HTTP 200 JSON.
- token = `((id / 1e15) * PI).toString(36)` 에서 `0` 과 `.` 문자를 전부 제거.
  예: id 719944021058060289 -> `1qtrrnvqpw`. (Dart: double 연산 후 base36 변환을 직접
  구현. 정수부/소수부 모두 36진수. JS `Number.prototype.toString(36)` 과 동일 결과여야
  하며 위 예시가 단위 테스트 기준값.)
- JSON: `mediaDetails[].video_info.variants[]` (`content_type` video/mp4 인 것만,
  `bitrate`, `url`), `mediaDetails[].media_url_https` (썸네일), `video_info.duration_millis`,
  `text` (제목), `user.screen_name`. `mediaDetails` 없으면 카드/외부 플레이어 트윗이라
  미지원 에러 (무엇/왜/다음).
- 1280x720 mp4 Range GET -> 206. 스트림에 추가 헤더 불필요.

### TikTok
- `GET https://www.tiktok.com/@<user>/video/<id>` (Chrome 데스크톱 UA, Accept,
  Accept-Language). 첫 응답은 1.4KB 챌린지 페이지 (`id="cs"` 엘리먼트, class 속성 =
  base64 JSON `{v:{a:<b64 seed>, c:<b64 digest>}, ...}`).
- 풀이: `sha256(base64decode(a) + ascii(i))` 가 `base64decode(c)` 와 같은 i 를
  0..1,000,000 에서 탐색 (실측 i=73, 8ms). `challenge['d'] = base64(ascii(i))` 를 넣고
  JSON 을 base64 로 인코딩한 값을 쿠키 이름 `id="wci"` 엘리먼트의 class (실측
  `_wafchallengeid`) 로, `id="rci"` class 를 이름 + `id="rs"` class 를 값으로 하는 두 번째
  쿠키 (실측 `waforiginalreid`) 와 함께 붙여 같은 URL 재요청.
- 두 번째 응답 427KB, `<script id="__UNIVERSAL_DATA_FOR_REHYDRATION__">` JSON.
  `__DEFAULT_SCOPE__["webapp.video-detail"]`: `statusCode` (0 정상, 10216/10222 비공개,
  10204 IP 차단), `itemInfo.itemStruct`: `desc`, `video.duration`, `video.cover`,
  `video.bitrateInfo[]` {`Bitrate`, `PlayAddr`{`UrlList[]`, `Width`, `Height`, `UrlKey`,
  `DataSize`}}, 폴백 `video.playAddr`. 전부 muxed mp4 (병합 불필요).
- 스트림 GET: UA + `Referer: https://www.tiktok.com/` + 세션 쿠키 전부 -> 206 video/mp4.
- 참고 구현: `docs/spikes/tiktok_pow_spike.dart`.
- 단축 URL (`vm.tiktok.com/<code>`, `tiktok.com/t/<code>`) 은 리다이렉트 따라가서 정식
  URL 확보 후 진행. 사진 포스트 (`/photo/`) 미지원 에러.

### Instagram
- 순수 HTTP 는 전부 618KB SPA 셸 (TLS 지문 차단). yt-dlp 도 curl_cffi 위장 없으면 못 함.
- 해결: **시스템 브라우저 헤드리스 DOM 덤프**. Windows 11 은 Edge 기본 탑재.
  `msedge.exe --headless=new --disable-gpu --no-first-run --no-default-browser-check
  --user-data-dir=<고유 임시 폴더> --dump-dom <post url>` -> stdout 760KB HTML,
  `"video_versions":[{"type":101,"url":"https:\/\/scontent-...mp4?..."},...]` 포함
  (JSON 이스케이프 `\/` 와 `&` 복원 필요). Range GET -> 206 video/mp4.
- 같은 DOM 에 `xig_polaris_media` 블롭: `caption.text`, `image_versions2.candidates[0].url`,
  `video_duration`, `owner.username`. 캐러셀은 첫 번째 영상만 (그 외 미지원 메시지).
- 브라우저 탐색 순서: Windows `%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe`,
  `%ProgramFiles%\Microsoft\Edge\Application\msedge.exe`, `%ProgramFiles%\Google\Chrome\
  Application\chrome.exe`, `%LOCALAPPDATA%\Google\Chrome\Application\chrome.exe`.
  macOS `/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge`,
  `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`. 없으면 에러:
  "Instagram downloads need Microsoft Edge or Google Chrome installed." (무엇/왜/다음).
- 타임아웃 60초 후 프로세스 kill. 임시 프로필 폴더는 finally 에서 삭제.

## SCOPE

### 1. 공통

- `lib/core/extractors/media_extractor.dart` 의 `MediaExtractor` / `ExtractorRegistry` 재사용.
  `MediaInfo.requestHeaders` 에 스트림 요청 헤더 (TikTok: UA, Referer, Cookie) 를 담는다.
- `lib/core/services/browser_page_fetcher.dart`: 실행파일 탐색 + 헤드리스 DOM 덤프.
  `Process.run` 인자 리스트 (셸 금지). 실행파일 경로/탐색 함수는 주입 가능 (테스트).
- 네트워크는 dart:io HttpClient, 주입 가능. 새 pub 의존성 금지 (`crypto` 는 이미 있음).

### 2. 추출기 (플랫폼당 폴더, 파일 400줄 이하)

- `lib/core/extractors/twitter/twitter_extractor.dart` + `syndication_token.dart`
  + `twitter_response_parser.dart`.
- `lib/core/extractors/tiktok/tiktok_extractor.dart` + `tiktok_challenge_solver.dart`
  + `tiktok_page_parser.dart`.
- `lib/core/extractors/instagram/instagram_extractor.dart` + `instagram_dom_parser.dart`.
- URL 판별은 `url_parser.dart` 의 `PlatformType` 에 맞춘다 (host 는 exact/suffix 매치,
  Phase 1 수정과 동일 규칙). X: `twitter.com`, `x.com`, `mobile.twitter.com`, 경로
  `/<user>/status/<id>` 또는 `/i/status/<id>`. TikTok: `tiktok.com`, `vm.tiktok.com`,
  `vt.tiktok.com`. Instagram: `instagram.com` 경로 `/p/`, `/reel/`, `/reels/`, `/tv/`.
- 모든 실패는 `MediaExtractionException(code, message)` 로 (what/why/next, 영어,
  느낌표 없음). 코드: UNSUPPORTED_URL, NOT_FOUND, PRIVATE, RATE_LIMITED, CHALLENGE_FAILED,
  BROWSER_MISSING, PARSE_ERROR, NETWORK.

### 3. 만지지 말 것 (Phase 1 레인이 동시에 수정 중)

`lib/features/download/services/*.dart`, `lib/core/download/*.dart`,
`lib/core/extractors/youtube/**`, `lib/core/extractors/format_selector.dart`,
`lib/core/utils/file_utils.dart`, `test/live/lead_pipeline_live_test.dart`.
`url_parser.dart` 는 **읽기만**. 필요한 URL 파싱은 각 추출기 폴더 안에 둔다 (Phase 2b
에서 통합). 등록 (registry 에 추가) 도 Phase 2b.

### 4. 테스트

- `syndication_token`: 719944021058060289 -> `1qtrrnvqpw`, 그리고 두 개 더 (구현자가
  `node -e` 로 기준값 생성해 테스트에 박고 명령을 주석으로 남긴다).
- `tiktok_challenge_solver`: 합성 챌린지 (seed 임의, i=4242 로 digest 생성) 를 풀어
  4242 반환, 상한 초과 시 CHALLENGE_FAILED. 쿠키 조립 (이름 추출, base64 JSON, rci 유무).
- 파서 3종: 라이브 응답 fixture (`test/fixtures/twitter_syndication.json`,
  `tiktok_universal_data.json`, `instagram_dom_excerpt.html`; 각 200KB 이하로 정리,
  URL 토큰 등 민감값은 실제값 그대로 둬도 됨 (공개 데이터)). 제목/썸네일/길이/포맷
  수/최고 비트레이트 검증. 카드 트윗 / 사진 포스트 / 비공개 statusCode 의 에러 매핑.
- `browser_page_fetcher`: 가짜 실행파일 (임시 .bat 이 HTML echo) 로 인자 조립 + 출력
  수집 + 프로필 폴더 삭제 검증, 실행파일 없음 -> BROWSER_MISSING, 타임아웃 -> kill 후
  NETWORK. **guard must be able to fail**: 프로필 삭제 finally 를 제거하면 빨개지는 것 증명.
- 라이브 (`MIDA_LIVE=1`, `test/live/phase2_live_test.dart`): X
  `https://twitter.com/captainamerica/status/719944021058060289`, TikTok
  `https://www.tiktok.com/@hankgreen1/video/7047596209028074758`, Instagram
  `https://www.instagram.com/reel/Chunk8-jurw/`. 각각 extract -> 포맷 1개 이상 -> 첫
  포맷 Range 0-1023 GET 206.

## OUT OF SCOPE (Phase 2)

registry 등록/파이프라인 연결 (Phase 2b), yt-dlp 삭제 (Phase 3), 로그인/쿠키 가져오기,
캐러셀 전체, 스토리/라이브, 플레이리스트, TikTok 사진, X 카드 플레이어, 자막.

## DONE 기준

1. analyze error 0 (info 는 기존 56 이하). 2. `flutter test` 그린 + 가드 실패 증명.
3. `MIDA_LIVE=1 flutter test test/live/phase2_live_test.dart` 3/3 그린.
4. `flutter build windows --release` 성공. 5. 400줄/emdash/이모지/회사정보 규칙.
