# Emacs Client

A small, fast macOS app that opens files in your running **Emacs daemon** and brings
Emacs to the front — from Finder, the Dock, Spotlight, drag-and-drop, or
`org-protocol://` links.

It's a compiled Swift launcher (inspired by [emacs-plus]) that talks to `emacsclient`
and works around the macOS 14+ behaviour that otherwise stops a background Emacs daemon
from coming to the foreground.

[emacs-plus]: https://github.com/d12frosted/homebrew-emacs-plus

## Features

- **Open With → Emacs Client** in Finder for text, source, Org, Emacs Lisp, Markdown,
  and more — files open in your existing Emacs frame.
- **Reuses your frame** instead of spawning a new one; creates a frame only when none
  exists yet.
- **Reliably raises Emacs** to the foreground (the two-step raise needed on macOS 14
  and later).
- **`org-protocol://`** support for `org-capture`, `org-roam`, and friends.
- **Invisible launcher** — no Dock bounce or stray icon; it does its job and quits.
- **Fast** — activation fires in roughly 130 ms (and ~70 ms when opening a file).

## Requirements

- macOS 12 or later.
- A running **Emacs server/daemon** with `emacsclient` available at
  `~/.local/bin/emacsclient` (or point `$EC` elsewhere — see [Configuration](#configuration)).
- The Swift toolchain (Xcode or Command Line Tools) to build.

Start a daemon if you don't already run one, e.g.:

```sh
emacs --daemon
```

## Install

```sh
./emacsclient-swift-build.sh
```

This compiles the app, assembles **`~/Applications/Emacs Client.app`**, and registers
it with macOS. Re-run it after pulling updates.

To install somewhere else:

```sh
APP="/Applications/Emacs Client.app" ./emacsclient-swift-build.sh
```

## Usage

- **Finder:** right-click a file → *Open With* → *Emacs Client*. To make it the default
  for a given type, use *Get Info* → *Open with* → *Change All…*
- **Dock / Spotlight:** launch *Emacs Client* to bring Emacs forward (opening a frame if
  needed).
- **Drag-and-drop:** drop files onto the app.
- **Command line:**

  ```sh
  open -a "Emacs Client" ~/notes.org
  ```

- **org-protocol:** links like `org-protocol://capture?...` are handed straight to Emacs.

## File types it handles

Org (`.org`, `.org_archive`), Emacs Lisp (`.el`, `.eld`), Texinfo (`.texi`,
`.texinfo`), Markdown (`.md`), and a broad catch-all for plain-text, source-code,
script, XML, and JSON files.

> The app registers as a **candidate** opener — it appears under *Open With* but does
> **not** hijack your existing defaults. You choose per type whether to make it the
> default.

## Configuration

| Variable | Used by | Meaning |
|----------|---------|---------|
| `EC` | the app at runtime | Path to `emacsclient` (default `~/.local/bin/emacsclient`). |
| `APP` | the build script | Where to install the `.app` (default `~/Applications/Emacs Client.app`). |
| `CONFIG` | the build script | `release` (default) or `debug`. |
| `ICON_SRC` | the build script | Optional `.icns` for macOS versions before 26. |

## Troubleshooting

- **Nothing happens / Emacs doesn't open.** Make sure the daemon is running
  (`emacsclient -e t` should print `t`) and that `emacsclient` is where the app expects
  it (`EC` / `~/.local/bin/emacsclient`).
- **It doesn't appear under "Open With".** Re-run `./emacsclient-swift-build.sh` (it
  re-registers with Launch Services). If macOS is still confused, log out and back in.
- **The wrong "Emacs Client" opens.** Some Emacs distributions (e.g. emacs-plus) ship
  their own `Emacs Client.app`. Remove the copies you don't want, then re-run the build
  script.
- **Emacs comes up but doesn't take focus.** This is exactly the macOS 14+ case the app
  handles via Launch Services; confirm you launched *this* app and not a stale copy.

## How it works

The app asks the daemon whether a graphical frame already exists, opens your files with
`emacsclient -n` (adding `-c` only when there's no frame yet), then performs a two-layer
raise: it tells Emacs which window to surface, and — because macOS 14+ won't let a
background daemon front itself — activates Emacs's exact app bundle through Launch
Services. It runs as an accessory app so it stays out of your way and exits immediately.

## License

See repository.
