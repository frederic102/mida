# MiDa v2.0 Phase 3 - yt-dlp 완전 삭제 + 배포물 정리 (계약)

작성 2026-09-05. 전제: Phase 2b 배선 완료 (registry 가 모든 URL 을 네이티브 경로로 처리,
legacy backend 는 프로덕션에서 호출되지 않음이 테스트로 증명됨).

## INTENT

저장소, 빌드 스크립트, 인스톨러, 문서 어디에도 yt-dlp 가 남지 않게 한다. 오늘 만들었던
yt-dlp 자동 갱신 코드도 함께 삭제한다. 버전 2.0.0.

## SCOPE

1. 코드 삭제:
   - `lib/features/download/services/ytdlp_legacy_download_backend.dart` 와 그 참조
     (`download_service_io.dart` 의 주입 필드/게터, 라우팅 테스트의 가드는 "registry 외
     경로 없음" 으로 다시 쓰거나 삭제).
   - `lib/core/services/ytdlp_manager.dart`, `lib/core/services/ytdlp/` 전체,
     `lib/features/settings/widgets/engine_section.dart` 와 settings_screen 의 카드,
     `main.dart` 의 manager 부트스트랩/프로바이더, `test/core/services/ytdlp*` 전체.
   - `YoutubeDownloadPipeline` 래퍼: `test/live/lead_pipeline_live_test.dart` 를
     `MediaDownloadPipeline` API 로 옮긴 뒤 래퍼 삭제 (이 단계에서는 lead 파일 수정 허용).
2. 배포물: `scripts/download_binaries.ps1`, `scripts/download_binaries_mac.sh`,
   `scripts/build_windows.ps1`, `scripts/build_macos.sh`, `installer.iss` 에서 yt-dlp 다운로드
   /복사/패키징 라인 삭제. ffmpeg/ffprobe 는 유지. `windows_binaries/yt-dlp.exe` 파일 삭제
   (gitignore 대상이지만 로컬 정리). `.gitignore` 의 관련 주석 정리.
3. 문서: README 의 "powered by yt-dlp", "Bundled dependencies (yt-dlp, FFmpeg)", 의존성
   표, 라이선스 표기에서 yt-dlp 제거. 대신 "Requires Microsoft Edge or Google Chrome for
   some sites (Instagram, JS-only players)" 한 줄. CHANGELOG `[2.0.0]` 항목 (yt-dlp 제거,
   네이티브 추출기 YouTube/X/TikTok/Instagram + 범용 + 브라우저 캡처, HLS/DASH 직접).
   `docs/plan-ytdlp-auto-update.md` 는 폐기 표시 후 삭제. `docs/spikes/` 는 유지 (lint
   info 피하려면 `analysis_options.yaml` 에 `docs/**` exclude 추가).
4. 버전: `pubspec.yaml` 2.0.0+4, `installer.iss` AppVersion/OutputBaseFilename 2.0.0,
   settings_screen About 문자열 2.0.0 (pubspec 에서 읽는 구조면 더 좋지만 스코프 밖).
5. 검색 검증: `grep -ri "yt-dlp\|ytdlp\|yt_dlp" lib test scripts installer.iss README.md
   pubspec.yaml` 결과가 CHANGELOG 의 과거 항목과 이 문서/리서치 문서 외에는 0건.

## DONE

analyze error 0 / `flutter test` 그린 / `flutter build windows --release` 성공 / 위 grep 0건 /
`scripts/build_windows.ps1` 실행해 `dist/windows` 에 yt-dlp.exe 없음 + ffmpeg 있음 +
인스톨러 컴파일 (ISCC 있으면) 성공 / 400줄 / emdash 없음.
