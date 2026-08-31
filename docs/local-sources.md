# Sending things to Vestitel

Vestitel is a menu-bar inbox for "things that happened". Besides RSS feeds, it
accepts events from other apps and scripts running on the same Mac. There are
two ways to hand it an event; both end up in the same place: the Inbox, under
a source of your choosing, with the same read / clear / sync behaviour as any
article.

Pick the **drop folder** for anything that posts regularly or might post while
Vestitel is not running. Pick the **URL** for one-off pushes and shell scripts.

## The event

Whichever transport you use, an event is the same handful of fields:

| Field       | Required | Meaning |
|-------------|----------|---------|
| `source`    | yes      | Who is posting. Becomes the feed name in Vestitel ("Ozonko", "Backup Script"). Keep it stable: the same name always maps to the same feed. |
| `title`     | yes      | What happened, in one line. |
| `url`       | no       | Where clicking the item goes. Without it the item still shows, it just can't be opened. |
| `summary`   | no       | A sentence or two shown under the title. |
| `image`     | no       | Thumbnail URL. |
| `published` | no       | When it happened, as ISO 8601 (`2026-08-31T09:15:00Z`) or Unix seconds. Defaults to the moment Vestitel receives it. |
| `id`        | no       | Deduplication key within the source. Posting the same `id` twice adds one item. Defaults to `url`, then `title`. |

Unknown fields are ignored. Everything is plain text; HTML is not rendered.

## 1. Drop folder

Write a JSON file into

```
~/Library/Application Support/Vestitel/Events/
```

(Settings → Local Sources has **Show in Finder** and **Copy Path** buttons.)

The file holds one event:

```json
{"source": "Ozonko", "title": "Kindle Paperwhite back in stock",
 "url": "https://www.ozone.bg/product/kindle", "id": "ozonko-4821"}
```

or an array of events:

```json
[
  {"source": "Ozonko", "title": "Price drop: Steam Deck", "url": "https://…"},
  {"source": "Backup Script", "title": "Nightly backup finished", "published": 1756630000}
]
```

Any file name ending in `.json` works. Vestitel reads the folder within about
a second of a change, at launch, and on every feed refresh, then **deletes the
files it consumed**. A file that isn't valid JSON, or contains no usable event,
is moved to `Events/Rejected/` so you can see what went wrong; it is not
retried.

Because the folder is read at launch, events posted while Vestitel is quit are
not lost.

**Write files atomically.** Write to a temporary name (or another folder), then
rename into `Events/`. A file that is still being written when Vestitel reads
it would be rejected as truncated JSON.

From a shell:

```sh
dir="$HOME/Library/Application Support/Vestitel/Events"
tmp=$(mktemp "$dir/.event.XXXXXX")
printf '%s' '{"source": "Backup Script", "title": "Nightly backup finished"}' > "$tmp"
mv "$tmp" "$dir/backup-$(date +%s).json"
```

(Vestitel ignores dotfiles, so the temporary name is invisible until renamed.)

From Swift:

```swift
let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Vestitel/Events", isDirectory: true)
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let event: [String: Any] = ["source": "Ozonko", "title": title, "url": url.absoluteString, "id": productID]
let data = try JSONSerialization.data(withJSONObject: event)
// .atomic writes to a temp file and renames it into place
try data.write(to: dir.appendingPathComponent("\(UUID().uuidString).json"), options: .atomic)
```

## 2. URL

Open a `vestitel://add` URL with the same fields as query parameters:

```
vestitel://add?source=Ozonko&title=Kindle%20back%20in%20stock&url=https%3A%2F%2Fwww.ozone.bg%2Fproduct%2Fkindle
```

`source` and `title` are required; `url`, `summary`, `image`, `published` and
`id` are optional. Percent-encode the values. One URL carries one event.

If Vestitel isn't running, opening the URL launches it and the event is
delivered once it's up.

From a shell:

```sh
open "vestitel://add?source=Backup%20Script&title=Nightly%20backup%20finished"
```

From Swift:

```swift
var c = URLComponents()
c.scheme = "vestitel"; c.host = "add"
c.queryItems = [.init(name: "source", value: "Ozonko"),
                .init(name: "title", value: title),
                .init(name: "url", value: url.absoluteString)]
NSWorkspace.shared.open(c.url!)
```

The URL scheme is registered when Vestitel.app is first launched (or moved
into /Applications). If `open` complains that there is no application for the
URL, launch Vestitel once and try again.

## What happens in Vestitel

- Each distinct `source` appears as a feed in Settings, marked **LOCAL**. It
  can be renamed (the new name shows on its items) and given a colour like any
  feed. It has no refresh button: nothing is fetched, events are pushed in.
- Events land in the Inbox and behave like articles: clicking opens the `url`
  and marks the item read (it clears itself 15 minutes later), Clear Inbox
  clears them, cleared items stay recoverable for 24 hours, and topic grouping
  can cluster them with related articles.
- With sync between Macs on, local sources and their events sync too, so an
  event posted on one Mac shows up on the other.
- Removing a local source in Settings drops its unread items. If its producer
  posts again, the source comes back: the producer decides whether it exists.
  To silence a source for good, stop the app that posts to it.

## Checking that it worked

- The menu bar icon plays its arrival animation and the item appears in the
  Inbox under the source name.
- If a dropped file vanished from `Events/` but nothing appeared, look in
  `Events/Rejected/`.
- For URLs, Vestitel logs rejected ones:
  `log show --last 5m --predicate 'subsystem == "com.strahil.vestitel"'`.
