# Emacs Client — macOS launcher app

A small compiled macOS app (**"Emacs Client.app"**) that bridges Finder / Dock /
Spotlight / drag-and-drop / `org-protocol://` to a running **emacsclient** daemon,
applying the macOS 14+ foreground-activation workaround so Emacs actually comes to
the front. It registers the relevant document types and the `org-protocol` URL
scheme with Launch Services.

It is a native Swift reimplementation of an `emacsgui` zsh script (inspired by the
emacs-plus project). The shell script and AppleScript applet are no longer part of
this repo — the Swift app is the single deliverable.

## Layout

| Path | Role |
|------|------|
| `Sources/EmacsClient/main.swift` | The whole app — one file. |
| `Package.swift` | SwiftPM executable target `EmacsClient` (macOS 12+). |
| `Info.plist` | Static bundle plist: UTIs, document types, `org-protocol` scheme, `LSUIElement`. Copied verbatim into the bundle. |
| `emacsclient-swift-build.sh` | Build + bundle + sign + register. The only build entry point. |
| `Assets.car` | Tahoe (macOS 26+) app icon (the emacs-plus "dragon"). |

SwiftPM produces only a bare executable; the `.app` bundle is assembled by the build
script (Info.plist + icon + `lsregister`).

## Build & install

```sh
./emacsclient-swift-build.sh
```

Installs to `~/Applications/Emacs Client.app` and registers it. Re-run after editing
`main.swift` or `Info.plist`. Useful overrides:

- `APP=...` — target bundle path (for side-by-side testing).
- `CONFIG=debug` — debug build (default `release`).
- `ICON_SRC=/path/to.icns` — optional pre-Tahoe `.icns`.

Quick compile check without bundling: `swift build -c release`.

There is no test suite. To verify behavior, launch it:
`open -a "$HOME/Applications/Emacs Client.app" somefile.org`, or right-click a file →
Open With. Note it talks to your Emacs daemon and steals focus, so it's disruptive to
run in a loop.

## How it works (main.swift)

Runs as an **`LSUIElement` / `.accessory`** app — invisible in the Dock, no menu bar
— that still receives open events and can activate another app. It does its one job
and calls `NSApp.terminate`.

Two entry points in `AppDelegate`:
- `application(_:open:)` — files (Open With / drag-drop) and `org-protocol://` URLs
  arrive together in one unified callback. File URLs become paths, scheme URLs are
  passed through verbatim.
- `applicationDidFinishLaunching` — bare launch (Dock / Spotlight). After a short
  ~60 ms hop (to let a pending open event win the race and avoid creating an empty
  frame *and* opening a file), it surfaces a frame.

Both funnel into `runEmacsGui(files:)`, the port of the shell logic:
1. **Frame check** — ask the daemon whether any frame is on a *graphical* display
   (`display-graphic-p` over `frame-list`). A daemon always keeps an invisible
   terminal frame, so counting frames would lie.
2. **Open / create** — `emacsclient -n [-c] <args>`; `-c` is added **only** when no
   graphical frame exists yet.
3. **Two-layer raise** (the macOS 14+ workaround):
   - *Window layer* — `(select-frame-set-input-focus (selected-frame))` so the daemon
     key-orders the right window.
   - *App layer* — macOS 14+ ignores `activateIgnoringOtherApps:` for a background app,
     so the daemon can't front itself. We do it from outside via Launch Services
     (`/usr/bin/open -a <bundle>`), which the OS honours as a user-initiated request
     targeting *another* app.
4. **Exact bundle** — the activated bundle is resolved from the daemon's own
   `invocation-directory` (this machine may host several `Emacs.app` builds sharing the
   `org.gnu.Emacs` id, so `open -a Emacs` / `open -b` would be ambiguous).

## Invariants / gotchas — don't break these

- **Use `posix_spawn`, never Foundation `Process`.** All subprocess spawns go through
  the `spawn(_:_:capture:)` helper. Foundation `Process` measured ~66 ms/spawn vs ~7 ms
  for `posix_spawn`; with ~4 emacsclient round-trips that was the bulk of launch
  latency. Reintroducing `Process` will make the app feel sluggish again. See the
  memory `foundation-process-spawn-tax`.
- `posix_spawn_file_actions_t` is an opaque pointer typedef on Darwin — declare it
  `var actions: posix_spawn_file_actions_t?` (optional), not `= posix_spawn_file_actions_t()`.
- **Candidate registration only.** Document types use the `Editor` role but the build
  does *not* force any default handler (no `LSSetDefaultRoleHandler`). This is
  deliberate: many emacs-plus Cellar copies ship their own `Emacs Client.app` with the
  same `org.gnu.emacsclient` id, and forcing defaults would fight them.
- **Activation is fire-and-forget.** Don't switch back to
  `NSWorkspace.openApplication`'s completion handler — blocking on it added ~200 ms
  before exit and risked delaying the activation itself.
- **emacsclient path** is `$EC` if set, else `~/.local/bin/emacsclient`. Same override
  the build pipeline uses.
- **Bundle id** `org.gnu.emacsclient`, executable name `EmacsClient` — must match
  `CFBundleExecutable` in `Info.plist`.

## File-type registration (Info.plist)

- **Custom imported UTIs** for Emacs types the system doesn't know by extension:
  `org.gnu.emacs.org-mode` (`.org`, `.org_archive`), `…emacs-lisp-source` (`.el`),
  `…lisp-data` (`.eld`), `…texinfo-source` (`.texi`, `.texinfo`).
- **Markdown** (`net.daringfireball.markdown`, `public.markdown`).
- **Broad catch-all** (`public.text`, `public.plain-text`, `public.source-code`,
  scripts, xml/json, `public.data`) so any plain-text/source file is still covered.
- **URL scheme** `org-protocol` for org-capture / org-roam.
