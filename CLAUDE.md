# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Vestitel is a menu-bar-only macOS RSS reader (SwiftUI `MenuBarExtra`, no Dock icon, no main window). Built with SwiftPM + Command Line Tools only — there is no Xcode project and `xcodebuild` is not available. No external dependencies; no test target.

## Commands

```sh
make app    # swift build -c release + package Vestitel.app (ad-hoc signed)
make run    # make app + open Vestitel.app
make icon   # regenerate Resources/AppIcon.icns from Tools/make-icon.swift
swift build # debug build, fastest way to check for compile errors
```

The dev loop for verifying a change in the running app:

```sh
make app && pkill -f Vestitel.app/Contents/MacOS/Vestitel; sleep 1; open Vestitel.app
```

App state lives in `~/Library/Application Support/Vestitel/state.json`. Seeding or editing this file (while the app is quit) is the established way to set up test scenarios; deleting it resets the app. Setting `articles: []` and `seen: {}` while keeping `feeds` forces a full re-ingest on next launch (used to trigger the new-articles animation and re-parse with new fields).

UI verification is done by screenshotting the popover: open it via
`osascript -e 'tell application "System Events" to tell process "Vestitel" to click menu bar item 1 of menu bar 2'`
(this *toggles* — check `count of windows` first), read the window bounds via System Events, then `screencapture -x -R "x,y,w,h"`. All content sits under `group 1 of window 1`; the tab picker is `radio group 1` (Inbox=1 … Settings=5; when a store-watch feed exists a Store tab appears at index 2 and Settings becomes 6). Do NOT set text field values via AX (`set value of text field …`) — it bypasses SwiftUI bindings and buttons stay disabled; synthesize real clicks/typing with CGEvent instead.

## Architecture

Single module, `Sources/Vestitel/`. Everything runs on the main actor.

- **`AppStore`** — the one `ObservableObject`, injected as `@EnvironmentObject` everywhere. Owns all state, timers, fetching, persistence, and every user action. Views never mutate model data directly.
- **`Models.swift`** — plain Codable structs. `Article` moves through a state machine: inbox (unread → read via `readAt`) → cleared (`clearedAt`) → purged. Time-based transitions happen in `AppStore.sweep()` (30 s timer): read articles clear after 15 min, cleared articles purge after 24 h. A `seen` id→date map (30-day retention) prevents purged articles from re-ingesting.
- **`StorePageParser`** — regex HTML scraper for store product-listing pages (ozone.bg-style `product-box` cards), producing the same `ParsedFeed` shape as RSS. Feeds with `kind == .store` use it; `addFeed` falls back to it when RSS parsing fails. Store articles live in a separate Store tab (`store.storeInbox`, excluded from `inbox`/grouping), are never capped by `maxArticlesPerFeed`, and their `seen` entries are exempt from the 30-day pruning in `sweep()` — that permanence is the whole point: a cleared product must never re-ingest.
- **`FeedParser`** — dependency-free RSS 2.0/1.0/Atom parser on `XMLParser`. Namespace prefixes are stripped to local names, so `media:content` arrives as `"content"` (shared case with Atom's `<content>`, disambiguated by the `url` attribute).
- **`TopicGrouper`** — clusters same-story articles across sources: union-find over pairwise links from keyword-Jaccard (language-agnostic) OR NL sentence embeddings gated on ≥2 shared tokens (English only). Tokens drop <3-char words, numbers, and a bilingual (English + Bulgarian) stopword list of function words and news-rubric noise ("видео", "снимки", "млн", "breaking"…). Text inside quotes („…“, “…”, «…», "…") becomes a single phrase token, counted double in the shared-token shortcut — a shared quoted name is a strong same-story signal. Embeddings are expensive: vectors are memoized per title here, and the resulting group *structure* (ids, not Article values) is cached in `AppStore.groupCache`, invalidated by inbox-composition/sensitivity changes and warmed right after ingest. Don't call `TopicGrouper.group` from view code — go through `store.groupedInbox`.
- **`NotificationManager`** — local notifications (UserNotifications). One case today: a feed fetch answered with a bot-challenge page (`AppStore.looksBlocked`: `cf-mitigated` header, or 401/403/429/503 + HTML body) sets a readable `lastError` and posts a notification with an "Open Website" action; once per block episode per feed (`notifiedBlockedFeeds`, in-memory), identifier keyed by host so repeats replace. Authorization is requested lazily on first use. Banners aren't AX-clickable — verify delivery via `log show --predicate 'process == "usernoted"'`.
- **`MenuBarIcon`** — pre-rendered NSImage variants of the mascot (monochrome template / coloured / head-only-coloured × eyes-up / eyes-down-tilted, plus 16 animation frames × 2). State priority lives in `VestitelApp.menuBarLabel`: animation > colour signals (if `allowColoredIcon`) > monochrome; eyes-down whenever the inbox is non-empty. Monochrome variants are true template images (eyes/mouth are alpha punch-outs); partially-coloured variants can't be templates, so their waves use fixed mid-gray.
- **`SyncEngine`** — optional multi-Mac sync through any shared folder (Google Drive etc., set via `settings.syncFolderPath`). Each machine writes only its own `vestitel-<machineID>.json` and merges the others' on launch, after every refresh, on popover open, and whenever `SyncFolderWatcher` (FSEvents on the sync folder, 2 s coalescing, `IgnoreSelf` so our own writes don't re-trigger) sees another machine's file change — no file has two writers, so the transport can't conflict. Merge rules: unions everywhere; `seen` keeps the earliest date (never-show-again propagates); cleared beats inbox (restore loses across machines by design); deletions travel as tombstones (`removedFeeds`/`removedBookmarks`/`archiveClearedAt`) because absence is not a signal; remote feed ids are remapped to local ones by URL; a locally-seen id with no local article means "already purged here" and is never re-adopted. Settings stay per-machine. In `load()`, `settings` must be assigned last — its `didSet` fires `save()` → `writeSyncDocument()`, which must see the loaded `machineID`.
- **`SourcePalette`** — per-feed colours. Automatic assignment must stay deterministic for the same *set* of feed URLs: FNV-1a hash (Swift's `Hasher` is seeded per launch — never use it for anything persisted/displayed-stable) + CIELAB ΔE-aware slot probing in URL-sorted order. Manual `colorIndex` overrides always win.
- **`Views/`** — `ContentView` (header + tab switch + shared row components), `InboxView` (groups), `ClearedView` (also hosts Archive views), `BookmarksView`, `SettingsView`. `Tools/make-icon.swift` draws the app icon; keep it visually in sync with `MenuBarIcon`.

## Hard-won constraints (violating these reintroduces fixed bugs)

- **Swipe gestures**: `DragGesture` on a view that moves with its own offset MUST use `coordinateSpace: .global`; local space feeds the offset back into the translation and oscillates. Row/group swipe uses the "drop target" pattern: fixed-size pane at the destination edge, layered *above* the row, armed at 75% of `actionWidth`, commit on release while armed. The row gets an opaque `windowBackgroundColor` background while dragging so the pane never shows through. Clicks are detected inside the gesture (`dragIsHorizontal == nil` on end), not via `onTapGesture`.
- **Row layout is hover-invariant**: action buttons never appear/disappear in ways that reflow text — they fade via `opacity` with `allowsHitTesting` gated (`RowActionButton.visible`), or are always visible (`InlineActionButton` bar). The per-article clear × stays top-right regardless of card height.
- **Codable evolution**: every new persisted field must decode tolerantly — optional field, or `decodeIfPresent` with default in a custom `init(from:)` (`AppSettings` already has one; `PersistedState` uses optionals). A decode failure silently loses the user's entire state.
- **No ticking timestamps** in the UI: use `Date.articleDisplay` (absolute, time-only for today), never `Text(_, style: .relative)`.
- Articles ingested without a publish date get `published = fetch time` by design (displayed as "when it was added").
- `MenuBarExtra` label updates are driven by `@Published` changes on the store; the popover's `onAppear`/`onDisappear` set `popoverOpen` and acknowledge `hasUnseenArticles` — that's the only "is the app open" signal available.
- The whole-row tap on Settings toggle rows (`SettingRow.onTap`) is intentional; keep it when adding toggles, skip it for pickers.
