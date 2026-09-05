# MiDa v2.2 Phase 5 - 커버리지 확대 (계약)

작성 2026-09-05. 유저 오더: "주요 플랫폼 외에 동영상 있는 사이트는 다 받아야 한다."
목표는 상용 다운로더(4K Video Downloader 류)와 대등하거나 그 이상의 사이트 커버리지.

## 실측 출발점 (2026-09-05 19:5x, 리드, `test/live/lead_coverage_probe_test.dart`)

20개 임의 사이트 resolve 결과 **7/20 성공**.

성공: streamable, imgur, ted(22포맷), bbc-news, facebook, archive.org, 직접 mp4.
실패(전부 `NO_MEDIA_FOUND`): dailymotion, reddit, rumble, odysee, coub, naver-tv,
kakao-tv, chzzk, soundcloud, bandcamp, twitch, bilibili, nytimes.

**중요**: 실패 케이스는 13~31초가 걸렸다 = generic 실패 후 브라우저 캡처까지 갔는데도
못 낚았다는 뜻. 즉 "어떤 사이트든 받는다"의 핵심 엔진인 브라우저 캡처가 실제로는
대부분의 사이트에서 작동하지 않고 있다. 이게 1순위 문제다.

성공 케이스도 `heights=[]` 인 것이 많다(streamable/imgur/bbc/facebook/archive) =
포맷은 찾았지만 해상도 메타가 없어 품질 선택이 불가능하다.

## Lane A - 브라우저 캡처 엔진 강화 (최우선, 모든 사이트에 효과)

`lib/core/extractors/browser_capture/**`, `lib/core/services/browser_devtools_session.dart`.

먼저 **진단**하라: dailymotion / naver-tv / twitch 세 곳을 캡처 세션으로 열어
`Network.responseReceived` 로 실제 어떤 URL/mimeType이 오가는지 raw 로그를 뽑고,
왜 후보가 0이 되는지 규명한 뒤 그 근거로 고쳐라. 추정 원인(검증 대상):

1. **재생이 시작 안 됨** -> 미디어 요청 자체가 발생 안 함. 현재는
   `document.querySelector('video')?.play()` 만 시도. 강화: 흔한 재생 버튼 셀렉터
   (`[class*=play]`, `[aria-label*=Play]`, `[data-testid*=play]`, `button[title*=재생]`)
   클릭, 플레이어 영역 중앙 좌표 `Input.dispatchMouseEvent` 클릭, 페이지 스크롤,
   `--autoplay-policy=no-user-gesture-required` 재확인, muted 설정 후 play 재시도.
2. **대기 전략 부족** -> 현재 load 후 3초 + 자동재생 후 5초. 강화: 첫 미디어 후보가
   잡히면 그때부터 3초 더 수집(관련 변형 확보), 0개면 최대 25초까지 폴링.
3. **MSE/blob 경로** -> `blob:` URL 은 제외 대상이지만, 그 뒤의 실제 세그먼트/매니페스트
   요청은 XHR/fetch 로 나간다. `Network.responseReceived` 만이 아니라
   `Network.requestWillBeSent` 도 수집하고, `Runtime.evaluate` 로
   `performance.getEntriesByType('resource').map(e => e.name)` 를 읽어 CDP 이벤트에서
   놓친 URL을 보완하라.
4. **세그먼트에서 매니페스트 역추론** -> `.m4s`/`.ts`/`seg-*.mp4` 만 보이고 매니페스트가
   없으면, 그 URL의 디렉토리에서 `master.m3u8`, `playlist.m3u8`, `manifest.mpd`,
   `index.m3u8` 를 HEAD 로 시도해 매니페스트를 복원하라 (호스트 정책 통과 필수).
5. **iframe 안의 플레이어** -> `Target.setAutoAttach` 는 이미 있음. 자식 타깃에서도
   위 1~3의 재생 트리거를 적용하라.

DONE: 위 13개 실패 사이트 중 **최소 8개**가 캡처만으로 포맷 1개 이상 반환.
가드 실패 증명 포함. 진단 로그 요약을 보고서에.

### Lane A 추가 경화 (2026-09-05, 코디네이터 지시 - headed-by-default + Codex 리뷰 A-E)

**Headed-by-default 측정**: `--headless=new`는 Cloudflare/DataDome 등이 즉시 핑거프린트해
챌린지 페이지/빈 SPA 셸을 반환한다 (실측: dailymotion 헤드리스=0캔디데이트/헤디드=1,
nytimes 헤드리스=0/헤디드=2, 동일 페이지에서 헤드리스 플래그만 바꿔 확인).
`navigator.webdriver`는 두 모드 모두 `false`(차이 없음) - 실제 차이는 UA의
`HeadlessChrome` 토큰 + 렌더링 핑거프린트. `BrowserDevtoolsSession.launch`는 이제
헤디드(오프스크린, `--window-position=-32000,-32000` + `--window-size=1280,720`)를
먼저 시도하고, 그 헤디드 "브라우저 프로세스+CDP 세션" 자체가 안 뜨거나
(`InteractiveSessionDetector` - Windows `SESSIONNAME` 부재) `preferHeaded:false` 일 때만
headless로 폴백한다 (`browser_launch_args.dart`, `interactive_session_detector.dart`,
`browser_launch_resources.dart`). `--enable-automation`은 애초에 전달한 적 없음
(그 플래그가 `navigator.webdriver`를 켜는 것이지 디버깅 포트 자체가 아님) - 스텔스
패치 없음. `BrowserCaptureExtractor.extract`는 헤디드 첫 시도에서 페이지 자체가
`Page.loadEventFired` 없이 끝나면(포맷 0개) 딱 한 번 headless로 전체 캡처를 재시도한다
(`shouldRetryHeadless` - `capture_attempt.dart`, 순수 함수로 유닛 테스트).

**A - 브라우저 내부 사설 목적지 차단**: CDP `Fetch.enable`(전 패턴)로 모든 요청을
가로채, `PrivateDestinationGuard`가 (동기 검사 + 필요 시 `InternetAddress.lookup`
DNS 재확인) 사설/루프백/메타데이터 호스트면 `Fetch.failRequest`, 아니면
`Fetch.continueRequest`. 기존 사후 후보 필터(`HostPolicy.assertAllowedHost`)보다
먼저, 후보 목록이 생기기도 전에 막는다.

**B - 헤디드 견고성**: (1) 페이지 로드 실패 시 전체 캡처 headless 재시도(위 참조),
(2) 비대화형 세션(서비스 컨텍스트) 사전 감지 후 즉시 headless, (3)
`--window-size=1280,720` 추가(뷰포트 정상화). 극단적 오프스크린 좌표 자체가
핑거프린트일 수 있다는 리뷰 지적은 인지하되, 실측이 헤디드 우세를 분명히 보여주는
현재로선 근거 없는 추가 변경을 하지 않기로 결정(`browser_launch_args.dart` 주석).

**C - 프로세스 트리 kill + 스테일 프로필 스윕**: `BrowserProcessTree.kill`이
`killAndAwaitExit`의 SIGTERM/SIGKILL 이후 Windows에서 `taskkill /T /F /PID`로
전체 자식 트리(렌더러/GPU 프로세스는 부모 kill만으로 안 죽음)를 마저 정리.
`BrowserTempCleanup.sweepStale`이 `launch()` 시작 시 fire-and-forget으로
1시간 이상 된 `mida_cdp_*`/`mida_profile_*` 임시 디렉터리를 쓸어낸다. 프로필 삭제가
재시도 후에도 실패하면 그 사실을 예외 메시지에 덧붙인다(`BrowserTempCleanup.deleteQuietly`
반환값).

**D - 쿠키 도메인 스코핑**: `MediaInfo.cookiesByDomain`(도메인별 `CookieEntry` 목록)
추가, `requestHeaders`는 UA/Referer 전용으로 축소(다른 추출기 호환을 위해
`requestHeaders['Cookie']`는 폴백으로 계속 인식). `CookieScope.headerFor`가
도메인 서픽스 매치 + `secure` 존중으로 요청별 Cookie 헤더를 만든다.
`StreamDownloader`는 리다이렉트 홉마다 재계산, `HlsFfmpegDownloader`는 ffmpeg의
전역 `-headers` 한계상 매니페스트 자신의 호스트로만 스코프(부분적 완화, 문서화됨).
`MediaDownloadPipeline`은 `FormatRequestContext`(headers+cookiesByDomain 번들)로
스레딩(파라미터 수 증가 없이 기존 `headers` 자리를 대체).

**E**: 위 B(3) 주석 참조.

### Lane A 진단 라운드 2 (2026-09-05, 클린 게이트 90s/site 재현 실패 6곳)

pinterest/youku/vk/bandcamp/xiaohongshu/reddit 각 1회 진단 실행
(`document.title`, `<video>` 존재, `Page.loadEventFired`, mimeType별 응답 수,
크기 top10, PrivateDestinationGuard 차단 목록 덤프):

- **reddit**: 최종 타이틀 "Reddit - Prove your humanity" - Cloudflare/reCAPTCHA류
  봇체크 인터스티셜. **수정**: `PageStatusDetector`에 `botCheckRequired` 시그널 추가
  (`prove your humanity`/`just a moment`/`attention required` 등 실측 문구),
  `BrowserCaptureExtractor`가 `_waitForLoad` 직후 이 시그널을 조기 검사해
  `_driveCapture`의 전체 대기 예산을 태우지 않고 `BOT_CHECK_REQUIRED`로 즉시 실패
  (봇체크를 우회/자동 통과하지 않음 - 그저 빠르게 보고).
- **vk** (→ vkvideo.ru로 리다이렉트): 실제 `video/mp4`/`audio/mp4` 트래픽이 CDP에
  잡혔으나(okcdn.ru, 서명된 경로에 확장자 전혀 없음) `CapturedMediaClassifier.classify`가
  "mimeType는 video/audio인데 URL에 인식 가능한 확장자가 없음" 케이스를 전부 버리고
  있었음. **수정**: 그 경우 서버 자신의 mimeType을 신뢰해 컨테이너를 추론
  (video/webm→webm, audio/mp4→m4a, audio/mpeg→mp3, 기본 mp4)하도록 폴백 추가.
  같은 라운드에서 `.ts`(HLS 세그먼트, video/mp2t)가 이 폴백에 잘못 걸려 자기 자신의
  후보가 되는 회귀를 발견 → `.ts`를 `.m4s`와 동일하게 "인식하되 컨테이너 없음"으로
  등록해 여전히 세그먼트로만 남도록 수정 (가드 실패 증거:
  `network_signal_recorder_test.dart`).
- **bandcamp** (`/discover`): `audio/mpeg` 스트림 다수 캡처됐으나 URL 경로가
  `mp3-128`(점 없는 경로 세그먼트)라 확장자 정규식이 애초에 매칭 대상이 아니었음 -
  위와 동일한 mimeType 폴백으로 함께 해결됨(컨테이너 'mp3', SoundCloud 추출기의
  기존 관례와 일치).
- **pinterest/xiaohongshu**: 특정 pin/note URL이 익명 세션에서 일반 피드
  (`/ideas/`, `/explore`)로 리다이렉트되며 콘텐츠 ID 자체가 사라짐 - 로그인 필요
  또는 안티스크레이핑성 리다이렉트로 추정되나, 일반적인 "제목/URL 패턴"으로는
  안전하게 탐지할 신뢰 가능한 시그널이 없어(오탐 위험) 이번 라운드에서는 수정하지
  않음(알려진 한계로 기록).
- **youku**: 탐색한 비디오 ID가 완전히 무관한 광고성 영상으로 이어짐(픽스처
  자체의 문제로 보임, 캡처 엔진 결함 아님).

**공통 수정 (모든 사이트에 적용)**: `ConsentDialogDismisser` 추가 - 텍스트 매칭
(accept/agree/동의/确定 등, 영어/한국어/중국어)으로 쿠키/연령 동의 오버레이를
`PlaybackTrigger`보다 먼저 클릭. `CaptureDriveLoop`의 첫 트리거 및 halfway 재시도
직전에 배치.

## Lane B - 범용 스니퍼 강화 (정적 HTML 단계에서 더 많이 건지기)

`lib/core/extractors/generic/**`.

1. **인라인 JSON 블롭 파싱**: `__NEXT_DATA__`, `window.__INITIAL_STATE__`,
   `window.__NUXT__`, `window.__APOLLO_STATE__`, `application/json` 스크립트 태그를
   JSON 으로 파싱해 트리를 순회하며 `.m3u8`/`.mpd`/`.mp4`/`.webm` 문자열과
   `{url, width, height, bitrate, quality, label}` 형태의 객체를 수집하라
   (문자열 정규식보다 훨씬 정확하고 해상도 메타까지 건진다).
2. **해상도 메타 확보**: 위 JSON 에서 width/height/quality/label 을 `MediaFormat` 에
   채워라. 현재 heights=[] 로 나오는 streamable/imgur/bbc/facebook/archive 케이스가
   품질 선택 가능해져야 한다.
3. **oEmbed 폴백**: 페이지에 `<link type="application/json+oembed">` 가 있으면 그 JSON을
   받아 `html` 필드의 iframe src 를 따라가라.
4. **data 속성**: `data-video-src`, `data-src`, `data-mp4`, `data-hls`, `data-setup`.

DONE: 실패 13개 중 정적 HTML 만으로 최소 3개 추가 성공 + 기존 성공 케이스의
`heights` 가 채워짐.

## Lane C - 한국 플랫폼 전용 추출기 (유저 실사용 직결)

`lib/core/extractors/naver/`, `kakao/`, `chzzk/`. 각 사이트의 공개 재생 API를 조사해
(브라우저 개발자도구 대신 CDP 캡처 로그로 조사) 전용 추출기를 만들어라.
- 네이버TV `tv.naver.com/v/<id>` (+ 네이버 블로그/카페 임베드 영상)
- 카카오TV `tv.kakao.com/.../cliplink/<id>`
- 치지직 `chzzk.naver.com/video/<no>` (VOD 만, 라이브는 범위 밖)
로그인/성인인증 필요한 콘텐츠는 명확한 `LOGIN_REQUIRED` 로 끊어라.
DONE: 3개 사이트 각각 라이브로 포맷 1개 이상 + Range GET 200/206.

## Lane D - 글로벌 주요 사이트 전용 추출기

`lib/core/extractors/` 하위 각 폴더. 우선순위 순:
Dailymotion, Reddit(v.redd.it DASH), Twitch(VOD/clip), SoundCloud(오디오),
Bilibili, Rumble.
DONE: 6개 중 최소 5개 라이브 성공 + Range GET 200/206.

## 공통 규칙

- `ExtractorRegistry` 등록 순서: 전용 추출기들 -> Generic -> BrowserCapture(fallback).
  새 추출기는 `extractor_registry_builder.dart` 에 등록(레인 간 충돌 주의, 마지막에
  리드가 병합).
- 파일 400줄 이하, emdash/이모지 금지, 영어 UI 문자열, 새 pub 의존성 금지,
  hermetic 단위 테스트 + `MIDA_LIVE=1` 라이브 테스트, 가드 실패 증명.
- 각 사이트 조사 시 **같은 URL을 5회 이상 때리지 말 것**(WAF 유발). 캡처 로그 한 번
  뽑아서 그걸로 분석하라.
- DRM(cbcs/cenc/widevine)은 기존대로 `DRM_PROTECTED` 로 끊는다. 우회 금지.

## 최종 DONE

`test/live/lead_coverage_probe_test.dart` 재실행 시 **20개 중 16개 이상 성공**.
analyze 0 error, 전체 테스트 그린, 빌드 성공.
