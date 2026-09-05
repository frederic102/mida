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

라운드 1~3(headed-by-default 측정, Codex 리뷰 A-E, 진단 라운드 2, 최종 게이트 진단,
독립 리뷰 라운드 2, 회귀 라운드 3)의 전체 기록은 `docs/plan-phase5-lane-a-history.md`
참조(이 파일이 400줄 캡에 부딪혀 라운드 4에서 분리, 2026-09-06).

### Lane A 라운드 4 (2026-09-06, 실다운로드 게이트 - blob: 후보 누출 + Fetch 워커 커버리지)

**1. blob: URL이 `MediaInfo.formats`에 누출(nicovideo, 비결정적)**: Chromium이
`<video>` 엘리먼트의 `blob:`(MediaSource) src에 대해 실제 `Network.responseReceived`를
`video/mp4` Content-Type과 함께 발생시킴 - `CapturedMediaClassifier.classify`의
확장자 없는 mimeType 폴백(라운드 2, vk.com/Bandcamp용)이 URL 스킴을 전혀 검사하지
않아 이 응답이 그대로 후보가 됨. 이 CDP 이벤트 발생 여부 자체가 레이스라 "한 번은
포맷에 섞이고 한 번은 14개 깨끗하게 나옴"의 비결정성과 정확히 일치. **수정**:
`CapturedMediaClassifier.isFetchableUrl`(신규, `http`/`https`만 통과) 추가, `classify`
와 `classifyByUrlOnly` 양쪽 진입점 최상단에서 게이트. `CapturedMediaRanker`의 기존
`blob:` 문자열 접두사 체크도 동일 헬퍼로 교체(더 넓은 커버리지: `data:`, 스킴 없는
문자열 등도 함께 차단, 단순 문자열 매치가 아님을 테스트로 증명). 테스트: **guard can
fail** - `classify`/`classifyByUrlOnly`/`NetworkSignalRecorder.recordResponse`/
`CapturedMediaRanker.rank` 네 지점 모두에서 `blob:`(+`data:`) 입력이 후보를 만들지
못함을 각각 별도로 확인.

**2. `shared_worker`/`service_worker`가 PrivateDestinationGuard 커버리지 밖(코디네이터
보안 후속 지적)**: 라운드 3에서 `Fetch`/`Network` 활성화를 `page`/`iframe`에만
적용한 것은 그 시점엔 데드락 방지책이었지만, resume이 `finally`로 무조건 보장된
지금은 그 제한이 순수한 커버리지 공백으로 남음 - service worker가 자체적으로
fetch를 발생시켜도 어떤 사설 목적지 검사도 받지 않았음. **수정**:
`ChildTargetResumer.fetchInterceptedTargetTypes`에 `worker`/`shared_worker`/
`service_worker`를 추가. `Fetch.enable`/`Network.enable` 각 호출은 여전히 개별
`try`/`catch`로 감싸여 있고 resume은 `finally`로 무조건 실행되므로, CDP가 실제로
그 타깃 타입에서 이 도메인을 거부하더라도(라이브 CDP 세션으로 확인은 못 함 - 문서화로
갈음, "else document" 충족) 그 한 통화만 조용히 스킵되고 라운드 3의 데드락이 재현되지
않는다(가드 실패 테스트: service_worker 타입에서 `Fetch.enable`이 에러를 반환해도
resume은 여전히 발생).

**확인**: `flutter analyze`(전체 프로젝트) 0 error, 새 이슈 0(기존 54개 info/warning은
전부 다른 레인 소유 파일). `test/core/services`, `test/core/extractors/browser_capture`
전체 214개 테스트 그린(라운드 3의 203개 + 이번 라운드 신규 11개). 라이브 히트 없음
(이번 라운드는 순수 정적 분석/유닛 테스트로 재현 가능한 결함이라 코디네이터 지시대로
라이브 hit 없이 수정). msedge 프로세스 수 35개로 라운드 3과 동일(변동 없음, 이번
라운드는 브라우저를 전혀 띄우지 않음).

### Lane A 라운드 5 (2026-09-06, 실다운로드 게이트 - vimeo/facebook/niconico/douyin
바레 CMAF/fMP4 세그먼트가 완결 파일로 노출됨)

최종 게이트 근본 원인: 캡처 티어가 바레 CMAF/fMP4 세그먼트(moof/mfhd/traf/trun만
있고 ftyp/moov 없음 - `.cmfv`/`.cmfa` 확장자, 확장자 없는 `video/mp4` 응답,
`range=`/`bytes=` 쿼리로 주소 지정되는 한 파일의 바이트 레인지 조각)를 완결
다운로드 가능 파일처럼 노출하고 있었음 - 다운로드 결과물에 init 세그먼트(`moov`)가
없어 ffprobe가 스트림을 찾지 못함.

**1. 세그먼트 분류 확장**: `CapturedMediaClassifier.isSegmentUrl`(신규, 단일 판정
지점) - `.cmfv`/`.cmfa`/`.m4s`/`.ts`, 숫자-확장자 인접 패턴(`\d{2,5}\.(m4s|cmfv|
cmfa|mp4)`), `seg-`/`segment`/`frag`/`chunk`/`init`/`range=`/`bytes=` 키워드를
URL 어디서든 매칭하면 세그먼트로 판정, `classify`/`classifyByUrlOnly` 양쪽 최상단
에서 게이트(mimeType 기반 수락보다 먼저 - 확장자 없는 mimeType 폴백이 스킴을
검사하지 않아 라운드 4의 blob: 누출과 같은 종류의 구멍이었음). `SegmentManifestProber
.looksLikeSegmentUrl`은 이제 이 메서드로 위임(판정 지점 중복 방지).

**주의(코디네이터에게 명시적으로 플래그)**: `range=`/`bytes=`를 세그먼트 신호로
추가하면서 라운드 2의 vk.com(`okcdn.ru`) 픽스처(`?...&bytes=0-100`)가 문자
그대로 세그먼트로 재분류됨 - 그 URL의 `bytes=` 파라미터가 실제 HTTP 바이트-레인지
디스크립터인지 무관한 서명 파라미터명인지 이번 라운드엔 라이브로 재확인하지
않았음(이번 라운드 지시가 새 사이트 라이브 히트를 요구하지 않았고, 이 정적 분석
결론 자체가 vimeo/facebook/niconico/douyin 네 사이트 실측에 근거하므로 문자 그대로
적용). vk.com이 실제로 이 셰이프라면 이건 회귀가 아니라 그동안 안 걸렸던 같은 버그의
발견이라고 판단하나, 확인은 다음 라이브 게이트에서 vk.com/vk-video를 다시 봐야 함 -
공개 항목으로 남김.

**2. 형제 세그먼트 그룹핑(신규, `NetworkSignalRecorder.reclassifyFragmentedSiblings`)**:
확장자도 키워드도 없는 순수 숫자 경로 세그먼트(예: `.../fragments/5?sig=...`)는
per-URL 패턴으로 못 잡음 - 캡처 완료 후 한 번(이벤트마다가 아니라) 전체 후보를
"디렉터리 + 마지막 경로 세그먼트의 숫자런 자리표시자로 치환" 기준으로 그룹핑,
컨테이너가 mp4/m4a고 크기가 3MB 미만이며 같은 그룹에 3개 이상 있으면 전부 세그먼트로
강등. 2개 이하, 3MB 이상, 크기 미상, m3u8/mpd 컨테이너는 건드리지 않음(품질
사다리 오탐 방지 - 실제 화질별 변형은 보통 그렇게 작지 않거나 3개 미만).

**3. 매니페스트 복구 확장**: `SegmentManifestProber`가 `stream.mpd` 추가 시도 +
세그먼트 자신의 베이스 파일명에서 유도한 `<base>.m3u8`/`<base>.mpd` 추가 추측
(`init.mp4` 옆의 `init.m3u8` 같은 셰이프). `NetworkSignalRecorder
.recordRequestWillBeSent`가 요청의 `Referer` 헤더도 `classifyByUrlOnly`(조건 B,
`.m3u8`/`.mpd`는 mimeType 무관 항상 수락)에 통과시켜, CDP가 매니페스트 자체 요청은
못 봤어도 세그먼트 요청의 Referer에 담긴 매니페스트 URL은 잡음.

**4. 관측된 매니페스트 우선**: 이미 아키텍처가 보장 - `finalCandidates`가 비어있을
때만 `_segmentProber.recoverFirst`(세그먼트-유래 복구)를 시도하므로, 네트워크에서
직접 관측된 매니페스트가 하나라도 정상 분류되어 있으면 `finalCandidates`가 비지
않아 세그먼트 복구 경로 자체가 실행되지 않음 - 별도 우선순위 로직 불필요.

**부수 발견/조정**: 라운드 2의 "Range-fragmented 응답은 가장 큰 content-length를
유지해 병합" 로직이 실은 이번 버그와 같은 클래스였음(병합된 후보의 `.url`이 첫
관측된 특정 바이트-레인지 쿼리를 그대로 유지해, 실제 다운로드도 그 한 조각만
받아왔을 가능성) - 이제 range=/bytes= URL은 애초에 candidates에 들어가지 않으므로
이 병합 코드 경로 자체가 도달 불가(주석으로 문서화, 코드는 다른 dedupe 케이스를
위해 유지). 관련 테스트(`network_signal_recorder_test.dart`, `browser_capture_
extractor_test.dart`) 갱신: "병합되어 포맷 1개" 기대값을 "세그먼트로 추적, 후보
0개"로 교체.

**신규 파일**: `test/core/extractors/browser_capture/fake_devtools_session.dart`
(테스트 전용 공유 헬퍼, `browser_capture_extractor_test.dart`가 새 프래그먼트
테스트 3개를 더하며 400줄 캡을 넘겨 `browser_capture_extractor_fragments_test.dart`
로 분리하는 과정에서 중복 방지차 추출).

**확인**: `flutter analyze`(전체 프로젝트) 0 error, 새 이슈 0. 영향받은 테스트
파일 전체(`captured_media_classifier_test.dart`, `network_signal_recorder_test.dart`,
`segment_manifest_prober_test.dart`, `captured_media_ranker_test.dart`,
`browser_capture_extractor_test.dart`, `browser_capture_extractor_fragments_test.dart`)
+ `test/core/services` + `test/core/extractors/browser_capture` 전체 224개 테스트
그린. 가드 실패 테스트: vimeo형(바레 `.cmfv`/`.cmfa` + 관측된 매니페스트 - 매니페스트만
포맷화, 세그먼트는 전혀 안 됨), niconico형(순수 숫자 경로 세그먼트 3개, 매니페스트
전무 - NO_MEDIA_FOUND, 깨진 포맷 1개 아님), 형제 그룹핑 5종(강등/비강등 경계
케이스), Referer 유도 매니페스트, 3개 미만/3MB 이상 비강등. 라이브 히트 없음(정적
재현 가능한 결함). msedge 프로세스 수 35개, 라운드 4와 동일(변동 없음, 브라우저
미실행).

### Lane A 라운드 6 (2026-09-06, 회귀 - 라운드 5 규칙이 vimeo/bbc/vk.com 실제
후보를 오분류)

라운드 5의 `range=`/`bytes=` 키워드와 숫자런-확장자 인접 패턴이 전부 **단일 URL,
형제 개수·크기 무관**하게 즉시 세그먼트로 판정하는 구조였음 - vimeo `22439234`가
4포맷→NO_MEDIA_FOUND, bbc `cz7z93zde3po`가 43.8MB 성공 다운로드→"3개 포맷 전부
실패", vk.com `video-30558759_456239017`가 0.0MB 오디오 전용 파일로 회귀. vimeo +
bbc 각 1회 진단(신규 `isSegmentUrl` vs 삭제 예정이던 라운드-5 버전을 나란히 로그로
비교)으로 확증: vimeo의 진짜 프로그레시브 mp4가
`.../v2/range/prot/<base64>/avf/<uuid>.mp4?...&range=0-802` 셰이프(라운드 5의
`range=` 키워드가 걸림) - 수정 후 재실행 시 15.7초, 포맷 2개(mp4)로 정상 resolve.
bbc는 Next.js 정적 자산 디렉터리 `_next/static/chunks/*.js`와 서드파티 분석
URL(`api.permutive.com/ctx/v1/segment`)까지 라운드 5의 bare substring
`chunk`/`segment` 매치에 걸렸음(미디어 무관 트래픽이라 실질 영향은 없었으나 오탐
범위의 증거) - 수정 후 15.0초, 포맷 4개(mp4+mpd)로 정상 resolve.

**좁힌 규칙(코디네이터 지시 그대로)**: `CapturedMediaClassifier.isSegmentUrl`이
이제 URL 단위로는 딱 두 가지만 본다 - (1) 진짜 세그먼트 확장자
`.cmfv`/`.cmfa`/`.m4s`/`.ts`, (2) `init`/`seg`/`frag`/`chunk` 경로 토큰을
**단어 경계**로(`/`, `_`, `.`, `-` 또는 문자열 시작/끝으로 양쪽이 막혀야 함) 매치 -
"chunks" 디렉터리나 "segment"라는 무관한 단어의 부분 문자열 매치를 더 이상 허용하지
않음. `range=`/`bytes=`와 라운드 5의 숫자런-확장자-인접 패턴은 URL 단위 판정에서
**완전히 제거** - 크기/형제 개수 기반 세그먼트 판정은 오직
`NetworkSignalRecorder.reclassifyFragmentedSiblings`(라운드 5, 3개 이상 + 3MB
미만 그룹)만 담당. 단일 `range=`/`bytes=` 후보는 크기와 무관하게 항상 유지.

**되돌림**: 라운드 5에서 "range=/bytes= 두 응답은 세그먼트로 추적, 후보 0개"로
바꿨던 `network_signal_recorder_test.dart`/`browser_capture_extractor_fragments_
test.dart`의 테스트를 원래 동작("두 번째 응답이 더 큰 content-length를 유지해
후보 1개로 병합")으로 되돌림 - 이게 bbc/vk.com의 실제 프로그레시브 다운로드 셰이프.
vk.com의 라운드-2 픽스처(`?...&bytes=0-100`)도 다시 "여전히 후보"로 되돌림.

**(a) 별도 지시: 불안정 테스트 결정화**: `browser_devtools_session_test.dart`의
"DevTools 포트가 안 뜨면 프로세스 kill + 프로필 삭제" 테스트가 실 스위트에서
1회 타이밍 실패 - `ping -n 1`(틱당 실 1초) 루프 + 900ms 실대기 + 10초 벽시계
상한 + `preferHeaded` 기본값(true)에 의한 이중 시도가 전부 CI 부하에 취약했음.
수정: `preferHeaded: false`(단일 시도), `connectTimeout` 150ms, 가짜 배치를
지연 없는 틱 루프로 교체(초당 수백 틱), 200ms 고정 창(2초 상한 내)에서 "킬 이후
틱 카운트가 정확히 0 증가"를 단언(느슨한 `< 3` 대신 등식 - `killAndAwaitExit`가
프로세스 종료를 `await`한 뒤 반환하므로 등식이 성립). 벽시계 스톱워치 단언은
제거. 5회 연속 재실행으로 결정성 확인.

**확인**: vimeo/bbc 각 1회 라이브 진단(코디네이터 승인)으로 회귀 확정 수정 확인.
가드 실패 테스트: vimeo 실제 URL 셰이프(`isSegmentUrl` false, `classify` 후보
유지), bbc의 `_next/static/chunks`/`permutive.../segment` 오탐 방지, 리터럴
`seg-`/`init.mp4`/`.cmfv`/`.cmfa`/`.m4s`/`.ts`는 여전히 세그먼트, 단일
`bytes=`+큰 content-length는 여전히 후보. 엔드투엔드: vimeo형/bbc형 각 1개
신규(라이브 셰이프 그대로 fake session 재현). `flutter analyze`(전체) 0 error,
새 이슈 0(기존 53개는 전부 다른 파일). `flutter test`(전체 프로젝트) 954 passed,
42 skipped(MIDA_LIVE 게이트, 미설정), 0 failed. msedge 프로세스 수 35개,
라이브 진단 전/후 동일(누수 없음).

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

## Result (2026-09-06)

Honest status based on what is in git history and in the code's own doc
comments as of this date. Numbers not found anywhere in that history are
marked "to be measured by the lead" rather than guessed.

### Corpus grew past the original DONE bar

The 최종 DONE bar above was written against a 20-site corpus. By the time
of the `v2.2 coverage` commit, `test/live/lead_coverage_probe_test.dart`'s
corpus had grown to 32 sites (the full native-extractor list plus the
generic-tier sites from `docs/coverage-corpus.md`), and the test file's
own `MIDA_COVERAGE_MIN` default is still `16`. That default was not raised
to scale with the larger corpus; flagged here as an open item, not
silently fixed in this doc pass.

### Aggregate coverage measured

Per the `v2.2 coverage` commit message (`5a572a3`, 2026-09-06): **25/32
sites resolve formats, 20/32 complete the full resolve + real pipeline
download + ffprobe criterion** (see `docs/coverage-corpus.md` for what
that criterion means). No per-site pass/fail breakdown was recorded in
that commit message. Getting one requires rerunning
`MIDA_LIVE=1 flutter test test/live/lead_coverage_probe_test.dart` and
reading its per-site `OK`/`FAIL`/`ERR` output lines - to be measured by
the lead.

### Lane A (browser capture engine)

Shipped, per this file's own Lane A sections above and the diff history:
headed-by-default launch with headless fallback, in-browser private-
destination blocking via CDP `Fetch` interception, consent/age-gate
dialog dismissal, broadened playback triggers, adaptive first-candidate
polling, `performance.getEntriesByType('resource')` backfill, segment-to-
manifest reconstruction, process-tree kill, stale temp-profile sweep, and
cookie domain scoping. The diagnosis-round-2 and final-gate fixes
documented above (reddit bot-check early exit, vk/bandcamp mimeType-based
container fallback, the bilibili `ConcurrentModificationError` crash fix,
TLS-certificate-failure messaging for vk/ok.ru) are all in the tree with
their own guard-failure test evidence per file. Pinterest and xiaohongshu
remain known, undocumented-as-fixed limitations (anonymous-session
redirect strips the content id) by deliberate choice, not oversight.

The Lane A DONE bar ("최소 8개 사이트가 캡처만으로 포맷 1개 이상 반환") was
not re-measured against the final 32-site corpus in anything found in git
history - to be measured by the lead.

### Lane B (generic sniffer)

Shipped: `inline_json_scanner.dart`, `json_media_walker.dart`,
`oembed_scanner.dart`, and `format_expander.dart` all exist with hermetic
unit tests and fixtures (`generic_next_data.html`,
`generic_initial_state.html`, `generic_data_attrs.html`,
`generic_videojs_setup.html`). Whether this recovered at least 3 more
successes plus filled in the previously empty `heights` on
streamable/imgur/bbc/facebook/archive, as the Lane B DONE bar asked, was
not confirmed against a live run in anything found in git history - to be
measured by the lead.

### Lane C (Korean platforms)

Shipped: `NaverExtractor`, `ChzzkExtractor`, `KakaoExtractor`, all wired
into the registry, all with `test/live/korea_live_test.dart`. Per that
test file's own doc comment, KakaoTV's public video service was confirmed
live 2026-09-05 to be discontinued, so its half of the Lane C DONE bar
("포맷 1개 이상") cannot literally be met by design - the honest
replacement is the clean `NOT_FOUND` behavior described in
`docs/supported-sites.md`. Whether Naver TV and CHZZK meet their half of
the bar on a live run was not confirmed in anything found in git history
- to be measured by the lead.

### Lane D (global platforms)

Shipped: `DailymotionExtractor`, `RedditExtractor`, `TwitchExtractor`,
`SoundCloudExtractor`, `BilibiliExtractor` - 5 of the 6 sites originally
scoped for this lane got a native extractor; Rumble did not (it remains
on the browser-capture tier, per `docs/coverage-corpus.md`), which matches
the Lane D DONE bar's "6개 중 최소 5개" read as extractors built. Live
pass/fail is environment-sensitive: per
`test/live/global_sites_live_test.dart`'s own doc comment (2026-09-05),
Dailymotion and Twitch VOD were confirmed working end to end in that pass;
Bilibili and Reddit hit anti-bot blocks in that sandbox's network,
plausibly TLS-fingerprint based and plausibly reproducible elsewhere;
SoundCloud's `client_id` resolution and Douyin's JS-VM anti-bot challenge
were not resolved within that pass's budget. Whether the same holds
outside that sandbox's network is to be measured by the lead.

### Not shipped / open items

- `MIDA_COVERAGE_MIN` still defaults to 16 against a 32-site corpus (see
  above).
- Pinterest and xiaohongshu content-id loss on anonymous redirect.
- SoundCloud `client_id` resolution and Douyin's JS-VM challenge (Lane D).
- Niconico current-site auth (per `global_sites_live_test.dart`).
- Per-site pass/fail for the current 32-site corpus, and a re-check of the
  Lane A/B/C DONE bars against that corpus, both to be measured by the
  lead via a live `MIDA_LIVE=1` run.
