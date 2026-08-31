---
name: vestitel-events
description: Post an event ("something happened") from any app, script or agent into Vestitel, the macOS menu-bar inbox, via its Events drop folder or the vestitel://add URL scheme. Use when asked to notify Vestitel, send/post/push something to Vestitel, integrate an app (e.g. Ozonko) with Vestitel, or make a result show up in the Vestitel inbox.
---

# Posting events to Vestitel

Vestitel (macOS menu-bar inbox, source at ~/Projects/vestitel) accepts events
from local producers. Two transports, identical payload. Full human guide:
`docs/local-sources.md` in that repo.

## Payload

JSON object. Required: `source` (string, the feed name; keep it stable per
producer), `title` (string, one line). Optional: `url` (string), `summary`
(string), `image` (URL string), `published` (ISO 8601 string or Unix seconds
number; default = receipt time), `id` (dedupe key within the source; default =
url, then title). Unknown keys are ignored. Plain text only.

```json
{"source": "Ozonko", "title": "Kindle back in stock", "url": "https://www.ozone.bg/product/kindle", "id": "ozonko-4821"}
```

## Transport A: drop folder (preferred for anything recurring)

Folder: `~/Library/Application Support/Vestitel/Events/`
(a test instance started with `VESTITEL_STATE_DIR=<dir>` uses `<dir>/Events/`).

- A file is one event object OR an array of event objects; name must end in
  `.json`; dotfiles are ignored.
- MUST write atomically: write to a dotfile or temp path, then `mv` into the
  folder. Non-atomic writes get rejected as truncated JSON.
- Vestitel consumes within ~1 s, at launch, and on each refresh, then deletes
  the file. Invalid files move to `Events/Rejected/` (never retried).
- Works while Vestitel is quit (picked up at next launch).

```sh
dir="$HOME/Library/Application Support/Vestitel/Events"; mkdir -p "$dir"
tmp=$(mktemp "$dir/.event.XXXXXX")
printf '%s' '{"source": "Backup Script", "title": "Nightly backup finished"}' > "$tmp"
mv "$tmp" "$dir/$(date +%s)-$$.json"
```

Swift: `try data.write(to: dir.appendingPathComponent("\(UUID().uuidString).json"), options: .atomic)`.

## Transport B: URL (one-off pushes)

`vestitel://add?source=…&title=…[&url=…&summary=…&image=…&published=…&id=…]`,
values percent-encoded, one event per URL. Launches Vestitel if not running.

```sh
open "vestitel://add?source=Backup%20Script&title=Nightly%20backup%20finished&url=https%3A%2F%2Fexample.com"
```

Swift: build with `URLComponents` (scheme `vestitel`, host `add`, `queryItems`) and `NSWorkspace.shared.open(url)`.

If `open` reports no application for the URL, Vestitel.app has never been
launched on this Mac (or was rebuilt at a new path): launch it once, or run
`lsregister -f /path/to/Vestitel.app`.

## Semantics to rely on

- Each `source` becomes a feed of kind `local` (identity `vestitel://source/<slug>`,
  slug = lowercased name with non-alphanumerics collapsed to `-`). The user
  may rename it in Settings; posting under the original `source` still routes
  to it.
- Events enter the normal Inbox pipeline: unread → read (auto-clear 15 min
  after opening) → cleared (24 h) → purged; the `seen` map (30 days) suppresses
  re-posts with the same `id`. They sync to the user's other Macs.
- A source the user removed is re-created on the next post; the producer is
  the authority. Stop posting to silence it.
- Verify delivery: the item appears in the Inbox under the source; rejected
  files in `Events/Rejected/`; rejected URLs in
  `log show --last 5m --predicate 'subsystem == "com.strahil.vestitel"'`.
- Do not write to `state.json` to inject items; use these transports.
