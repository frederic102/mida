# MiDa v2.2 Phase 5 - Lane A (browser capture engine) 라운드 히스토리

`docs/plan-phase5-coverage.md`의 Lane A 섹션이 400줄 캡에 부딪혀 분리됨(2026-09-06,
라운드 4). 헤딩 구조는 원본과 동일, 내용은 그대로 이동.

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

### Lane A 최종 게이트 진단 (2026-09-05/06, bilibili 90s 벽 + tumblr NO_MEDIA_FOUND + TLS)

**bilibili** (`BV1GJ411x7h7`) 위상별 타이밍 실측: launch 1.2s, loadFired 4.8s(빠름),
postLoadDelay+trigger 후 9s 시점 후보 0개, 8초 정착 후 17s 시점에도 온전한 후보는 0개지만
segmentUrls 3개(서로 다른 디렉터리 2개)는 확보됨 - 즉 시간이 새는 곳은 로드/폴루프가
아니라 **매니페스트 재구성 단계**. 같은 진단에서 치명적 버그 발견: `SegmentManifestProber
.recoverFirst`가 호출자(`BrowserCaptureExtractor`)의 **살아있는(계속 add되는) Set을
그대로 순회**하다가 `ConcurrentModificationError`로 죽음(재현: 진단 스크립트 t=20s에
크래시). 이 에러는 Dart `Error`(=`Exception`이 아님)라 `_attemptCapture`의
`on MediaExtractionException catch`를 그대로 건너뛰어 캡처 전체가 미가공 크래시로
새어나갔다 - 90s 벽의 상당 부분을 설명. **수정**: (1) `recoverFirst`가 순회 전
`segmentUrls.toList(growable:false)`로 스냅샷, (2) 디렉터리 시도 상한 4개
(`_maxDirectoriesToTry`), (3) probe당 4초 타임아웃(`_probeTimeout`) - 무응답 호스트가
무한 대기하지 않도록. (4) `PageLoadWaiter`(신규, `_waitForLoad`에서 분리):
`Page.loadEventFired` 전에도 `candidates`가 이미 채워졌으면 즉시 반환 - 무거운 페이지의
실제 미디어 요청이 페이지 전체 로드보다 훨씬 먼저 끝나는 경우 불필요한 대기를 없앤다.
(5) `CaptureDriveLoop`: 이미 `m3u8`/`mpd` 매니페스트 후보가 있으면 `variantSettleDelay`
생략(매니페스트 자체가 모든 variant를 담고 있어 형제 요청을 더 기다릴 이유가 없음).

**tumblr** (`staff.tumblr.com/post/70425851417`): 진단 결과 해당 포스트 URL이 익명
세션에서 블로그 루트(`staff.tumblr.com/`)로 리다이렉트됨 - `<video>` 0개, `<source>` 0개,
비디오/오디오 mimeType 응답 0개(총 208개 응답 중). **결론: 이 특정 포스트에는 비디오가
없다(혹은 이미 사라져 루트로 튕겨나감) - 캡처 엔진 결함이 아니라 스테일 픽스처.
코디네이터가 교체할 corpus URL로 보고.**

**TLS 인증서 처리 (vk/ok.ru HandshakeException)**: `StreamDownloader`에 CDN 인증서를
이 시스템이 신뢰하지 않을 때(okcdn.ru 등에서 실측) 명확한 what/why/next 메시지로 매핑.
인증서 실패는 일시적이지 않으므로(재시도해도 동일하게 실패) `maxRetries`를 소진하지 않고
즉시 실패. 인증서 검증을 끄는 우회는 하지 않음(명시적 금지 사항 준수).

### Lane A 독립 리뷰 라운드 2 (2026-09-06, 세 가지 결함 수정)

**1. child target Fetch.enable 경쟁(CRITICAL)**: `Target.setAutoAttach`가
`waitForDebuggerOnStart: false`였던 탓에 iframe이 attach 즉시 실행을 시작해,
`Fetch.enable`이 그 세션에 실제로 적용되기 전 창(window)에 요청을 낼 수 있었음 -
PrivateDestinationGuard의 커버리지 공백. **수정**: `waitForDebuggerOnStart: true`로
전환 - child는 우리가 명시적으로 재개하기 전까지 아무것도(스크립트/요청) 실행하지
않는다. `_onCdpEvent`에서 순서를 `Fetch.enable` → `Network.enable` →
`Runtime.runIfWaitingForDebugger`로 고정(테스트: child 세션에 대한 커맨드 순서를
직접 검증). 동시에 `PrivateDestinationGuard`의 DNS 조회 실패를 fail-open→
**fail-closed**로 전환(타임아웃/에러 시 차단, 통과 아님).

**2. 프로세스 트리 kill 순서(CRITICAL)**: `killAndAwaitExit`가 부모를 먼저
kill+await한 뒤 `taskkill /T`를 호출해, 그 시점엔 부모가 이미 죽어 있어 Windows가
자식 트리를 그 PID에 제대로 귀속시키지 못하고 orphan 남길 수 있었음. **수정**:
`BrowserProcessTree.kill`(트리 kill)을 부모가 **아직 살아있을 때** 먼저 실행하도록
순서 반전. macOS/Linux는 `pkill -P <pid>`로 동일 사상 적용(프로세스 그룹 launch는
하지 않음, 더 가벼운 대안). 테스트: fake process + fake tree-killer로 호출 순서
자체를 단언(`['treeKill', 'processKill']`).

**3. 메인 문서 상태 오귀속(HIGH)**: 어떤 타깃에서든 첫 `text/html` 응답을 메인
문서로 간주하던 로직 때문에 404 광고 iframe이 정상 페이지를 NOT_FOUND로 오판할 수
있었음. **수정**: `MainDocumentStatusTracker`(신규) - `type=='Document'` +
최상위 세션(child 아님) + requestId가 내비게이트한 URL의 최초
`Network.requestWillBeSent`와 동일(리다이렉트 체인은 Chrome이 requestId를 재사용하는
성질로 자동 커버) 세 조건을 모두 만족해야 상태를 갱신. 테스트: child 세션의 404는
무시, 최상위+내비게이트 URL의 404는 반영, 트레일링 슬래시 정규화 등.

**부수 발견**: 이 라운드 검증 중 `lib/core/net/host_policy.dart`(다른 레인 소유,
미수정)에 대한 동시 편집이 `HostPolicy.assertResolvesToPublicHost`를 마찬가지로
fail-closed로 바꿔, `cdn.example.com`(실제 DNS 레코드 없음)을 픽스처로 쓰던 기존
테스트 다수가 붕괴 - 내 소유 파일(`browser_capture_extractor_test.dart`,
`segment_manifest_prober_test.dart`, `hls_ffmpeg_downloader_cookie_scope_test.dart`)의
픽스처만 리터럴 공인 IP(93.184.216.34)로 교체해 대응(host_policy.dart 자체는
미수정, 다른 레인 소유 존중).

### Lane A 회귀 라운드 3 (2026-09-06, 라운드 2 직후 douyin/vk-video/ok-ru/twitch-clip
90초 벽 재발 - 재현 + 수정 + 확인)

라운드 2 게이트 이전엔 douyin 17초, vk-video 34초, ok-ru 27초로 정상 resolve하던
것이, 라운드 2 반영 직후 게이트에서 이 셋과 twitch-clip 모두 90초
`TimeoutException` 벽에 걸림. douyin 1건 재현 실측(진단 전용 스크립트, 프로덕션
`BrowserCaptureExtractor` 경로 그대로, `sessionLauncher` 주입으로 단계별 타임스탬프만
추가 관측) 결과: launch+attach 1193ms, 첫 `Fetch.requestPaused` 1225ms,
`Page.loadEventFired` 5370ms, 첫 video/audio mimeType 응답 6908ms, 최종 resolve
13971ms(포맷 1개) - 정상 시나리오이므로 근본 원인은 이 페이지가 아니라 다른
페이지/타깃 타입에서 라운드 2 변경이 만든 일반적 결함으로 판단, 셋 다 아래서 고침.

**1. child target 영구 정지(가장 유력, CRITICAL)**: 라운드 2에서
`waitForDebuggerOnStart: true`로 전환하며 `_onCdpEvent`가 `Fetch.enable` →
`Network.enable` → `Runtime.runIfWaitingForDebugger`를 단일 try 블록 안에서 순서대로
호출했음 - `Fetch.enable`이 worker/service_worker 등 CDP가 Fetch 도메인을 고르게
지원하지 않는 타깃 타입에서 에러를 던지면 그 아래 `Runtime.runIfWaitingForDebugger`가
전혀 실행되지 않아 해당 타깃이 **영구히** 일시정지 상태로 남음
(`waitForDebuggerOnStart: true`이므로). SPA가 여러 worker를 붙이는 사이트일수록 이
정지가 상위 리소스 로드를 block해 90초 벽으로 귀결. **수정**: 신규
`ChildTargetResumer`(`lib/core/services/child_target_resumer.dart`, 57줄) -
`Fetch.enable`/`Network.enable`은 `try`, `Runtime.runIfWaitingForDebugger`는 반드시
`finally`에서 실행(무엇이 실패하든 재개는 보장). 추가로 Fetch/Network 활성화 자체를
`page`/`iframe` 타깃 타입에만 적용(`fetchInterceptedTargetTypes`), worker 등에는
아예 시도하지 않고 즉시 재개. `browser_devtools_session.dart`의 `_onCdpEvent`는 이제
`targetInfo['type']`만 뽑아 이 클래스에 위임하는 얇은 래퍼. 테스트: page 타입은
Fetch+Network 활성화 후 재개, worker 타입은 활성화를 건너뛰고 바로 재개, **guard can
fail** - page 타입에서 `Fetch.enable`이 에러를 반환해도 여전히 재개됨(정확히 이번
회귀 시나리오를 가짜 WebSocket 서버로 재현), 세션이 이미 닫혀 있어도 던지지 않음.

**2. DNS 조회 미캐싱(유력, MEDIUM)**: 라운드 2의 fail-closed DNS 체크가 매
`Fetch.requestPaused` 이벤트마다 실제 `InternetAddress.lookup`을 호출하고 있었음 -
현대 SPA는 같은 CDN/광고/분석 호스트에 수십 번 요청하므로, 요청마다 새로 조회하면
그 비용이 누적되어 응답이 순서대로 막힘. **수정**:
`PrivateDestinationGuard._dnsVerdictCache`(프로세스 수명 `Map<String, Future<bool>>`,
값이 아니라 Future 자체를 캐싱해 동시 요청이 진행 중인 조회 하나를 공유하게 함),
타임아웃 3초→2초로 단축(호스트당 최대 1회만 이 비용을 물게 되어 가끔 발생해도 더는
누적되지 않음). 테스트: **guard can fail** - 같은 호스트에 대한 연속 두 요청이 조회
1회만 발생, 동시(in-flight) 두 요청도 조회 1회만 공유.

**3. 리다이렉트 requestId 가정 경화(가능성 낮음이나 방어적으로 수정, LOW)**:
`MainDocumentStatusTracker`가 단일 nullable `_mainRequestId`로 "한 번 걸리면 끝"
방식이었음 - Chrome이 리다이렉트 체인 전체에서 항상 같은 requestId를 재사용한다는
전제가 실제로는 100% 보장되지 않음. **수정**: `Set<String> _mainRequestIds`로 전환,
내비게이트한 URL과 일치하는 `Document` 타입 `requestWillBeSent`는 몇 번이 오든 모두
추적 대상에 추가. 테스트: **guard can fail** - 리다이렉트 홉마다 새 requestId를 발급
하는 케이스도 첫 id에 멈추지 않고 두 번째 id의 최종 상태를 반영.

**확인**: 위 수정 반영 후 douyin 1건 재실행 - **13971ms(30초 기준 대비 여유 있음)**,
포맷 1개 정상 resolve. `test/core/services`, `test/core/extractors/browser_capture`
전체 203개 테스트 그린. msedge 프로세스 수 실행 전/후 35개로 동일(누수 없음).

