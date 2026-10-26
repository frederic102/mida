# Phase 7 - "거의 모든 플랫폼" 커버리지 + 에이전트/헤드리스 인터페이스 (오더 다이제스트, 2026-10-25)

> 리드 소유 문서. 유저 오더(2026-10-25): "비슷한 서비스는 안 되는 걸 찾는 게 더 빠를 정도로 엄청나게 많은
> 플랫폼을 지원한다. 그 수준으로. 그리고 에이전트랑 연결해서 헤드리스로도 작업되게." + 직전 질문
> "facebook 은 왜 빠졌나".

## INTENT

1. **커버리지**: 사용자가 아무 영상 URL 을 던져도 받히는 경험. 경쟁 기준은 yt-dlp 류의 사이트 수가
   아니라 "실제로 사람들이 쓰는 상위 플랫폼 + 그 외는 범용 티어가 받아냄". 측정은 기존 게이트
   (`test/live/lead_coverage_probe_test.dart`) 를 확장한 코퍼스로, "resolve + 실다운로드 + ffprobe 스트림"
   기준만 인정. 정책 불변: 사이트 자체 플레이어의 공개 API 재현 또는 정직한 실브라우저. 챌린지 풀이,
   핑거프린트 스푸핑, IP 로테이션, DRM/인증서 우회 금지. yt-dlp 재도입 금지 (v2.0.0 결정).
2. **에이전트 인터페이스**: GUI 없이 동작하는 `mida` CLI (URL -> JSON 결과, 진행 상황 JSON lines,
   종료코드 계약) + 강제 헤드리스 브라우저 캡처 모드. 에이전트가 읽기 쉬운 형태: JSON lines, 고정 exit code, 스킬 파일 + AGENTS.md 사용법.
   비대화형 세션(서비스/에이전트 런너)에서 창을 띄우지 않고 끝까지 돈다.
   **MCP 금지 (유저 2026-10-25, "극혐")**: 에이전트 연결은 CLI 를 셸에서 직접 호출 + JSON 파싱으로만.
   서버/데몬/프로토콜 층을 두지 않는다. 에이전트용 사용법은 프로젝트 스킬 파일로 제공.

## 현황 (2026-10-25 실측)
- v2.3.0: 네이티브 16 (YouTube, X, TikTok, Instagram, Naver TV(종료), CHZZK, Kakao(종료), Dailymotion,
  Twitch, Reddit, SoundCloud, Bilibili, Douyin, Niconico, Odysee, Vimeo) + 범용 페이지 분석 + 브라우저 캡처.
- 게이트 마지막 전체 측정 19/32 (v2.2.0). Facebook 은 네이티브 없음, 범용+캡처 경로로 0.7MB 저화질 성공
  (로그인 벽). CLI/bin 없음, main.dart 가 Flutter 바인딩에 바로 묶임. 헤드리스는 폴백 전용
  (`InteractiveSessionDetector`, SESSIONNAME 부재 시만).

## 조사 (병렬, 2026-10-25)
- 경쟁 지형: `docs/research-coverage-landscape-2026-10.md` (competitive-analyst).
- CLI/헤드리스 시임: Explore 보고 -> 아래 SCOPE 에 반영.

## SCOPE
(조사 결과 수신 후 레인 확정. 아래는 확정 전 골격.)

### Track A - 에이전트 인터페이스 (코드, 먼저)
- A1 `bin/mida_cli.dart` 또는 `--cli` 모드: `mida resolve <url>` / `mida download <url> [--out] [--format]
  [--audio-only] [--headless] [--json]`. stdout = JSON lines (event: progress/status/result/error),
  exit 0 성공 / 2 입력오류 / 3 추출실패 / 4 다운로드실패 / 5 정책거부(DRM/로그인).
- A2 Flutter 비의존 코어 확인: `lib/core/**` 가 `package:flutter` 를 import 하지 않도록 (있으면 분리).
  설정은 CLI 인자/환경변수로 주입 (`SettingsService` 의 shared_preferences 우회).
- A3 강제 헤드리스: `--headless` / `MIDA_HEADLESS=1`. 헤드리스에서 챌린지 페이지를 만나면 정직하게
  "headless blocked, rerun headed" 에러코드로 보고 (스푸핑 금지).
- A4 (삭제, 유저 결정) MCP 서버 없음. 대신 `.claude/skills/mida-download/SKILL.md` 로 에이전트 사용법 제공.
- A5 설치본에 CLI 포함 (installer.iss, 64비트 모드 선언 추가), README "Agent / CLI" 절.

### Track B - 커버리지 (조사 후 확정)
- B1 Facebook 네이티브 (공개 영상 + 로그인 세션 토글).
- B2 조사 상위 플랫폼 중 미지원 Top-N 네이티브/범용 보강 (후보: Pinterest, LinkedIn, Kick, SOOP/AfreecaTV,
  Weibo, Kuaishou, Naver Blog/Cafe, Rumble 확인, VK/ok.ru 는 인증서 정책상 제외 유지).
- B3 임베드 플랫폼 패밀리 (JW Player, Brightcove, Kaltura, Wistia, Vimeo/YouTube 임베드) 를 범용 티어에서
  인식 -> "any site" 폭을 사이트 수가 아니라 패밀리 수로 늘린다.
- B4 코퍼스 32 -> 60+ 확장, 게이트 재측정 (브라우저 기동이라 유저 승인 필요).

## DONE (관찰 가능 체크)
- [ ] `dart run bin/mida_cli.dart download <youtube url> --headless --json` 가 창 없이 파일을 만들고
      exit 0, 마지막 JSON 에 output path + ffprobe 스트림 요약.
- [ ] 비대화형 환경 시뮬레이션(SESSIONNAME 제거) 에서 브라우저 캡처 사이트 1곳 헤드리스로 다운로드.
- [ ] Claude Code 세션이 셸에서 `mida-cli download ... --headless` 를 호출해 JSON 결과를 읽는 데 성공 (실측).
- [ ] Facebook 공개 영상 1건 네이티브 경로로 video+audio 다운로드.
- [ ] 확장 코퍼스 게이트 결과를 `docs/coverage-corpus.md` 에 기록, README 표 갱신.
- [ ] analyze 0 errors, 스코프별 test 그린 (bare `flutter test` 금지, "Error:" grep).
- [ ] AEGIS 5석 + astra-review, PENTAD SHIP 이상.

## Track A 계약 (리드 확정 2026-10-25, 레인은 시그니처 변경 금지)

### CLI 명령/출력 (Lane C 구현, Lane M 소비)
- 실행: `dart run bin/mida_cli.dart <cmd> ...` (개발), 설치본은 `mida-cli.exe` (`dart compile exe`).
- `resolve <url> [--login-session] [--headless]` -> stdout 한 줄 JSON `{"event":"result","kind":"resolve","title","author","duration_seconds","platform","formats":[{"id","ext","height","fps","has_video","has_audio","protocol","content_length"}],"captions":[lang...]}`. 헤더/쿠키 절대 미출력.
- `download <url> [--out DIR] [--type video|audio] [--quality best|1080|720|480|360] [--audio-format mp3|m4a|...] [--format-id ID] [--captions] [--login-session] [--headless] [--ffmpeg PATH]` -> stdout JSON lines: `{"event":"status","message"}`, `{"event":"progress","fraction":0.42}`, 마지막 `{"event":"result","kind":"download","output_path","bytes","video":{"codec","width","height","duration_seconds"},"audio":{"codec"},"attempts":n}` 또는 `{"event":"error","code","message"}`. 에러 메시지는 `UrlParser.redactUrlsInText` 통과.
- `sites` -> `{"event":"result","kind":"sites","native":[...],"tiers":["generic","browser-capture"]}`.
- `version` -> `{"event":"result","kind":"version","version":"2.4.0"}`.
- `--quiet` 면 progress 이벤트 생략. `--json` 은 기본이자 유일한 출력 형식 (사람용 텍스트 모드 없음, stderr 는 디버그 로그만).
- exit code: 0 성공 / 2 인자 오류 / 3 추출 실패(NO_MEDIA_FOUND, UNSUPPORTED_URL, PARSE) / 4 다운로드 실패 / 5 정책 거부(DRM, LOGIN_REQUIRED, HEADLESS_BLOCKED) / 6 환경(BROWSER_MISSING, FFMPEG_MISSING, NETWORK) / 7 RATE_LIMITED.
- 환경변수: `MIDA_FFMPEG_PATH`(디렉터리 또는 ffmpeg 실행파일), `MIDA_HEADLESS=1`(= --headless), `MIDA_BROWSER_PATH`(기존).
- 공개 함수: `Future<int> runMidaCli(List<String> args, {ExtractorRegistry? registry, MediaDownloadPipeline? pipeline, StringSink? out, StringSink? err, Map<String,String>? environment})` in `lib/cli/mida_cli.dart`. 테스트는 이 함수로 헤르메틱.

### 헤드리스 (Lane H)
- `buildExtractorRegistry({useBrowserLoginSession, forceHeadless})` (스텁 이미 박힘) -> `BrowserCaptureExtractor(forceHeadless:)` -> `BrowserDevtoolsSession.launch(preferHeaded: false)`.
- 헤드리스 캡처가 로드는 됐는데 미디어 0 이고 챌린지/빈 SPA 징후면 `MediaExtractionException('HEADLESS_BLOCKED', ...)`. 스푸핑으로 뚫지 않는다.
- `GenericExtractor` 의 DOM 렌더 폴백도 같은 플래그를 존중.

### 에이전트 연결 (Lane M, MCP 없음)
- `dart compile exe bin/mida_cli.dart` -> 설치본 `mida-cli.exe`. 에이전트는 셸로 실행하고 마지막 JSON 줄과 exit code 만 읽는다.
- 프로젝트 스킬 `.claude/skills/mida-download/SKILL.md`, README "Agent / CLI" 절.

### 파일 펜스
- Lane C: `bin/`, `lib/cli/**`, `lib/core/download/hls_ffmpeg_args.dart`, `lib/core/download/hls_ffmpeg_downloader.dart`, `lib/core/services/platform_service.dart`, `lib/core/services/ffmpeg_locator.dart`, `lib/core/services/settings_service.dart`(Flutter-free 코어 분리), `lib/features/download/services/download_service_io.dart`(타입 추출만), 새 `lib/features/download/models/`, `test/cli/**`, pubspec `executables:`.
- Lane H: `lib/core/extractors/extractor_registry_builder.dart`, `lib/core/extractors/browser_capture/**`, `lib/core/services/browser_devtools_session.dart`, `lib/core/services/interactive_session_detector.dart`, `lib/core/extractors/generic/generic_extractor.dart`(플래그 전달만), 해당 테스트.
- Lane M: `installer.iss`, `.claude/skills/mida-download/**`, `scripts/build_windows.ps1`, README "Agent / CLI" 절.
- 공통 금지: 라이브 네트워크, 브라우저 기동, docker, `run_in_background`, bare `flutter test` (스코프 디렉터리로만 + "Error:" grep).
