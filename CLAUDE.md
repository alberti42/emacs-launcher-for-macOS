# Emacs Launcher — macOS launcher app

A small compiled macOS app (**"Emacs Launcher.app"**) that bridges Finder / Dock /
Spotlight / drag-and-drop / `org-protocol://` to a running **Emacs daemon**
(`emacs --daemon`), applying the macOS 14+ foreground-activation workaround so Emacs
actually comes to the front. It registers the relevant document types and the
`org-protocol` URL scheme with Launch Services.

It speaks the **Emacs server protocol directly over the daemon's local Unix socket**
(`Sources/EmacsLauncher/EmacsServer.swift`) — there is **no dependency on an
`emacsclient` binary**. It started as a native Swift port of an `emacsgui` zsh script
(inspired by the emacs-plus project); the shell script and AppleScript applet are no
longer part of this repo — the Swift app is the single deliverable.

It is intentionally distinct from emacs-plus's own **"Emacs Client.app"** — different
name *and* bundle id (`io.alberti42.EmacsLauncher`, not `org.gnu.emacsclient`) —
so the two coexist and a user can keep both.

## Layout

| Path | Role |
|------|------|
| `Sources/EmacsLauncher/main.swift` | App lifecycle, open-event / CLI handling, the two-exchange flow, activation. |
| `Sources/EmacsLauncher/EmacsServer.swift` | Native Emacs server-protocol client: socket-path resolution, `&`-quoting, send/parse. |
| `Package.swift` | SwiftPM executable target `EmacsLauncher` (macOS 12+). |
| `Info.plist` | Static bundle plist: UTIs, document types, `org-protocol` scheme, `LSUIElement`. Copied verbatim into the bundle. |
| `emacs-launcher-build.sh` | Build + bundle + sign + register. The only build entry point. |
| `Assets.car` | Tahoe (macOS 26+) app icon (the emacs-plus "dragon"). |

SwiftPM produces only a bare executable; the `.app` bundle is assembled by the build
script (Info.plist + icon + `lsregister`).

## Build & install

```sh
./emacs-launcher-build.sh
```

Installs to `~/Applications/Emacs Launcher.app` and registers it. Re-run after editing
the Swift sources or `Info.plist`. Useful overrides:

- `APP=...` — target bundle path (for side-by-side testing).
- `CONFIG=debug` — debug build (default `release`).
- `ICON_SRC=/path/to.icns` — optional pre-Tahoe `.icns`.

Quick compile check without bundling: `swift build -c release`.

There is no test suite. To verify behavior, launch it:
`open -a "$HOME/Applications/Emacs Launcher.app" somefile.org`, or right-click a file →
Open With. Note it talks to your Emacs daemon and steals focus, so it's disruptive to
run in a loop.

## How it works (main.swift)

Runs as an **`LSUIElement` / `.accessory`** app — invisible in the Dock, no menu bar
— that still receives open events and can activate another app. It does its one job
and calls `NSApp.terminate`.

`handleCLIFlags()` runs first in the entry point, *before* `NSApplication`: it prints
help/version to stdout and `exit`s for the exact tokens `-h`/`--help`/`-V`/`--version`
(exact-match only, so LS noise never trips it) — no AppKit, no Emacs contact.

Three ways work arrives, all funnelling into `runEmacsGui(targets:)`:
- `application(_:open:)` — files (Open With / drag-drop) and `org-protocol://` URLs
  arrive together in one unified callback. File URLs become paths, scheme URLs are
  passed through verbatim. Launch Services carries no line/column, so positions are nil.
- `applicationDidFinishLaunching` → `parseCommandLine()` — when the **binary is run
  directly** with file args (`EmacsLauncher [+LINE[:COLUMN]] FILE...`), emacsclient-style.
  A `+12:4`-type token sets the `-position` for the following file; args starting with
  `-` are skipped (LS/Cocoa noise). This is the *only* way a path on the command line is
  honoured — a path is invisible to the open-event path.
- `applicationDidFinishLaunching` (no CLI args) — bare launch (Dock / Spotlight). After
  a short ~60 ms hop (to let a pending open event win the race and avoid creating an
  empty frame *and* opening a file), it surfaces a frame.

An `OpenTarget` is `(arg, position?)`. `runEmacsGui(targets:)` does **two short socket
exchanges** with the daemon (each is one connect → send one `\n`-terminated line → read
the reply):
1. **Probe** — one `-eval` returning `(t/nil "<bundle path>")`: whether any frame is on
   a *graphical* display (`display-graphic-p` over `frame-list` — a daemon always keeps
   an invisible terminal frame, so counting frames would lie), plus the daemon's own
   `invocation-directory` for the exact bundle.
2. **Act** — `-nowait`, then `-current-frame` (reuse) **or** `-display ns -window-system`
   (create a graphical frame — the same thing `emacsclient -c` does on macOS, but only
   when none exists yet), then (per target) an optional `-position <pos>` and `-file
   <path>`, then an `-eval` doing the *window-layer raise*
   `(select-frame-set-input-focus (selected-frame))`.

Then the **app-layer raise** (the macOS 14+ workaround): macOS 14+ ignores
`activateIgnoringOtherApps:` for a background app, so the daemon can't front itself. We
do it from outside via Launch Services (`/usr/bin/open -a <bundle>`), which the OS
honours as a user-initiated request targeting *another* app. The exact bundle comes
from the probe's `invocation-directory` (this machine may host several `Emacs.app`
builds sharing the `org.gnu.Emacs` id, so `open -a Emacs` / `open -b` would be
ambiguous).

The wire protocol is line-based: space-separated tokens, values `&`-quoted (leading
`-`→`&-`, space→`&_`, newline→`&n`, `&`→`&&`); replies are `\n`-terminated
(`-emacs-pid`, `-print`, `-error`). See `EmacsServer.swift` and Emacs
`lib-src/emacsclient.c` for the reference.

## Invariants / gotchas — don't break these

- **Talk to Emacs over the socket, never by spawning `emacsclient`.** All daemon
  communication goes through `EmacsServer.send` (native AF_UNIX). There is intentionally
  no `emacsclient` binary dependency, and Foundation's `Process` is avoided everywhere
  (~66 ms/spawn vs ~7 ms for `posix_spawn`; see memory `foundation-process-spawn-tax`).
- **Local socket only.** `EmacsServer.socketPath()` resolves `$EMACS_SOCKET_NAME`, then
  `$XDG_RUNTIME_DIR/emacs/server`, then `<TMPDIR>/emacs<uid>/server` (macOS `TMPDIR` via
  `confstr(_CS_DARWIN_USER_TEMP_DIR)`, value 65537). TCP/`server-file` (remote, auth-key)
  setups are **not** supported by design — if you add them, port `set_tcp_socket` from
  `emacsclient.c`.
- **Activation uses `/usr/bin/open -a <bundle>`** via `posix_spawn`, fire-and-forget —
  the one remaining subprocess. Don't switch to `NSWorkspace.openApplication`'s
  completion handler (blocking on it added ~200 ms and risked delaying the activation).
  `posix_spawn_file_actions_t` is an opaque pointer typedef on Darwin — declare it
  `var actions: posix_spawn_file_actions_t?` (optional), not `= posix_spawn_file_actions_t()`.
- **Two distinct file inputs.** Launch Services `application(_:open:)` (Finder, drag,
  `open -a`, org-protocol) carries no position. The direct-binary path
  (`parseCommandLine`, `EmacsLauncher [+L[:C]] FILE…`) is the only one that reads `argv`
  and the only one with line/column. When testing the LS path use `open -a "Emacs
  Launcher" <file>`; when testing positions run the binary directly.
- **Distinct identity from emacs-plus.** Name **"Emacs Launcher"**, bundle id
  **`io.alberti42.EmacsLauncher`**, executable **`EmacsLauncher`** (must match
  `CFBundleExecutable` in `Info.plist` and the SwiftPM target). Do *not* revert to
  `org.gnu.emacsclient` / "Emacs Client" — that's emacs-plus's bundle and the whole
  point of the rename was to stop colliding with it.
- **Candidate registration only.** Document types use the `Editor` role but the build
  does *not* force any default handler (no `LSSetDefaultRoleHandler`) — we appear in
  "Open With" without hijacking the user's existing defaults.

## File-type registration (Info.plist)

- **Custom imported UTIs** for Emacs types the system doesn't know by extension:
  `org.gnu.emacs.org-mode` (`.org`, `.org_archive`), `…emacs-lisp-source` (`.el`),
  `…lisp-data` (`.eld`), `…texinfo-source` (`.texi`, `.texinfo`). These are *imported*
  declarations of types Emacs owns, so the `org.gnu.emacs.*` namespace is appropriate
  here (unrelated to the app's own bundle id).
- **Markdown** (`net.daringfireball.markdown`, `public.markdown`).
- **Broad catch-all** (`public.text`, `public.plain-text`, `public.source-code`,
  scripts, xml/json, `public.data`) so any plain-text/source file is still covered.
- **URL scheme** `org-protocol` for org-capture / org-roam.
