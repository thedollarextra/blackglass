# BlackGlass

A macOS notes app for a folder of Markdown files.

Your notes are plain `.md` files in a directory you choose — no database, no
sync service, no lock-in. BlackGlass reads and writes that folder directly, so
anything else that edits Markdown can edit the same notes.

Built with SwiftUI and AppKit. No third-party dependencies.

## What it does

**Vaults.** Point it at a folder and it becomes a vault. Multiple vaults are
supported; the sidebar switches between them.

**Markdown, Obsidian-flavoured.** Wiki links (`[[note]]`), embeds
(`![[note]]`), callouts, footnotes, and math blocks. Toggle between the raw
source and the rendered view with `⌘E`.

**Two searches.** A sidebar search that filters the tree, and an Omnisearch
palette over the whole vault. Both run against an in-memory index; a setting
decides which one `⌘K` opens, and either is always reachable from the
sidebar's toolbar.

**Graph view.** Notes as nodes, links as edges. Defaults to the neighbourhood
around the selected note rather than the whole vault, with an adjustable
depth and a global toggle. Optional 3D layout — shift-drag or two fingers to
orbit, pinch to dolly.

**A file tree that behaves like one.** Drag to move or reorder with insertion
lines, spring-loaded folders, multi-select, inline rename, and drag-in from
Finder (Markdown and text only, folders imported recursively).

**Serve to your phone.** An optional local HTTP server puts a web client on
your LAN, so the same vault is readable from a phone or another computer.
Off by default, and bound to localhost unless you say otherwise.

**Stays out of the way.** Optional menu bar mode and launch-at-login, so it
can live in the menu bar and open on a hotkey.

## Building

Requires macOS 14 or later and a Swift 6 toolchain (Xcode 16).

```bash
./build.sh
```

That compiles a release build, assembles `BlackGlass.app`, and ad-hoc signs
it. `./build.sh debug` for a debug build. The app is written to the repository
root; copy it to `/Applications` yourself.

Because the binary is ad-hoc signed rather than notarised, macOS will warn the
first time you open it — right-click the app and choose Open.

Build intermediates are kept outside the source tree (override with
`SCRATCH_PATH`), which matters if you keep the repository in a synced folder.

## Where it keeps things

Notes live in your vault folder and nowhere else. Application state — the
vault list, settings, and any manual sidebar ordering — lives in
`~/Library/Application Support/BlackGlass/`.

## Status

A personal project, developed in the open. It works, it is used daily, and it
carries no promises of stability, support, or backwards compatibility.

## Licence

MIT. See [LICENSE](LICENSE).
