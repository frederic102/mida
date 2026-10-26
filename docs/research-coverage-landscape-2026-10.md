# 영상 다운로더 커버리지 지형도 (2026-10-25, competitive-analyst 보고, 리드 저장)

출처 표기: [S] 소스/원문 직접 열람, [V] 벤더 주장, [I] 추정.

## 결론
1. yt-dlp 의 폭(약 1,734 엔트리, broken 표기 136 = 7.8%)은 범용 스니퍼가 아니라 사이트별 추출기에서 나온다. generic 은 1개.
2. 싸게 폭을 늘리는 지렛대 = 임베드 플랫폼 계열 8~10개 (Brightcove, Kaltura, Wistia, JW Platform, Vimeo/Dailymotion/YouTube 임베드). 호스트 페이지에서 임베드를 찾아 그 플랫폼의 공개 플레이어 API 로 위임. MiDa 정책과 정확히 일치.
3. 상위 플랫폼(Facebook, Instagram, TikTok, Kick, VK, Weibo, Douyin)은 yt-dlp/cobalt 도 TLS 위장, PoW 풀이, 앱 UA 위장을 섞는다. 정책 내 유일한 길 = 정직한 실브라우저 캡처 + 매니페스트 스니핑.
4. 한국/일본은 공개 API 가 있어 네이티브 효율 최고 (Kakao TV, CHZZK, SOOP VOD, Naver TV, Niconico). 중국은 Douyin/Kuaishou 서명 벽, Bilibili(WBI 서명)/Weibo(가짜 fp) 는 회색.

## 경쟁 제품
- cobalt: 21개 서비스, generic 없음, 상위 플랫폼 집중. Facebook 은 페이지 HTML 의 `browser_native_hd_url/sd_url` 정규식 [S]. TikTok 은 `__UNIVERSAL_DATA_FOR_REHYDRATION__` SSR JSON [S]. Instagram 은 `/p/{id}/embed/captioned/` 가 정책 내 후보 [S].
- 4K Video Downloader: 제품 페이지 명시 10곳 + 내장 브라우저. JDownloader: 플러그인 엔진(캡차 OCR 은 정책 밖). IDM/Allavsoft: 브라우저 확장 스니퍼. VideoProc/SnapDownloader "1000+" 는 벤더 주장. 완전 범용은 없다.
- 브라우저 스니퍼(Video DownloadHelper 등): HLS/DASH 네트워크 감지, DRM/blob 비대상, 미지원 시 화면 캡처 폴백.

## 임베드 계열 공개 API (이식 1순위)
| 플랫폼 | API | 임베드 탐지 |
|---|---|---|
| Brightcove | `edge.api.brightcove.com/playback/v1/accounts/{acct}/videos/{id}`, `Accept: application/json;pk={policy_key}`; 키는 `players.brightcove.net/{acct}/{player}_{embed}/config.json` 의 `video_cloud.policy_key` | iframe `players.brightcove.net`, `<video data-video-id>` |
| Kaltura | `cdnapi.kaltura.com/api_v3/service/multirequest` 익명 `startWidgetSession` -> flavorAsset. `.wvm` 은 DRM | `kWidget.embed`, `cdnapi(sec).kaltura.com`, iframe `entry_id` |
| Wistia | `fast.wistia.net/embed/medias/{id}.json` | `wistia_async_`, `data-wistia-id`, iframe |
| JW Platform | `cdn.jwplayer.com/v2/media/{id}` | `content.jwplatform.com/players/{id}`, `data-video-jw-id` |
DRM 표지(`key_systems`, `.wvm`, `.ism`) 는 DRM 벽으로 보고.

## 플랫폼별 정책 내 기법 (요약, 40개 중 실행 후보)
- 쉬움 (공개 API/PAGE): Telegram 공개 채널 `t.me/<ch>/<id>?embed=1` `<video src>`; Rumble `rumble.com/embedJS/u3/?request=video&ver=2&v={id}`; OK.ru `data-options` JSON -> metadataUrl; Pinterest `resource/PinResource/get/` 익명; Kakao TV `api/v1/ft/playmeta/cliplink/{id}` + `katz/v1/ft/cliplink/{id}/readyNplay`; SOOP VOD `api.m.sooplive.com/station/video/a/view`; LinkedIn 공개 게시물 `<video data-sources>`; Xiaohongshu `__INITIAL_STATE__`; Reddit `.json` + v.redd.it DASH; X syndication `cdn.syndication.twimg.com/tweet-result`; Streamable, Loom, Bluesky, Rutube, Tumblr, Snapchat Spotlight.
- Facebook: PAGE (`browser_native_hd_url/sd_url`) + 로그인 벽 시 브라우저 캡처(로그인 세션 토글). 공개 영상만.
- 브라우저 캡처 전용: Kick, VK, Douyin, Weibo, Kuaishou, Instagram(embed 외).
- 회색(정책 결정 필요): Bilibili WBI 서명, Naver TV HMAC, TikTok PoW, VK 해시 챌린지, Weibo 가짜 fp. 현재 전부 제외 권장.
- WALL(제외): WeChat Channels, LINE VOOM, Netflix 류 DRM, Youku/iQiyi VIP.

## 로드맵 권고
1. 임베드 계열 + generic 파이프라인. 2. 브라우저 캡처 + 매니페스트 스니핑을 1급 경로로. 3. 네이티브 확장 순서: Telegram, Rumble, OK.ru, Pinterest, Kakao TV, SOOP VOD, Twitch, Reddit, Xiaohongshu, Niconico, (정책 결정 후) Naver TV, Bilibili, X syndication.
4. 유지보수: 추출기별 라이브 헬스 체크 + 자동 비활성화 장치.

## 불확실성
엔트리/broken 수는 수작업 집계. GUI 제품 엔진 정체 미확인. CHZZK/Bluesky/Rutube/Dailymotion 내부 API 미열람. 2026-10-25 master 기준이며 매주 바뀐다.
