# MiDa v2.1 Phase 4 - 브라우저 로그인 세션 재사용 (계약)

작성 2026-09-05. 오더: 로그인해야 평문 스트림을 주는 사이트 (Vimeo, Instagram 오디오,
TikTok 강화 WAF, 로그인 전용 사이트) 를 유저 본인 계정으로 받는다. yt-dlp 의
`--cookies-from-browser` 와 같은 원리. DRM 자체 우회는 하지 않는다 (로그인해도 DRM
재생목록만 주면 DRM_PROTECTED 유지).

## INTENT

유저가 이미 로그인해 둔 Edge/Chrome 세션을 (a) 쿠키로 읽어 HTTP 추출기에 붙이고,
(b) 헤드리스 캡처 브라우저에 그 프로필을 붙여 띄운다. 유저는 설정에서 "브라우저
로그인 사용" 토글 + 브라우저 선택 (Edge/Chrome/Brave) 만 한다.

## 실측 근거 (2026-09-05)

- Vimeo 76979871: 로그아웃 player config 의 hls/dash 전부 `/playlist/drm/cbcs`. yt-dlp
  메시지 "The web client only works when logged-in". 로그인 세션에서 평문이 나오는지는
  이 단계의 첫 실측 항목 (구현자가 유저 프로필 쿠키로 확인, 안 나오면 그대로 보고).
- Instagram Chunk8-jurw: 로그아웃 DASH 매니페스트 has_audio=false.
- 헤드리스 캡처는 현재 빈 임시 프로필로 실행 (`browser_devtools_session.dart`).

## SCOPE

### 1. 쿠키 읽기 `lib/core/services/browser_cookie_store.dart` (+ 분할 파일)

- Chromium 계열 쿠키 DB: Windows `%LOCALAPPDATA%\Microsoft\Edge\User Data\<Profile>\Network\Cookies`,
  `%LOCALAPPDATA%\Google\Chrome\User Data\<Profile>\Network\Cookies`, Brave 동일 패턴.
  macOS `~/Library/Application Support/Google/Chrome/<Profile>/Cookies`, Edge/Brave 동일.
- 파일이 브라우저에 잠겨 있으므로 **임시 복사 후 읽기**. SQLite 파서: 순수 Dart 최소
  구현 (테이블 `cookies` 의 host_key, name, path, encrypted_value, expires_utc, is_secure
  컬럼만; B-tree 리프 페이지 순회, overflow 페이지 처리). 새 pub 의존성 금지가 원칙이나
  `sqlite3` (dart:ffi, 번들 DLL) 은 **리드 승인 하에 허용** (파서 직접 구현이 400줄을
  크게 넘으면 sqlite3 채택하고 보고).
- 값 복호화: Windows `v10`/`v20` 접두 = AES-256-GCM, 키는 `User Data\Local State` 의
  `os_crypt.encrypted_key` (base64, `DPAPI` 접두 제거 후 `CryptUnprotectData` 로 복호화;
  dart:ffi 로 crypt32 호출). `v20` (App-Bound Encryption, Chrome 127+) 은 브라우저
  프로세스 권한이 필요해 실패할 수 있음: 실패 시 그 쿠키는 건너뛰고 카운트 보고, 이
  경우 (b) 프로필 부착 경로가 주 경로가 된다. macOS: Keychain 의 "Chrome Safe Storage"
  비밀번호 -> PBKDF2(SHA1, 1003회, salt `saltysalt`, 16바이트) -> AES-128-CBC, `v10` 접두.
  `security find-generic-password -w -s "Chrome Safe Storage"` Process.run (인자 리스트).
- API: `Future<List<Cookie>> cookiesFor(Uri url, {String browser, String profile})`,
  도메인 매칭 (host_key 앞 `.` 은 서브도메인 포함), 만료 제외, path 매칭.
- 쿠키 값은 로그/예외 메시지/디스크에 절대 남기지 않는다. 임시 복사본은 finally 삭제.

### 2. 추출기 연결

- `MediaExtractor.extract` 호출 전 `SessionProvider` 가 URL 도메인의 쿠키를 만들어
  `requestHeaders['Cookie']` 로 주입할 수 있게 `ExtractorRegistry.resolveInfo(url,
  {SessionContext? session})` 추가. 각 추출기는 `session?.cookieHeaderFor(host)` 를 자기
  요청에 붙인다 (YouTube: watch/player/스트림, Instagram: 페이지 fetch, TikTok: 두 요청,
  Vimeo 는 범용 경로: 페이지 + 임베드 + config). 쿠키는 요청 호스트가 쿠키 도메인에
  속할 때만 전송 (교차 도메인 유출 금지, 테스트).
- 스트림 다운로드 (`StreamDownloader`, `HlsFfmpegDownloader`) 도 같은 규칙.

### 3. 캡처 브라우저에 프로필 부착

- `browser_devtools_session.dart`: 옵션 `userDataDir` (유저 프로필 루트) + `profileDirectory`
  (`Default`, `Profile 1`...). 브라우저가 이미 실행 중이면 같은 user-data-dir 로 헤드리스를
  못 띄우므로: (1) 프로필 폴더의 `Network\Cookies`, `Local State` 만 임시 프로필로 복사해
  띄우는 방식을 기본으로 (잠금 회피, 원본 무수정), (2) 실패 시 1번 쿠키를 CDP
  `Network.setCookies` 로 주입.
- 캡처 후 임시 프로필 삭제 (finally, 기존 규칙).

### 4. 설정 UI (`lib/features/settings/widgets/login_session_section.dart`)

- 토글 "Use my browser login", 브라우저 드롭다운 (감지된 것만), 프로필 드롭다운,
  상태 한 줄 ("Found 143 cookies for 12 sites" 처럼 개수만, 값 노출 금지).
- `SettingsService` 에 키 3개 추가. 기본값 off.

### 5. 테스트

- SQLite 파서: 실제 Chromium Cookies 파일 fixture 는 민감하므로 **테스트가 직접 생성**
  (sqlite3 CLI 없이 만들려면 최소 페이지 빌더를 테스트 유틸로; sqlite3 패키지 채택 시 그걸로
  생성). 복호화: Windows 는 DPAPI 가 머신 종속이므로 AES-GCM 단계만 알려진 키로 테스트,
  `v20` 실패 시 건너뛰기 테스트. 도메인/경로 매칭, 만료. 교차 도메인 미전송 (guard-can-fail).
- 라이브 (`MIDA_LIVE=1`, **각 URL 1회만**): 유저 프로필 쿠키로 Vimeo 76979871 resolve ->
  평문 포맷 나오면 성공, 여전히 DRM 이면 그 사실을 보고 (실패 아님). Instagram 릴 오디오
  유무. 이 머신의 Edge 로그인 상태에 따라 결과가 달라지므로 보고서에 어떤 브라우저/프로필을
  썼는지 기록.

## OUT OF SCOPE

DRM 복호화/우회, Firefox/Safari 쿠키, 비밀번호 입력형 로그인 UI, 2FA.

## DONE

analyze 0 / 테스트 그린 + 가드 증명 / 라이브 1회 보고 / 쿠키 값 로그 0건 (grep) / 400줄 /
emdash 없음 / 빌드 성공.
