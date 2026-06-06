# Emacs Launcher

A small, fast macOS app that opens files in your running **Emacs daemon**
(`emacs --daemon`) and brings Emacs to the front — from Finder, the Dock, Spotlight,
drag-and-drop, or `org-protocol://` links.

It's a compiled Swift launcher (inspired by [emacs-plus]) that talks to the Emacs
daemon **directly over its local socket** — no `emacsclient` binary required — and
works around the macOS 14+ behaviour that otherwise stops a background Emacs daemon
from coming to the foreground.

[emacs-plus]: https://github.com/d12frosted/homebrew-emacs-plus

## Features

- **Open With → Emacs Launcher** in Finder for text, source, Org, Emacs Lisp, Markdown,
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
- A running **Emacs server/daemon** listening on its default local socket (the app
  connects to it directly; no `emacsclient` binary is needed).
- The Swift toolchain (Xcode or Command Line Tools) to build.

Start a daemon if you don't already run one, e.g.:

```sh
emacs --daemon
```

## Install

```sh
./emacs-launcher-build.sh
```

This compiles the app, assembles **`~/Applications/Emacs Launcher.app`**, and registers
it with macOS. Re-run it after pulling updates.

To install somewhere else:

```sh
APP="/Applications/Emacs Launcher.app" ./emacs-launcher-build.sh
```

## Usage

- **Finder:** right-click a file → *Open With* → *Emacs Launcher*. To make it the default
  for a given type, use *Get Info* → *Open with* → *Change All…*
- **Dock / Spotlight:** launch *Emacs Launcher* to bring Emacs forward (opening a frame if
  needed).
- **Drag-and-drop:** drop files onto the app.
- **Command line (via Launch Services):**

  ```sh
  open -a "Emacs Launcher" ~/notes.org
  ```

- **Command line (the binary directly), with optional line/column:** invoke the
  executable inside the bundle and pass files as arguments. An `emacsclient`-style
  `+LINE[:COLUMN]` token before a file jumps point there:

  ```sh
  "$HOME/Applications/Emacs Launcher.app/Contents/MacOS/EmacsLauncher" +12:4 ~/notes.org
  ```

  `+12` (line only) and plain paths work too; relative paths resolve against the
  current directory, and you can pass several `[+POS] FILE` pairs. (Note: a file path
  given to the **binary** is only honoured this way — passing it to `open -a` instead
  carries no line/column, since Launch Services has no notion of one.) Run it with
  `-h`/`--help` for usage, or `-V`/`--version`.

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
| `EMACS_SOCKET_NAME` | the app at runtime | Override the daemon socket (path, or a `server-name`). Defaults to the standard local socket. |
| `APP` | the build script | Where to install the `.app` (default `~/Applications/Emacs Launcher.app`). |
| `CONFIG` | the build script | `release` (default) or `debug`. |
| `ICON_SRC` | the build script | Optional `.icns` for macOS versions before 26. |

## Troubleshooting

- **Nothing happens / Emacs doesn't open.** Make sure the daemon is running and
  listening on its default local socket (`emacsclient -e t` should print `t`, or check
  for `$TMPDIR/emacs<uid>/server`). If you use a non-default socket, set
  `EMACS_SOCKET_NAME`.
- **It doesn't appear under "Open With".** Re-run `./emacs-launcher-build.sh` (it
  re-registers with Launch Services). If macOS is still confused, log out and back in.
- **Coexisting with emacs-plus.** emacs-plus ships its own separate `Emacs Client.app`;
  this app is **Emacs Launcher** with its own bundle id, so the two don't clash and you
  can keep both. Just pick *Emacs Launcher* in *Open With* / *Change All…* if you want
  this one to handle a file type.
- **Emacs comes up but doesn't take focus.** This is exactly the macOS 14+ case the app
  handles via Launch Services; confirm you launched *this* app and not a stale copy.

## How it works

The app connects to the Emacs daemon's local socket and speaks its protocol directly.
It asks whether a graphical frame already exists, opens your files (creating a frame
only when none exists yet), then performs a two-layer raise: it tells Emacs which window
to surface, and — because macOS 14+ won't let a background daemon front itself —
activates Emacs's exact app bundle through Launch Services. It runs as an accessory app
so it stays out of your way and exits immediately.

## License

MIT — see [LICENSE](LICENSE).
