# How releases are made

Releases are cut from `main`, tagged `vX.Y.Z`, with an ad-hoc-signed app zip attached. v1.0.0 and v1.1.0 followed this process exactly.

1. **Version bump** — set both version keys in `Resources/Info.plist` (they use two-part versions, e.g. "1.1", even though tags are three-part):
   ```sh
   plutil -replace CFBundleShortVersionString -string "X.Y" Resources/Info.plist
   plutil -replace CFBundleVersion -string "X.Y" Resources/Info.plist
   ```
   Commit as `Bump version to X.Y` and push — the tag must point at a commit that contains the bump.

2. **Build and zip** — build *after* the bump so the plist inside the app is current:
   ```sh
   make app
   ditto -c -k --keepParent Vestitel.app Vestitel-X.Y.Z.zip
   ```
   Use `ditto` (not `zip -r`); it preserves the resource metadata codesign needs. Zip the asset outside the repo (scratchpad) — it must not be committed.

3. **Publish** — title `Vestitel X.Y.Z`, asset named `Vestitel-X.Y.Z.zip`:
   ```sh
   gh release create vX.Y.Z --target main --title "Vestitel X.Y.Z" \
       --notes-file <notes.md> Vestitel-X.Y.Z.zip#Vestitel-X.Y.Z.zip
   ```
   Write the notes to a file and use `--notes-file`; inline `--notes` with markdown code fences breaks shell quoting.

## Release notes format

Match the existing releases (see `gh release view v1.1.0`):

- One-sentence intro of the release theme.
- `## What's new` (or `## Features` for feature-list style) — bold lead-in per bullet.
- `## Requirements` — "macOS 14 (Sonoma) or later." unless `LSMinimumSystemVersion` changed.
- `## Installation` — keep the Gatekeeper section verbatim: the app is ad-hoc signed (no Apple Developer certificate), so first launch needs right-click → Open or `xattr -d com.apple.quarantine`. End with the build-from-source alternative (`make run`).

## Versioning

- New user-facing feature → minor bump (1.0 → 1.1). Fixes only → patch (tag v1.1.1, plist "1.1.1" is fine as three-part then).
- Tags and zip names are three-part (`v1.1.0`), plist values two-part (`1.1`) — that asymmetry is established, keep it.
