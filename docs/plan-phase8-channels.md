# Phase 8: YouTube channel and playlist bulk download, subscriptions

Owner order (2026-11-22): download a whole channel at once, and download new uploads automatically.
Owner decision: automatic checks run only while the MiDa app is open (no Windows Task Scheduler entry).

## Goal

A user can paste a YouTube channel or playlist URL, see the list of its videos, and queue all or some of
them. A user can subscribe to a channel; while the app is open, MiDa checks subscribed channels on an
interval and queues uploads it has not downloaded before.

## Scope

1. Listing (core, pure Dart, no new dependencies):
   - Channel URLs: `youtube.com/@handle`, `/channel/UC...`, `/c/name`, `/user/name`, with or without
     `/videos`. Playlist URLs: `youtube.com/playlist?list=...` and `watch?v=...&list=...` (list only when
     the user asks for the playlist).
   - Use YouTube's own public web endpoints, as the existing YouTube extractor does (innertube browse with
     continuation for the full list; the public RSS feed `feeds/videos.xml?channel_id=` is acceptable for
     the "latest uploads" check). No login, no cookies, no challenge solving.
   - Output: ordered list of video ids, titles, published time when known. Bounded: hard cap on pages and
     items (configurable, default 500 items), fail closed on a malformed page.
2. CLI (additive contract):
   - `mida-cli list <url>`: result `kind: "list"` with `items: [{id, url, title, published}]`, plus
     `extractor`. Items are untrusted page data.
   - `mida-cli download <channel-or-playlist-url> --all [--limit N] [--archive FILE]`: downloads each item in
     order, one `result` per item plus a final summary `result` (`kind: "batch"`, counts); the archive file
     records downloaded video ids so a rerun skips them. Exit code: 0 when every attempted item succeeded,
     otherwise the most severe per-item class (policy 5 stays 5).
   - `mida-cli sync --subscriptions FILE`: for each subscribed channel, list the latest uploads and download
     those not in the archive. Same output shape as `--all`.
3. GUI:
   - Pasting a channel or playlist URL shows a selectable list (select all, select none, count) that adds
     the chosen videos to the existing download queue.
   - A "Subscriptions" screen: add or remove a channel, per-channel output folder or the default, check
     now, last checked time, and an interval setting (default 60 min, minimum 15 min). The check runs only
     while the app is open, and on app start if the last check is older than the interval.
   - New uploads found by a check go into the normal queue. Only uploads published after the subscription
     was created are queued automatically (no surprise download of a whole back catalogue).
   - Downloaded video ids are stored persistently (archive) so a video is never downloaded twice by the
     subscription path.
4. Docs: AGENTS.md CLI contract, `.claude/skills/mida-download/SKILL.md`, README, CHANGELOG under
   [Unreleased] or [2.4.0] per owner (version stays 2.4.0 unless the owner says otherwise).

## Out of scope

- Platforms other than YouTube for channel listing (later phases may add them).
- Running when the app is closed, tray icon, Windows startup entry, Task Scheduler.
- Members-only, private, age-gated or premium videos (report them with the existing policy codes).
- Live streams and Shorts-specific feeds (Shorts that appear in the uploads list are just videos).

## Constraints

- AGENTS.md hard rules: no yt-dlp, no new pub dependencies without a stated reason, files under 400 lines,
  no em-dashes, hermetic unit tests (fixtures captured from real pages, sanitized), no browser or network
  in tests.
- Rate: sequential item downloads, a short pause between items, back off on `RATE_LIMITED`, stop a batch
  after repeated policy refusals rather than hammering the site.
- Every string from the page (titles, handles) is untrusted data.

## Done criteria (observable)

1. `flutter analyze` 0 errors; `flutter test test/cli test/core test/features` all pass, 0 `Error:` lines;
   new parsers and the archive/skip logic each have a test that fails when the logic is removed.
2. Live (owner-approved, headless): `mida-cli list` on one public channel and one public playlist returns
   the expected video count range; `download --all --limit 3 --archive F` saves 3 files; rerunning the
   same command downloads 0 and reports 3 skipped.
3. `mida-cli sync` against a subscriptions file with one channel queues nothing on the first run after
   subscribing and downloads a new upload when one exists (verified with a fixture-backed test; live only
   if a fresh upload is available).
4. GUI: paste a channel URL, select 2 videos, both download through the queue; subscriptions screen
   persists across app restarts (verified by unit/widget tests plus one manual run reported by the owner).
5. astra-review verdict quoted; files under 400 lines; installer rebuilt, release asset replaced, installed
   on this PC and byte-compared.
