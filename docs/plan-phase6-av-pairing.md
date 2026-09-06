# Phase 6 - A/V 페어링 + 캡 라벨 교정 (오더 다이제스트, 2026-09-06)

> 리드 소유 문서. 게이트: `MIDA_LIVE=1 MIDA_COVERAGE_MIN=0 /c/flutter/bin/flutter test
> test/live/lead_coverage_probe_test.dart` (32사이트, 약 20분). 단일 사이트 재현:
> `MIDA_LIVE=1 MIDA_VERBOSE=1 MIDA_SITES=ted,pinterest ...` (포맷 전체 + 미절단 에러 출력).

## INTENT

v2.2.0 게이트 19/32. "resolve 는 되는데 다운로드가 전부 실패" 5개 사이트를 실다운로드
성공으로 바꾼다. 사이트별 패치가 아니라 **파이프라인의 A/V 라벨 신뢰 모델**을 고친다.

## 재현 실측 (2026-09-06, 사이트당 1히트, 리드)

| 사이트 | 포맷 | 마지막 에러 | 근본 원인 |
|---|---|---|---|
| pinterest | 17 (HLS variant 10, mpd 1, mp4 6) | Output is missing its audio track | HLS 마스터의 `#EXT-X-MEDIA:TYPE=AUDIO` 렌디션 그룹을 버리고 variant(비디오 전용 미디어 플레이리스트)를 muxed 로 노출 |
| ted | 15 (HLS variant 14, mp4 1) | missing audio track | 동일. 3회 시도가 전부 HLS 형제라 muxed mp4 폴백(h=null 로 최하위)에 도달 못 함 |
| facebook | 6 (mp4 5, mpd 1) | missing audio track | 프로그레시브 mp4 가 실제로는 DASH 비디오 전용/오디오 전용 절반인데 muxed 라벨. `FacebookEfgDecoder` 가 이 URL 들에선 판정 못 함 (efg 부재 또는 태그 변경, Lane S 확인) |
| vimeo-public | 4 (mp4) | missing its **video** track | 동일 클래스. 첫 후보가 오디오 전용 CMAF mp4. height 전부 null 이라 순위 근거 없음 |
| niconico | 6 (HLS) | ffmpeg: Server returned 403 (media playlist `video-h264-360p.m3u8?session=..&Signature=..`) | 인증 클래스. 마스터는 열렸는데 미디어 플레이리스트가 403. 유력: 쿠키 유실 - `ExtractorRegistry._normalizeProtocols` (media_extractor.dart) 가 MediaInfo 재조립 시 `cookiesByDomain` 을 빠뜨림 (m3u8/mpd 를 내는 모든 추출기 영향) |

공통 결함 2개 (코드 확인):
- C1. HLS 마스터 -> 포맷 매핑이 `HlsPlaylistParser.parseMasterVariants` 만 쓰고 `EXT-X-MEDIA`
  오디오 렌디션과 variant 의 `AUDIO=` 그룹 속성을 무시 (captured_format_builder.dart,
  generic/format_expander.dart 둘 다).
- C2. `MediaDownloadPipeline._downloadAdaptivePair` 가 video/audio 절반을 둘 다
  `StreamDownloader` 로 받는다. 절반이 m3u8/mpd 이면 매니페스트 텍스트를 미디어로 저장.
  `_needsFfmpeg` 라우팅은 muxed 경로에만 있다.

## SCOPE (3 레인, 파일 펜스 disjoint, 병렬)

### 계약 (리드가 먼저 박아둔 스텁, 시그니처 변경 금지)
- `lib/core/download/mp4_track_sniffer.dart`: `Mp4TrackInfo`, `Mp4TrackSniffer.sniff(Uri, headers, {cookiesByDomain}) -> Future<Mp4TrackInfo?>`
- `lib/core/download/format_capability_resolver.dart`: `FormatCapabilityResolver.resolve(MediaInfo) -> Future<MediaInfo>`
- `download_outcome_verifier.dart`: `OutputTrackMismatchException({hasVideo, hasAudio, message})`
- `media_models.dart`: `MediaFormat.copyWith({videoCodec, audioCodec, width, height, contentLength, hasVideo, hasAudio, capabilitiesUnknown})`

### Lane P - HLS 오디오 렌디션 페어링 + ffmpeg 라우팅 + 교정 재시도 (sonnet)
소유: `lib/core/extractors/generic/hls_playlist_parser.dart`,
`lib/core/extractors/generic/format_expander.dart`,
`lib/core/extractors/browser_capture/captured_format_builder.dart`,
`lib/core/extractors/browser_capture/format_capabilities.dart`,
신규 `lib/core/extractors/generic/hls_master_format_mapper.dart` (공유 매퍼, DRY),
`lib/features/download/services/media_download_pipeline.dart`,
신규 `lib/features/download/services/adaptive_pair_downloader.dart` (400줄 캡 분리),
해당 테스트 파일들 (`test/core/extractors/generic/hls_playlist_parser_test.dart`,
`test/core/extractors/browser_capture/captured_format_builder_test.dart`,
`test/features/download/services/media_download_pipeline_*`, 신규 테스트).

P1. 파서: `HlsVariant` 에 `codecs`, `audioGroupId` 추가. 신규
`parseAudioRenditions(text, base)` -> `[HlsAudioRendition(groupId, uri, name, language, isDefault, channels)]`
(URI 없는 렌디션 = variant 에 오디오가 mux 됨 -> 제외). 기존 시그니처 유지.
P2. 공유 매퍼 `HlsMasterFormatMapper.formatsFor(masterUrl, text, {defaultCaps})`:
variant 가 URI 있는 오디오 그룹을 참조하면 `hasAudio=false` + `videoCodec` (CODECS 의
avc1/hvc1/av01/vp09 항목), 그 그룹의 렌디션마다 오디오 전용 m3u8 포맷 1개
(`audioCodec` = CODECS 의 mp4a/ec-3/opus 항목, 동일 URI 중복 제거, id `<master>#audio:<groupId>:<n>`).
오디오 그룹 없으면 기존 동작 (CODECS 기반 caps, 없으면 muxed). captured_format_builder 와
format_expander 둘 다 이 매퍼를 호출 (각자의 DRM 스캔/예산 로직은 그대로).
P3. 캡처 티어 직접 mp4/webm 후보: caps 가 `fromMimeType` 기본 추측이면
`capabilitiesUnknown: true` 로 표기 (Lane S 리졸버의 선택자).
P4. 파이프라인: (a) `resolve` 직후 `await _capabilityResolver.resolve(info)` (ctor 주입,
기본 `const FormatCapabilityResolver()`), 그 결과로 rank. (b) `_downloadAdaptivePair` ->
`AdaptivePairDownloader`: 절반이 `_needsFfmpeg` 이면 `HlsFfmpegDownloader.downloadVerified`
(`-c copy`, 비디오 절반은 `.mp4`, 오디오 절반은 `.m4a`; `aac_adtstoasc` 가 fMP4/비-AAC 에서
실패하는지 테스트로 확정하고 필요하면 bsf 를 `.ts` 세그먼트 입력일 때만) 아니면 기존
StreamDownloader. (c) 재시도 루프: `OutputTrackMismatchException` 을 잡으면 그 포맷을
`copyWith(hasVideo, hasAudio, capabilitiesUnknown: false)` 로 교정한 포맷 리스트로
**재-rank** 하고 계속 (이미 실패한 조합 제외, 총 시도 상한 `maxAttempts + 3`).
P5. 순위: `_rankByHeightThenBitrate` 는 손대지 않되, TED 처럼 한 마스터의 형제 variant 가
3회 시도를 독점하지 않도록 재-rank 가 (c) 로 해결되는지 테스트로 증명.

DONE: pinterest/ted 형 fake 마스터(오디오 그룹) -> 포맷이 video-only N + audio-only 1 로 나오고
selector 가 strict pair 를 1순위로 뽑고 두 절반이 ffmpeg 경로로 가는 단위 테스트. 가드 실패
테스트 필수 (매퍼를 끄면 빨개진다). 파이프라인 테스트: mismatch 예외 -> 교정 -> 페어 성공.

### Lane S - MP4 트랙 스니퍼 + 캡 리졸버 + 검증기 타입 예외 (sonnet)
소유: `lib/core/download/mp4_track_sniffer.dart`, `lib/core/download/format_capability_resolver.dart`,
`lib/features/download/services/download_outcome_verifier.dart`,
`lib/core/extractors/generic/facebook_efg_decoder.dart`, 해당 테스트
(`test/core/download/mp4_track_sniffer_test.dart` 신규, `format_capability_resolver_test.dart` 신규,
`test/core/extractors/generic/facebook_efg_decoder_test.dart`).

S1. 스니퍼: `HostPolicy.guardedRequest` 로 `Range: bytes=0-65535` GET (헤더 + 도메인 스코프 쿠키
`CookieScope.headerFor`). ISO BMFF 박스 워커 (32bit/64bit size, `ftyp`,`moov`,`trak`,`mdia`,`hdlr`
handler_type `vide`/`soun`, `tkhd` v0/v1 width/height 16.16 고정소수, `stsd` 첫 엔트리 fourcc ->
`videoCodec`/`audioCodec` 문자열: `avc1`,`hvc1`,`hev1`,`av01`,`vp09` / `mp4a`,`ec-3`,`ac-3`,`opus`).
`moov` 가 창 안에 없으면 null. 예외 절대 밖으로 안 냄. 200/206 둘 다 수락, 다른 상태 null.
S2. 리졸버: 선택자 = `capabilitiesUnknown && container in {mp4,m4a} && protocol == 'https'`.
상한 8개, 동시 3, 개별 4초. 성공 시 `copyWith(...)`, 실패 시 원본 유지. MediaInfo 재조립 시
**모든 필드 보존** (cookiesByDomain 포함).
S3. 검증기: 두 mislabel 케이스를 `OutputTrackMismatchException(hasVideo:, hasAudio:, message:)` 로
던진다 (메시지 문구 동일 유지). 기존 테스트 갱신.
S4. facebook efg: 라이브 URL 1회 (`MIDA_SITES=facebook MIDA_VERBOSE=1`) 로 efg 파라미터
존재/디코드 결과를 확인, 태그가 바뀌었으면 마커 갱신 + 픽스처 추가. 디코드가 안 되면
리졸버가 커버하므로 기록만.

DONE: 합성 fMP4 init (moov 앞) 바이트 픽스처로 vide/soun/크기/fourcc 파싱 테스트, moov 뒤
(non-faststart) null 테스트, 로컬 픽스처 서버로 Range 요청 + 사설 호스트 거부 테스트,
리졸버 상한/동시성/필드 보존 테스트.

### Lane N - niconico 403 + 레지스트리 쿠키 유실 (sonnet)
소유: `lib/core/extractors/niconico/*`, `lib/core/extractors/media_extractor.dart` 의
`_normalizeProtocols` 만, `test/core/extractors/niconico/*`, `test/core/extractors/media_extractor*`.
라이브 히트 상한: niconico 2회.

N1. `_normalizeProtocols` 가 `cookiesByDomain` 을 보존하도록 수정 + 가드 실패 테스트
(빠뜨리면 빨개진다).
N2. 실측: 어느 티어가 sm9 의 6포맷을 냈는지 (`MIDA_SITES=niconico MIDA_VERBOSE=1` 1회),
미디어 플레이리스트 403 의 원인 (domand 쿠키 미전파 / Referer / Origin / 세션 단일 사용).
니코니코 native 가 domand 접근권 응답의 Set-Cookie 를 `cookiesByDomain` 에 담고,
`requestHeaders` 에 `Referer: https://www.nicovideo.jp/` 를 넣는다. 세션 단일 사용이면
format 은 마스터 URL 하나만 노출하고 ffmpeg 가 마스터를 직접 열게 한다.
N3. 정책 준수: 쿠키는 우리 클라이언트가 받은 응답의 것만. 챌린지 풀기/지문 위조 금지.

DONE: 단위 테스트 그린 + niconico 1회 실다운로드 `DL ok` (Lane P 매퍼가 아직 없어 페어링이
막히면 그 지점까지 기록: "403 해소, 다음 에러 = X").

## 만지지 말 것 (전 레인)
`test/live/lead_*.dart`, `docs/coverage-corpus.md`, `extractor_registry_builder.dart`,
`format_selector.dart` (필요하면 리드에게 요청), 다른 레인 소유 파일, 계약 스텁 시그니처.
라이브 히트는 명시된 상한만. 400줄 캡. emdash 금지. 시크릿 없음.

## DONE (페이즈)
1. `flutter analyze` 0 error, `flutter test` 전체 그린.
2. 5사이트 재현 (`MIDA_SITES=vimeo-public,ted,facebook,niconico,pinterest MIDA_VERBOSE=1`)
   에서 최소 4/5 `DL ok`. niconico 는 403 해소를 최소선으로.
3. 풀 게이트 32 사이트 재실행, 회귀 0 (기존 19 유지) + 신규 성공 반영해
   `docs/coverage-corpus.md` Final measurement 갱신 (리드).
4. AEGIS 5석 + Codex 1회 -> PENTAD SHIP.

## 라운드 2 (2026-09-06, AEGIS + Codex 판결 NO-SHIP 반려분 수정)

라운드 1 판결: Bulwark DO-NOT-SHIP, Gadfly DO-NOT-SHIP, Vigil/Plumbline SHIP-WITH-CAVEATS,
Codex 19건. 2석 이상 DO-NOT-SHIP = NO-SHIP. 아래는 반려 사유 전부를 레인별로 재배정한 것.
라이브 히트·브라우저 실행은 전 레인 금지 (no-desktop-hijack.md). 판결 재소집은 라운드 2
착지 후.

### 리드 계약 (이미 트리에 있음, 시그니처 변경 금지)
- `MediaFormat.audioGroupId` (String?), `MediaFormat.audioPreference` (int, 0 DEFAULT / 1 AUTOSELECT / 2 기타, 기본 2)
- `MediaFormat.copyWith` 에 `protocol`, `audioGroupId`, `audioPreference` 추가. `withProtocol` 은 copyWith 위임.
- `MediaInfo.copyWith({formats, captions, requestHeaders, cookiesByDomain})` 신설. 손으로 재조립하는 곳 3개 전부 이걸로 교체.
- `DownloadOutcomeVerifier.verifyOutput(..., {Duration? expectedDuration})`
- `HlsFfmpegDownloader.downloadVerified(..., Duration? processTimeout)` -> `run` 에 전달.

### Lane P (페어링/셀렉터/파이프라인, sonnet) - 이번엔 `format_selector.dart` 소유
소유: hls_master_format_mapper.dart, hls_playlist_parser.dart, format_expander.dart,
captured_format_builder.dart, format_capabilities.dart, **format_selector.dart**,
media_download_pipeline.dart, adaptive_pair_downloader.dart, single_format_downloader.dart,
media_extractor.dart 의 `_normalizeProtocols` (MediaInfo.copyWith 로 교체만), 해당 테스트.
- P-R1 (Gadfly#1, 심각): 오디오 그룹의 렌디션이 전부 제외(DRM/누락)되어 오디오 포맷을 0개
  내면, 그 그룹을 참조하는 variant 는 라운드 1 이전처럼 muxed 로 되돌린다. 무음 파일이
  "성공" 으로 통과하는 회귀 차단. 가드 실패 테스트 필수.
- P-R2 (Codex#17, Gadfly#5): 매퍼가 `audioGroupId`/`audioPreference` 를 채운다. 셀렉터는
  video-only 와 audio-only 를 같은 audioGroupId (둘 다 null 포함) 끼리만 짝짓고, 오디오는
  audioPreference 오름차순 -> bitrate 내림차순.
- P-R3 (Codex#1): `rank` 가 페어를 1개만 내지 말고 순위 순으로 여러 페어를 열거 (비디오
  후보 x 그 그룹의 오디오 후보, 상한 6). 파이프라인의 재시도가 실제로 다른 페어를 시도하게.
- P-R4 (Codex#2): 파이프라인의 시도 키를 provider id 가 아니라 포맷 리스트 인덱스/identity
  로. 교정 시 같은 id 의 다른 포맷을 덮어쓰지 않는다.
- P-R5 (Codex#7): adaptive/single 다운로더가 ffmpeg 호출에 `processTimeout` 을 준다
  (duration 있으면 duration*4 + 5분, 없으면 60분). 걸리면 그 후보 실패로 루프 진행.
- P-R6 (Codex#18): captured_format_builder 의 매니페스트 읽기를 상한 (1MB) 스트리밍으로,
  초과 시 취소+close.
- P-R7 (Vigil#2): captured_format_builder 가 m4a 직접 후보도 `capabilitiesUnknown: true`.
- P-R8 (Gadfly#6b): `_rankAudio` 가 audio-only 후보 전부를 preference/bitrate 순으로 열거.
- P-R9: verifyOutput 호출에 `expectedDuration: currentInfo.duration` 전달. 파이프라인/
  레지스트리의 MediaInfo 재조립을 `MediaInfo.copyWith` 로.
- P-R10 (Plumbline F8): twitch_playlist_parser 는 손대지 않고 매퍼 doc 의 "유일" 주장 완화.

### Lane S (스니퍼/리졸버/검증기/니코니코 쿠키, sonnet)
소유: mp4_track_sniffer.dart, iso_bmff_reader.dart, format_capability_resolver.dart,
download_outcome_verifier.dart, output_stream_prober.dart, niconico_dmc_session_client.dart,
해당 테스트.
- S-R1 (Bulwark#2, Codex#4, 심각): 스니퍼가 리다이렉트 홉마다 `request.uri` 기준으로 쿠키를
  다시 스코프하고, 오리진이 바뀌면 Cookie/Authorization 류 헤더를 보내지 않는다. 리다이렉트
  픽스처 테스트 (다른 호스트로 302 -> 쿠키 없음 단언).
- S-R2 (Bulwark#3, Codex#8): 데드라인을 `sniff` 안으로. 만료 시 구독 취소 + client force close.
  리졸버의 동시성 상한이 실제로 지켜지도록 (느린 서버 픽스처로 소켓 수 단언).
- S-R3 (Vigil#1, Codex#9): 청크를 `min(chunk.length, window - total)` 만큼만 추가.
- S-R4 (Codex#13): 리졸버 선택자에 `uri.scheme == 'https'` 추가.
- S-R5 (Codex#10/#11/#12): 선언 크기가 창을 넘는 box, size 0 box 는 "불완전" 으로 표시하고
  불완전한 moov/trak 에서는 트랙 정보를 도출하지 않는다. 유효한 vide/soun 트랙이 하나도
  없으면 null (양쪽 false 로 포맷을 죽이지 않음).
- S-R6 (Bulwark#1, Codex#16, 심각): 니코니코 Set-Cookie 의 Domain 이 응답 호스트와 도메인
  매치 (호스트 자신 또는 그 상위, 최소 2 레이블 이상, `com`/`co.jp` 류 거부) 하지 않으면
  버린다. host-only 쿠키는 정확한 호스트로만.
- S-R7 (Gadfly#3): `verifyOutput` 이 `expectedDuration` 을 받으면 ffprobe `format=duration`
  과 비교, 90% 미만이면 `MediaMergeException` (절단). output_stream_prober 에 duration 조회 추가.
- S-R8: 리졸버의 MediaInfo 재조립을 `MediaInfo.copyWith` 로.

### Lane B (매니페스트 스캐너 + ffmpeg 다운로더 보안, opus)
소유: manifest_reference_scanner.dart, hls_ffmpeg_downloader.dart, 해당 테스트.
- B-R1 (Codex#5, Critical): 변형 플레이리스트 fetch 의 HostPolicy 거부를 삼키지 않고 재던진다.
  전송 오류만 계속. 가드 실패 테스트 (127.0.0.1 변형 -> 거부).
- B-R2 (Codex#6, Critical): 예산/깊이 초과 시 fail-closed. 중첩 마스터와 오디오 렌디션
  플레이리스트도 큐로 순회 (상한 내). 초과하면 거부.
- B-R3 (Codex#3): 쿠키가 붙는 매니페스트는 쿠키 스코프 밖 호스트를 참조하면 거부 (ffmpeg
  는 헤더를 전역 적용하므로 유출 경로). 세그먼트/키/맵/렌디션 전부.
- B-R4 (Codex#15, Gadfly#4, Plumbline F2): `segmentsAreTransportStream` 을 호출자가 안 주면
  스캔한 미디어 플레이리스트에서 자동 판정 (`#EXT-X-MAP` 또는 `.m4s/.mp4/.cmfa/.cmfv`
  세그먼트 = fMP4 -> bsf 없음, `.ts/.aac` = bsf). 파라미터는 유지하되 기본 자동.
- B-R5 (Codex#19): 헤더 이름은 RFC 토큰 문법만 허용, 아니면 거부 (strip 금지).
- B-R6: `processTimeout` 계약 유지 (이미 run 에 전달됨).

### Lane D (플레이크, sonnet)
소유: test/core/services/browser_devtools_session_test.dart (+ 필요 시 browser_devtools_session.dart
의 테스트 훅만). 실행마다 다른 테스트가 실패 (프로필 정리 / remote-debugging-address).
브라우저 실행 절대 금지. 10회 연속 그린으로 증명.

### 리드 후속
- 게이트 probe 라인에 duration/해상도 출력 (lead 파일).
- coverage-corpus.md: niconico 는 브라우저 캡처 경로로 통과 (native 는 사이트 개편으로
  PARSE_ERROR, Gadfly#2), facebook 은 로그인 월 (Lane S S4), vimeo 레인지 조각 원인.
- 풀 게이트 32 는 유저 승인 후에만.

## 라운드 3 (2026-09-06 저녁, AEGIS 라운드 2 판결 반려분)

라운드 2 판결: Vigil SHIP-READY, Bulwark SHIP-WITH-CAVEATS, Gadfly DO-NOT-SHIP, Codex 14건
NO-SHIP (Assay/Plumbline 은 집계 시 반영). 반려 사유를 블로커/비블로커로 나눠 3레인에
재배정. 브라우저·라이브·docker 금지. **테스트 실행 규율**: 레인마다 자기 디렉터리만,
마지막에 1회. 동시 3레인 이상 금지 (CPU 100% 회피). 백그라운드 실행 금지.

### 리드 계약 (트리에 있음)
- `MediaFormat.audioWasStripped` (bool, 기본 false) + `copyWith(audioWasStripped:)`.
  의미: "오디오가 없는데 그 이유가 소스가 원래 무음이라서가 아니다". 셀렉터 silent 티어는
  이 값이 true 인 포맷을 절대 받지 않는다.
- `HlsFfmpegDownloader.downloadVerified` 반환형 `Future<Duration?>` = 스캔에서 읽은 선언
  길이 (HLS `EXTINF` 합 / DASH `mediaPresentationDuration`), 못 읽으면 null. Lane B 가
  바꾸고 Lane P 가 페이크/파이프라인을 맞춘다.

### Lane P (셀렉터/매퍼/파이프라인, sonnet)
- P-R3-1 (Gadfly C1/C2, Codex #9/#14, 블로커): 무음 성공 경로 차단.
  (a) 매퍼: 참조한 오디오 그룹은 있는데 사용 가능한 렌디션이 0개면 variant 를
  `hasAudio=false, audioWasStripped=true` 로 낸다 (muxed 폴백 제거, CODECS 무관).
  (b) 파이프라인 `_correctedInfo`: mismatch 교정 시 `audioWasStripped: true`.
  (c) 셀렉터 silent 티어: `audioWasStripped` 인 포맷 제외. 결과적으로 "오디오를 주장했는데
  없음" 은 모든 후보 소진 -> `AllFormatCandidatesFailedException` 으로 **크게** 실패.
  (d) `media_download_pipeline_retry_test.dart` 의 라운드 2 에서 바꾼 두 테스트를 원래
  기대값 (예외 + "missing its audio track") 으로 복원. 가드 실패 테스트: Gadfly 시나리오
  (`CODECS="avc1..."` + 그룹 전부 제외 + FixedProber video only) -> 예외.
- P-R3-2 (Codex #10): `_rankPairs` 를 비디오 간 라운드로빈으로 (video1+audio1, video2+audio1,
  ..., 그다음 audio2). muxed 후보는 페어 3개 뒤에 인터리브. 상한 6 유지.
- P-R3-3 (Gadfly C4): 파서에 `CHARACTERISTICS`/`FORCED`/`LANGUAGE` 추가. 접근성/해설
  (`public.accessibility.*`) 또는 FORCED 는 audioPreference 3. 오디오 정렬은 인덱스 안정
  (preference, bitrate desc, 원래 index) 으로 명시. 2그룹 마스터에서 `audioCodec` 은 variant
  CODECS 의 오디오 fourcc 가 정확히 1개일 때만 채우고 아니면 null.
- P-R3-4 (Codex #13): loose 페어 (트랜스코드 필요) 의 절반은 중간 컨테이너를 `.mkv` 로.
- P-R3-5: `downloadVerified` 반환 `Duration?` 을 받아 `verifyOutput(expectedDuration:
  info.duration ?? declared)`. 페이크 2개 시그니처 갱신.
- P-R3-6 (Gadfly C7, Lane D 잔여): `browser_devtools_session_test.dart` kill-path 테스트에
  `expect(countAtThrow, greaterThan(0))` 추가, workDir 테스트별 분리.

### Lane S (스니퍼/리졸버/검증기/니코니코, sonnet)
- S-R3-1 (Codex #7, 블로커): 니코니코 Domain 쿠키를 `'.$domain'` 키로 저장 (host-only 만
  무접두). `CookieScope.headerFor` 가 sibling CDN 에 붙이는지 테스트.
- S-R3-2 (Codex #6): ISO BMFF 순회하는 모든 컨테이너/리프 박스 (mdia/minf/stbl/stsd/hdlr/tkhd)
  완전성 검사, 불완전이면 그 트랙 무시, 유효 트랙 0 이면 null.
- S-R3-3 (Codex #11): duration 90% 검사를 audio 다운로드에도 적용 (스트림 종류 검사만
  video 전용).
- S-R3-4 (Codex #12): 리졸버 워커는 `sniff` 가 실제로 client close 를 끝낸 뒤에만 다음
  작업. 외부 `.timeout` 제거, 데드라인은 `sniff` 내부 하나.
- S-R3-5 (Codex #8, 저위험): 퍼블릭 서픽스 리스트를 `co.uk/com.au/github.io/herokuapp.com`
  등 흔한 것으로 확장 + 3레이블 이상 요구 옵션. 클래스 doc 에 "니코니코 전용" 명시.

### Lane B (매니페스트 스캐너/ffmpeg 다운로더, opus)
- B-R3-1 (Codex #1/#4, Critical): 자식 플레이리스트 fetch 실패/비-2xx/`#EXTM3U`·`<MPD>`
  아님 -> 스캔 전체 거부 (fail-closed). 루트도 2xx + 셰이프 검사.
- B-R3-2 (Codex #2, Critical): 스캐너 fetch 도 홉마다 쿠키 재스코프 + 오리진 바뀌면
  Cookie/Authorization 제거 (S-R1 과 동일 규칙, 헬퍼 공유 가능하면 `lib/core/net/` 에).
- B-R3-3 (Codex #3): 스캔 전체 데드라인 (기본 30초), 만료 시 구독 취소 + force close.
- B-R3-4 (Codex #5): DASH 속성 정규식을 단일/이중 인용 모두 허용 + `&amp;` 류 엔티티
  디코드. 전체 XML 파서 도입은 범위 밖.
- B-R3-5 (Gadfly C5, 블로커): 쿠키 스코프 밖 참조가 있을 때 **거부 대신 쿠키 제거**:
  ffmpeg 헤더에서 Cookie 를 빼고 진행 (매니페스트 자체가 쿠키를 요구하면 ffmpeg 가
  정직하게 실패). 거부는 유지하지 않는다. 메시지는 유저 행동 가능한 문장으로.
- B-R3-6 (Gadfly C6): 바이트 예산을 플레이리스트당 (2MB) 으로, 전체 상한은 플레이리스트
  수 (48) 로만. 긴 VOD 픽스처 (12 variant x 400KB) 가 통과하는 테스트.
- B-R3-7: `downloadVerified` 가 `Duration?` 반환 (계약). 워커가 `EXTINF` 합 /
  `mediaPresentationDuration` 을 `ManifestScanResult.declaredDuration` 으로.

### 리드 후속
- Lane D 10회 결정성은 박스가 조용할 때 리드가 직접.
- 라운드 3 착지 후: 스코프 테스트 4트리 + analyze -> AEGIS 재소집 (셸 있는 에이전트로
  Bulwark 대체: code-reviewer 에 보안 브리프) -> PENTAD.

### 라운드 2 PENTAD 집계 (2026-09-06)
Vigil SHIP-READY / Bulwark SHIP-WITH-CAVEATS (셸 없어 S-R2·S-R6 flip 미증명) / Assay MISSING
(S-R6 flip RED 확인 직후 세션 한도 429 로 사망, 복원 미완 상태로 종료) / Plumbline DO-NOT-SHIP
(F1·F2 = Assay 가 꺼 둔 flip 킬스위치를 읽은 것, 리드가 복원 완료; F4·F7·F8 유효) /
Gadfly DO-NOT-SHIP / Codex 14건 NO-SHIP (비투표). Tally 1-1-2 + 1 missing -> **NO-SHIP**.
리드 사고: 복원 시 stale 백업 (라운드 1 시점) 으로 덮어써 라운드 2 스니퍼를 잃었다가 diff 출력에서
전문을 되살림 (analyze 클린, 34 테스트 그린). 교훈: 백업은 사용 직전 `diff` 로 시점 확인.

### Lane D 결정성 실측 (리드, 2026-09-06 16:30~16:40, 순차 10회)
9/10 그린. 실패 1회 = run 1 (83초, 라운드 3 레인 3개 기동 직후 CPU 스파이크), 이후 9회는
24~57초로 전부 그린. 결론: 로직 결함은 없고 부하 종속 타임아웃 잔존. P-R3-6 (kill-path
`countAtThrow > 0` 단언 + 테스트별 workDir) 착지 후 조용한 박스에서 10회 재실측이 DONE 조건.

### 라운드 3 착지 상태 (리드, 2026-09-06 18:10)
레인 3개 (opus) 가 16:33~16:52 사이 18개 항목을 전부 코드에 넣은 뒤 opus 세션 한도 (21:20 리셋)
로 사망. 죽은 지점: Lane P = P-R3-4 테스트 마무리 (코드·테스트 모두 트리에 있음), Lane B =
가드 flip 증명 착수 직전 (테스트는 트리에 있음), Lane S = 정상 완료 보고. 트리에 flip 잔재 없음.
리드 이음새: analyze 에러 0. download 250 / features/download 58 그린. extractors 669 중 1건
빨강 = `format_expander_audio_rendition_test.dart` 의 라운드 2 기대값 (전부-DRM 그룹 -> muxed)
이 P-R3-1(a) 계약 (video-only + audioWasStripped) 과 충돌. 리드가 기대값을 라운드 3 계약으로
수정 (레인 사망으로 인한 예외). 수정 후 관련 15 테스트 그린. 미완: 레인 자체 flip 증명
(P-R3-1/2, B-R3-1/2/5) 은 AEGIS 라운드 3 에서 셸 있는 석이 수행.
리드 재확인 (18:25, 조용한 박스): analyze 에러 0 (info 70, 기존 스타일). 스코프 실행 5트리 전부
그린: core/download 250, features/download 58, core/extractors 670, core/services 60 (devtools
포함), core/net 68 = 1106. "Error:" grep 0. AEGIS 라운드 3 는 sonnet 리셋 (19:30) 후 소집.
Codex 라운드 3 교차리뷰 진행 중.
리드 수령 검사 flip 증명 (18:05~18:15, 복사 백업 -> flip -> 테스트 -> 복사 복원 -> diff -q 무음):
- P-R3-1 셀렉터 silent 티어 `!f.audioWasStripped` -> `true`: silent_guard_test 1건 빨강. 복원 후 그린.
- B-R3-1 스캐너 2xx 검사 -> `if (false)`: fail_closed_test 2건 빨강 (404 variant, 404 root). 복원 후 그린.
- B-R3-5 쿠키 제거 `hostsOutsideCookieScope.isEmpty` -> `true`: cookie_containment_test 7건 빨강. 복원 후 그린.
나머지 flip (P-R3-2/3, B-R3-2/7, S-R3-2) 은 AEGIS Assay 라운드 3 에 배정.

### Codex 라운드 3 교차리뷰 (12건) 처리 (리드, 18:40)
반영 (리드 직접, 레인 사망 + 소규모):
- #1 블로커: `adaptive_pair_downloader.dart` 의 `declaredDuration ??= await _downloadHalf(audio)` 가 비디오
  절반이 길이를 돌려주면 오디오 절반 다운로드 자체를 건너뜀. 오디오 절반은 항상 받고 길이만 `??`.
  신규 `adaptive_pair_audio_half_test.dart` (2 테스트, flip 증명: 빨강 -> 복원 동일 -> 초록).
- #2 블로커: `format_capability_resolver.dart` 가 스니프로 오디오 부재를 확인해도 `audioWasStripped`
  를 안 세워 silent 티어로 세탁됨. 마커 추가. 신규 `format_capability_resolver_stripped_test.dart` (4).
- #4: muxed 인터리브를 2페어 뒤로 (`_pairsBeforeMuxed = 2`), 파이프라인 `maxAttempts = 3` 안에 진입.
보류 (라운드 4 후보, AEGIS 라운드 3 판결에 위임):
- #3 ffprobe 부재 시 claimed-audio 성공 허용 / #5 리다이렉트 후 base URI·홉 호스트 미반영 /
  #6 same-host 쿠키 Path/Secure 무시 / #7 ffmpeg 헤더에 Authorization 잔존 / #8 shape 검사 lookalike /
  #9 LL-HLS PART·PRELOAD-HINT·DASH Initialization sourceURL·Location 미스캔 / #10 stsd 샘플엔트리
  완전성 / #11 스니퍼 settle 이 cancel 완료를 안 기다림 / #12 variant 간 길이 불일치 시 declaredDuration.

### AEGIS 라운드 3 Plumbline (SHIP-WITH-CAVEATS) 처리
- #3 "셀렉터 페어링 로직을 리드가 썼나": 아니다. `format_selector.dart` 라운드 3 본문은 Lane P 가 16:36 에
  작성 (파일 mtime, 마커). 리드 변경은 `_pairsBeforeMuxed` 3 -> 2 와 그 주석뿐.
- #2 `niconico_extractor.dart` 는 Lane S (라운드 1 Lane N 이후) 소유로 펜스에 추가 (소급).
- #1 스니퍼의 `_sameOrigin`/`_isCredentialHeader` 사본 -> `PerHopCredentials` 로 통일: Bulwark 의
  flip 증명이 끝난 뒤 리드가 처리 (같은 파일군 동시 편집 회피).
- #4 상수 결합: `_pairsBeforeMuxed`/`maxAttempts` 교차 주석으로 연결 (라운드 4 또는 커밋 전 소규모).
- #5 400줄 근접 파일 3개 (scanner 393, selector 392, devtools 393): 분리 경계는 문서화, 이번 페이즈 미실행.
- #7 coverage-corpus 에 "4/5 는 라운드 3 코드로 재검증되지 않음" 문구 추가 예정 (리드).

## 라운드 4 (2026-09-06 저녁, AEGIS 라운드 3 반려분: 스캐너 리다이렉트/자격증명 + DRY)

라운드 3 판결 (진행 중 집계): Assay CAVEATS, Plumbline CAVEATS, Bulwark DO-NOT-SHIP, Codex NO-SHIP,
Vigil/Gadfly 대기. Bulwark #1/#2 (= Codex #5) 와 #3 (= Codex #7) 은 판결과 무관하게 닫아야 하는
보안 결함이라 선행 착수. 브라우저·라이브·docker 금지, 포그라운드만, 레인당 테스트 1회.

### 리드 계약
- `HostPolicy.guardedRequest(..., {void Function(Uri hop)? onHop})`: 홉 0 과 모든 리다이렉트 홉에서
  실제 요청한 URI 를 호출자에게 전달. 기존 호출부 무변경 (선택 파라미터).

### Lane B4 (스캐너/다운로더 보안, sonnet)
소유: manifest_reference_scanner.dart, manifest_reference_walker.dart, hls_ffmpeg_downloader.dart,
hls_ffmpeg_args.dart, 해당 테스트.
- B-R4-1 (Bulwark #1, Codex #5, Critical): 각 플레이리스트의 본문을 **마지막 홉 URI** 기준으로 파싱
  (`onHop` 로 받은 effective URI). 테스트: 루트가 다른 오리진의 `/path/final.m3u8` 로 302 하고 상대
  `seg.ts` 를 참조 -> 검사 대상이 `evil/path/seg.ts` 여야 함 (사설 호스트면 거부).
- B-R4-2 (Bulwark #2, Critical): 리다이렉트 홉 호스트도 `hostsOutsideCookieScope` 판정에 포함.
  테스트: 루트가 스코프 밖 CDN 으로 302 -> ffmpeg args 에 Cookie 없음.
- B-R4-3 (Bulwark #3, Codex #7): 스코프 밖 참조가 있으면 Cookie 뿐 아니라 Authorization /
  Proxy-Authorization 도 ffmpeg 헤더에서 제거 (`PerHopCredentials.isCredentialHeader` 재사용).
- B-R4-4 (Bulwark #4, Codex #8): shape 검사는 루트 요소 기준 (`#EXTM3U` 정확한 헤더 라인, XML 은
  첫 실제 요소가 `<MPD`). lookalike 픽스처 2개 거부 테스트.
- B-R4-5 (Bulwark #5, Codex #9): 워커에 `<Initialization sourceURL=...>`, `<Location>` (재배치 =
  플레이리스트 자식), `#EXT-X-PART`, `#EXT-X-PRELOAD-HINT` URI 추가.
- B-R4-6 (Codex #6, 저위험): same-host 단축 제거, 모든 참조를 `CookieScope.headerFor` 결과와 비교.
- B-R4-7 (Codex #12): variant 간 선언 길이가 10% 이상 다르면 `declaredDuration` null.

### Lane S4 (스니퍼/리졸버 DRY·정합, sonnet)
소유: mp4_track_sniffer.dart, iso_bmff_reader.dart, format_capability_resolver.dart, 해당 테스트.
- S-R4-1 (Plumbline #1, Bulwark #6): 스니퍼의 `_sameOrigin`/`_isCredentialHeader` 사본 삭제,
  `PerHopCredentials.apply` 사용. 기존 리다이렉트 테스트가 그대로 그린.
- S-R4-2 (Codex #11): `settle` 을 비동기로, `subscription.cancel()` 을 await 한 뒤 완료. 리졸버 워커는
  그 완료 후에만 다음 작업.
- S-R4-3 (Codex #10): `stsd` 샘플 엔트리를 박스로 파싱해 완전성 검사 후 fourcc 반환.

### 리드 후속 (커밋 전)
- Codex #3 (ffprobe 부재 시 claimed-audio 성공): 검증기에서 `selected` 가 audio 를 기대하면 실패.
  Lane S4 에 S-R4-4 로 추가.
- `_pairsBeforeMuxed`/`maxAttempts` 교차 주석 (Plumbline #4).
- 추가 (Gadfly 라운드 3, SHIP-WITH-CAVEATS): B-R4-8 = 쿠키 제거 사실을 `debugPrint` 가 아니라 `onStatus` 로
  유저에게 (Gadfly #2). B-R4-7 확장 = DASH 는 다운로드 대상 Period 기준, HLS 는 첫 큐 자식이 아니라
  선택 leaf 기준, 불일치 시 null (Gadfly #3). S-R4-4 = ffprobe `streamTypes == null` 이고 selected 가
  audio 를 기대하면 실패 (Gadfly #1, Codex #3). 리드 = retry 테스트에 "missing its audio track" 메시지
  단언 추가 (Gadfly #4).

### 라운드 3 PENTAD 집계 (2026-09-06 19:10)
Vigil SHIP-WITH-CAVEATS (리다이렉트 base URI, Authorization 잔존) / Bulwark DO-NOT-SHIP (동일 2건
Critical + Authorization) / Assay SHIP-WITH-CAVEATS (flip 5건 실제, 미테스트 경로 3) / Plumbline
SHIP-WITH-CAVEATS (스니퍼 DRY, 펜스 소급) / Gadfly SHIP-WITH-CAVEATS (ffprobe 부재 우회, 메시지,
declaredDuration 스코프) / Codex 12건 (비투표). Tally 0-4-1 -> **SHIP-WITH-CAVEATS**.
Chair 판결: 아키텍처와 핵심 결함 (무음 성공, 페어링, 쿠키 유실) 은 닫혔고 회귀 없음. 단 Bulwark 의
리다이렉트 2건과 Authorization 1건은 보안 표면이라 **릴리스 태그 전 필수** 후속으로 지정, 라운드 4
(Lane B4/S4) 로 즉시 착수. 커밋은 라운드 4 착지 + 리드 이음새 검증 후.

### 라운드 4 진행 (19:40)
- Lane B4 완료: B-R4-1..8 전부, flip 증명 3건 실행 (B-R4-1/2/3), core/download 282 + core/net 70 그린.
  신규 파일 `manifest_cookie_gate.dart` (123), `manifest_xml_utils.dart` (78) - 400줄 캡 분리.
- 리드: `onStatus` 를 adaptive/single 다운로더 -> `downloadVerified` 로 배선 (B-R4-8 후속), 페이크
  오버라이드 2개 + 테스트 서브클래스 1개에 파라미터 추가. features/download + core/net 133 그린.
- Lane S4 진행 중 (S-R4-1 PerHopCredentials 통일은 트리에 착지 확인, S-R4-2 비동기 settle 착지 확인).
- Lane S4 완료: S-R4-1..4 전부 (PerHopCredentials 통일, 비동기 settle, stsd 엔트리 완전성, ffprobe 부재
  시 claimed-audio 실패). 분리 파일 `download_outcome_verifier_ffprobe_unavailable_test.dart` 승인.
- 리드 이음새 (20:05): analyze 에러 0 (info 70). core/download 282, features/download 63, core/extractors
  670, core/services 60, core/net 70 = **1145 그린**. "Error:" 0, flip/백업 잔재 0. 변경분 400줄 초과 없음
  (기존 화면 3개 903/711/688 은 미접촉, 별도 과제). Bulwark/Vigil 라운드 4 재검토 진행 중.

### 라운드 4 판결 (2026-09-06 20:20)
Bulwark SHIP-READY (라운드 3 DO-NOT-SHIP 5건 전부 닫힘, Authorization strip flip 증명 실행, `<Location>`
미테스트 지적 -> 리드가 테스트 추가) / Vigil SHIP-READY (블로커 0, 스니퍼 데드라인 전용 테스트와
stsd entry_count 0 픽스처는 후속). Chair: 라운드 3 의 필수 후속이 전부 닫혔으므로 **페이즈 6 최종 =
SHIP** (커밋). 릴리스 태그는 32사이트 라이브 게이트 (브라우저 캡처, 유저 승인 필요) 재실행 후.
잔여 후속 (비차단): 스니퍼 데드라인 no-body 서버 테스트, stsd entry_count=0 픽스처, 취소 중 경로 테스트,
중복 format id 테스트, 화면 3개 400줄 초과 분리, vimeo 레인지 조각 원인, twitch 파서 매퍼 통일.
