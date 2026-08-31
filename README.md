# Vestitel

A menu-bar-only RSS reader for macOS. No Dock icon, no main window — everything
lives in a popover under a menu bar icon (the icon shows your unread count).

## Features

- **Add RSS/Atom feeds** in the Settings tab (paste any feed URL).
- **Inbox** shows article titles immediately; unread count in the menu bar.
- **Topic grouping** — articles about the same story are clustered across
  sources using keyword overlap plus Apple NaturalLanguage sentence embeddings.
  Toggle it or tune the sensitivity in Settings.
- **Click an article** → opens in your browser, is recorded in the Archive, and
  is marked read. Read articles auto-clear from the inbox after **15 minutes**.
- **Clear Inbox** moves everything to the Cleared tab, where articles remain
  recoverable (restore to inbox) for **24 hours** before being purged.
- **Copy link** — hover any article for a link button, or right-click for a
  context menu (open / copy link / mark read / clear / restore).
- **Archive** — a permanent record of every article you've opened.
- **Import/Export settings** — feeds + preferences as JSON, from Settings.
- **Start at login** — optional toggle in Settings (registers a login item).
- **Local sources**: other apps and scripts on the Mac can post "things that
  happened" into the Inbox through a drop folder or a `vestitel://add` URL.
  See [docs/local-sources.md](docs/local-sources.md).

## Build & run

Requires macOS 14+ and the Swift toolchain (Xcode Command Line Tools suffice).

```sh
make app   # builds .build/release and packages Vestitel.app
make run   # builds and launches it
make icon  # regenerates Resources/AppIcon.icns from Tools/make-icon.swift
```

To launch at login, enable **"Start Vestitel at login"** in the app's Settings
tab (uses `SMAppService`; also visible under System Settings → Login Items).

## Sending things to Vestitel from other apps

Any app or script on the Mac can post an event into the Inbox, either by
dropping a JSON file into `~/Library/Application Support/Vestitel/Events/` or
by opening a `vestitel://add?source=…&title=…` URL. The full guide, with the
event format and shell/Swift examples, is in
[docs/local-sources.md](docs/local-sources.md).

## Where data lives

`~/Library/Application Support/Vestitel/state.json` — feeds, articles, archive,
settings. Delete it to reset the app.

## Layout

```
Sources/Vestitel/
  VestitelApp.swift    MenuBarExtra entry point
  Models.swift         Feed / Article / ArchiveEntry / settings types
  AppStore.swift       state machine, fetching, timers, persistence, import/export
  FeedParser.swift     dependency-free RSS 2.0 / RSS 1.0 / Atom parser
  TopicGrouper.swift   cross-source topic clustering (union-find over
                       keyword-Jaccard + NL sentence-embedding links)
  Views/               popover UI (Inbox, Cleared, Archive, Settings)
Resources/Info.plist   LSUIElement=true (menu-bar-only)
```

## Behavior details

- Feeds refresh on launch and then every N minutes (configurable, default 15).
- A 30-second sweep timer promotes read→cleared (after 15 min) and purges
  cleared articles older than 24 h.
- Purged articles won't reappear on the next fetch — ingested article IDs are
  remembered for 30 days.
- Removing a feed drops its unread inbox articles but keeps read/cleared
  history and the archive.
