# MiDa v2.1 Phase 4 - 로그인 세션(쿠키) + 차단 회복력 (계약)

작성 2026-09-05. 유저 오더: 로그아웃 상태에서 막히는 것(Vimeo 무DRM 스트림, Instagram
오디오, WAF)을 유저 본인 브라우저 로그인 세션으로 뚫고, 서버 차단 시 앱이 버티게 한다.

## INTENT

유저가 이미 로그인한 Edge/Chrome의 쿠키를 읽어, 그 사람이 볼 수 있는 콘텐츠를 그 사람
계정으로 받는다 (yt-dlp `--cookies-from-browser`와 같은 정당한 경로). 서버가 rate-limit/
봇체크로 막으면 지수 백오프로 재시도하고 쿠키 경로로 폴백한다. DRM 우회는 범위 밖(불가).

## 실측 근거 (2026-09-05, 리드)

- Vimeo 76979871: 로그아웃 config API는 전부 `/playlist/drm/cbcs`. 로그인 세션에선 평문
  HLS를 주는 경우가 많음(yt-dlp도 쿠키로 해결). 쿠키 없이는 우리도 yt-dlp도 못 받음.
- Instagram 릴: 로그아웃 DASH는 `has_audio=false`(무음). 로그인 세션은 오디오 포함 렌디션.
- TikTok: 같은 IP에서 요청 과다 시 WAF가 1.4KB 챌린지 대신 44KB 인터스티셜을 줌
  (현재 RATE_LIMITED로 분류됨). 쿨다운 + 쿠키가 완화.

## SCOPE

### 1. 로그인 세션 사용 = 브라우저가 자기 프로필로 로그인 (쿠키 복호화 안 함)

**방침 변경(2026-09-05): 쿠키 DB 직접 열기/DPAPI 복호화는 하지 않는다.** 그 기법은
인포스틸러 패턴이라 안전 분류기가 차단했고, 우리가 할 일도 아니다. 대신 헤드리스
브라우저가 **유저의 실제 로그인 세션으로 직접** 페이지를 열게 한다.

- `browser_capture` / `browser_page_fetcher` 실행 시, 빈 프로필 대신 **유저 프로필의
  복사본**을 `--user-data-dir`로 준다. 원본은 브라우저 실행 중 잠기므로 필요한 하위
  파일(`Default/Network/Cookies`, `Default/Login Data`가 아니라 쿠키만, `Local State`)
  을 임시 프로필 트리로 복사해 그걸 가리킨다. 브라우저가 자기 쿠키를 알아서 로드해
  로그인 상태로 뜬다. 우리는 쿠키를 읽지도 복호화하지도 않는다.
- 복사 실패/프로필 없음은 빈 프로필로 폴백(현재 동작). 크래시 금지.
- API: `BrowserProfile.stagedCopyFor(BrowserKind)` -> 임시 user-data-dir 경로(또는 null).
  finally에서 임시 트리 삭제.
- 이 경로가 안 통하는 순수 HTTP 추출기(youtube/twitter/tiktok/instagram/generic)는
  로그인 세션이 필요하면 자동으로 browser_capture 폴백으로 넘어가 거기서 로그인 이득을
  본다(이미 fall-through 존재). HTTP 추출기에 쿠키를 직접 주입하지 않는다.

### 2. 배선 + 설정 토글

- 설정에 "Use browser login session" 토글(기본 off, 개인정보 존중). off면 지금과 동일
  (빈 프로필). on일 때만 browser_capture/page_fetcher가 프로필 복사본을 쓴다.
- 어느 브라우저를 쓸지는 `BrowserExecutableLocator`가 고른 것과 동일 브라우저의 프로필.
- 보안: 우리는 쿠키 값을 메모리에도 안 올린다(브라우저만 봄). 임시 프로필 트리는
  캡처 종료 시 삭제. 프로필 경로/내용 로그 금지.

### 3. 회복력 `lib/core/net/retry_policy.dart`

- 지수 백오프(1s,2s,4s,8s, 지터) 재시도 래퍼. RATE_LIMITED/NETWORK/HTTP 429/503에만
  적용, PRIVATE/NOT_FOUND/DRM_PROTECTED엔 즉시 중단. 최대 4회.
- TikTok 추출기: WAF 인터스티셜 시 (a) 쿠키 있으면 쿠키로 재시도, (b) 백오프 후 재시도,
  (c) 그래도 실패면 registry 폴백(generic/browser capture)으로. 지금은 바로 RATE_LIMITED.
- 사용자 대면: 재시도 중 상태줄 "Retrying (rate limited by the site)...". 최종 실패 시
  what/why/next에 "try enabling the browser login session in Settings" 안내.

### 4. Vimeo/Instagram 재검증

- 쿠키 경로로 Vimeo 76979871이 평문 HLS를 주는지, Instagram 릴이 오디오 포함인지
  라이브 확인. (리드 계정 쿠키 사용, 회사 계정 절대 금지 - 개인/회사 분리 룰.)

## OUT OF SCOPE

DRM 복호화/화면 캡처(불가, 안 함), 계정 로그인 자동화(유저가 브라우저에서 이미 로그인),
Firefox 쿠키, 클라우드 동기화 쿠키.

## DONE

analyze 0 error / 테스트 그린 + 가드 실패 증명 / 쿠키 복호화 라이브 1건 이상 실증 /
쿠키 토글 off 시 기존 동작 불변 / 쿠키 값 로그 미노출 검증 / 400줄 / emdash 없음 /
회사 정보 없음.
