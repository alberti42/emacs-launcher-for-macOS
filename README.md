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
- **`emacs://` links** that open a file — optionally at a line and column — from
  Obsidian, Things, notes, anywhere macOS resolves URLs.
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

**Nothing is forced.** Installing only registers Emacs Launcher as a *candidate* handler —
for the relevant file types and for the `emacs://` and `org-protocol://` URL schemes. It
does **not** set itself as the default for any file type and never overrides a default
you've already chosen; your existing associations are left alone. To make it the default
*when you want to*:

- **File types** — pick it per type in Finder: *Get Info → Open With → Change All…*
- **URL schemes** — use the opt-in picker
  [`goodies/set-default-handler.swift`](goodies/) (see
  [Practical tips](#choosing-the-org-protocol--emacs-handler)).

(For a URL scheme that has no other valid handler, macOS may simply route it to the sole
candidate — there's nothing to override. The picker lets you choose deliberately whenever
alternatives exist.)

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
  Note: stock GNU Emacs (the Cocoa/NS build) registers only `mailto`, so `org-protocol`
  has **no handler out of the box** — Emacs Launcher provides it, replacing emacs-plus's
  separate `Emacs Client.app` helper. (The emacs-mac port patches it into its own
  `Emacs.app`, so there it simply coexists.)

## Linking to a file (`emacs://` scheme)

Emacs Launcher registers an `emacs://` URL scheme, so a *link* can open a file in Emacs —
optionally at a line and column:

```
emacs://file/<absolute-path>           open the file
emacs://file/<absolute-path>+42        …at line 42
emacs://file/<absolute-path>+42:5      …at line 42, column 5
```

The path is **percent-encoded** (spaces → `%20`; a literal `+` in a name → `%2B`, so it
can't be confused with the `+LINE:COLUMN` delimiter). `+LINE:COLUMN` is Emacs's own
position syntax. The app parses the URL itself and opens the file over the daemon socket
— **no Emacs configuration is required**.

Use it anywhere macOS resolves URL schemes — an Obsidian or Things link, a note, a
message:

```markdown
[foo.org, line 42](emacs://file/Users/andrea/notes/foo.org+42)
```

To *generate* these links, see [`goodies/`](goodies/): an AppleScript that copies a link
for the current Finder selection, and an Emacs command (`emacs-uri-copy`) that copies a
link to the current buffer at point.

> Unlike `org-protocol://` — which hands the URL to Emacs's Org library to interpret
> (capture, store-link, …) and needs Org configuration — the `emacs://` scheme is plain
> "open this file" and is handled entirely by the app.

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

## Practical tips

### Keep everything in one frame

Emacs Launcher already reuses your existing graphical frame and only ever creates a
frame when none exists. To make Emacs itself *place* a visited buffer nicely — reuse the
window already showing it, otherwise switch in the current window, rather than splitting
or popping — set `server-window`:

```elisp
;; Control where emacsclient shows a visited buffer: if it is already visible in
;; a window, select that window; otherwise switch to it in the current window.
;; This governs PLACEMENT, not frame creation.  It applies to requests that do
;; not create a frame (`emacsclient' / `emacsclient -n').  It does NOT suppress
;; `emacsclient -c': that frame is created in `server-process-filter' before
;; `server-window' is ever consulted, so a new frame still appears.
(defun my/server-switch-to-buffer (buffer)
  "Select the window already showing BUFFER, or switch in the current window."
  (let ((win (get-buffer-window buffer)))
    (if win
        (select-window win)
      (switch-to-buffer buffer))))
(setq server-window #'my/server-switch-to-buffer)
```

Emacs Launcher talks to the daemon over the `emacsclient` protocol, so this is the
setting that governs where your files land.

### If you instead open files with Emacs.app directly

This is **not needed if you associate files with Emacs Launcher** (the recommended
setup). It only matters if Finder's *Open With* points at the regular Emacs.app:

```elisp
;; Finder/macOS "Open with Emacs" does NOT go through emacsclient, so
;; `server-window' above does not apply to it.  It arrives as a native NS
;; Apple Event handled by Emacs's own open-file path, governed by
;; `ns-pop-up-frames'.  Its default `fresh' reuses the first frame but opens a
;; NEW frame for every subsequent file; nil always reuses the selected frame,
;; matching the single-frame workflow above.
(when (eq system-type 'darwin)
  (setq ns-pop-up-frames nil))
```

### Choosing the `org-protocol` / `emacs` handler

macOS routes a URL scheme to a single app, with **no GUI to choose**. The goodies script
lists the apps you can pick from for both schemes and sets one as the default:

```sh
swift goodies/set-default-handler.swift        # list, numbered (→ marks the current default)
swift goodies/set-default-handler.swift 01     # set option 01 as the default
swift goodies/set-default-handler.swift 01 02  # several at once, applied in order
```

This writes a reversible *user preference*; you do **not** deregister the other apps
(that wouldn't stick — they re-register themselves). The list is keyed by **bundle id**,
so it's often shorter than the raw registrations: emacs-mac's `Emacs.app` and emacs-plus's
`Emacs Client.app` are usually shadowed by id collisions, leaving Emacs Launcher the only
selectable handler for these schemes.

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

Emacs normally runs as a background **daemon** (`emacs --daemon`): one long-lived
process that has no window of its own. Your editing happens in *frames* — Emacs's word
for windows — that clients ask the daemon to open or reuse. Emacs Launcher is one such
client. Its job is to take a request from macOS (a file from Finder, an `org-protocol`
link, or a plain Dock/Spotlight launch), carry it out in that daemon, and bring Emacs to
the front. Here is what it does on each launch.

**1. It connects to the daemon.** The daemon listens on a Unix-domain socket — a special
file on disk, typically `$TMPDIR/emacs<uid>/server`. Emacs Launcher opens that socket and
speaks the Emacs server protocol directly. This is the same protocol the `emacsclient`
command-line tool uses, which is why the app needs no `emacsclient` binary installed.

**2. It checks whether a window is already open.** It asks the daemon whether any
*graphical* frame currently exists. This check matters because a daemon always keeps one
invisible terminal frame alive in the background, so naively counting frames would always
say "yes" and be misleading.

**3. It opens your files.** It asks the daemon to visit the file (or files) you gave it.
If a graphical frame already exists, the files open inside it; if none does, the app asks
the daemon to create one first. With no file at all, it simply makes sure a frame is on
screen.

**4. It brings Emacs to the front — and this takes two steps.** This is the tricky part,
and really the reason the app exists:

- *Inside Emacs:* it tells the daemon to select and raise the correct window, so the
  right buffer is the one you land on.
- *At the macOS level:* since macOS 14, the system no longer lets a **background** process
  push itself to the foreground — a deliberate anti-focus-stealing measure. Because the
  daemon is a background process, it can no longer bring its own window forward. So Emacs
  Launcher does it from the outside: it asks **Launch Services** (the macOS service that
  opens and activates apps) to bring Emacs forward. macOS honors this, because it is one
  app activating *another* app on the user's behalf — exactly the case the restriction
  still allows.

  It activates the **exact** Emacs app bundle the daemon is running from — which it asks
  the daemon to report — in case you have more than one `Emacs.app` build installed.

**5. It gets out of the way.** Emacs Launcher runs as an *accessory* app: no Dock icon,
no menu bar. It does this one job in a fraction of a second and then quits. All you see is
Emacs coming to the front.

## License

MIT — see [LICENSE](LICENSE).
