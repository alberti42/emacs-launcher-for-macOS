# Emacs Launcher for macOS

A small, fast macOS app that opens files in your running **Emacs daemon** (`emacs --daemon`) and brings Emacs to the front — from Finder, the Dock, Spotlight, drag-and-drop, `emacs://` links (open a file, optionally at a line and column), or `org-protocol://` links.

It's a compiled Swift launcher (inspired by [emacs-plus]) that talks to the Emacs daemon **directly over its local socket** — no `emacsclient` binary required — and works around the macOS 14+ behaviour that otherwise stops a background Emacs daemon from coming to the foreground.

[emacs-plus]: https://github.com/d12frosted/homebrew-emacs-plus

## Features

- **Open With → Emacs Launcher** in Finder for text, source, Org, Emacs Lisp, Markdown, and more — files open in your existing Emacs frame.
- **Reuses your frame** instead of spawning a new one; creates a frame only when none exists yet.
- **Reliably raises Emacs** to the foreground (the two-step raise needed on macOS 14 and later).
- **`org-protocol://`** support for `org-capture`, `org-roam`, and friends.
- **`emacs://` links** that open a file — optionally at a line and column — from Obsidian, Things, notes, anywhere macOS resolves URLs.
- **Invisible launcher** — no Dock bounce or stray icon; it does its job and quits.
- **Fast** — activation fires in roughly 130 ms (and ~70 ms when opening a file).

## Requirements

**To run the app** (the [prebuilt download](#install) — no toolchain needed):

- macOS 12 (Monterey) or later.
- **Emacs**, run as a **daemon** (`emacs --daemon`). The app talks to a running Emacs server over
  its local socket — it does not start Emacs itself, and needs no `emacsclient` binary. Any
  reasonably recent Emacs works (the only requirement is daemon/server support). To have a daemon
  start automatically and stay up, see
  [Keeping a daemon running](#keeping-a-daemon-running-launchagent).

**To build from source** (only if you [build it yourself](#manual-installation-build-from-source) instead of downloading):

- The Swift toolchain — Xcode or the Command Line Tools (`xcode-select --install`).
- Optionally **full Xcode**, so `actool` can compile the Tahoe icon; without it the build falls
  back to the committed prebuilt icon.

## Install

**Download the latest release** — a **universal** (Apple Silicon + Intel), Developer ID-signed and **notarized** build, so it opens with no Gatekeeper warning and needs no build toolchain:

1. Download the `Emacs Launcher.app` zip from the [latest release](https://github.com/alberti42/emacs-launcher-for-macOS/releases/latest).
2. Unzip it and drag **Emacs Launcher.app** to `~/Applications` (or `/Applications`).
3. Run it once so macOS registers the file-type and `emacs://` / `org-protocol://` URL-scheme associations.

**Nothing is forced.** Running the app only registers Emacs Launcher as a *candidate* handler — for the relevant file types and for the `emacs://` and `org-protocol://` URL schemes. It does **not** set itself as the default for any file type and never overrides a default you've already chosen; your existing associations are left alone. To make it the default *when you want to*:

- **File types** — pick it per type in Finder: *Get Info → Open With → Change All…*
- **URL schemes** — use the opt-in picker
  [`goodies/set-default-handler.swift`](goodies/) (see
  [Practical tips](#choosing-the-org-protocol--emacs-handler)).

For a URL scheme that has no other valid handler, macOS may simply route it to the sole candidate — there's nothing to override. The picker lets you choose deliberately whenever alternatives exist.

### Manual installation (build from source)

Prefer to compile it yourself? Build the app from source (see [Requirements](#requirements)):

```sh
./emacs-launcher-build.sh
```

This compiles the app, assembles **`~/Applications/Emacs Launcher.app`**, registers it with macOS, and (re-run after pulling updates) keeps it current. See [Configuration](#configuration) for build options — universal builds, signing identity, icon selection.

### Cutting a release (maintainers)

To release version `X.Y.Z`:

1. **Bump the version** — set `CFBundleShortVersionString` in `Info.plist` to `X.Y.Z`.
   Note: CI overrides the bundle version from the tag, so this is mainly to keep the
   source tree in sync with the released artifact.
2. **Write the changelog** — add `release-notes/vX.Y.Z.md`; its contents become the body
   of the GitHub release.
3. **Commit, tag, and push:**

   ```sh
   git commit -am "Release vX.Y.Z"
   git tag vX.Y.Z
   git push --follow-tags
   ```

Pushing the `vX.Y.Z` tag triggers [`.github/workflows/release.yml`](.github/workflows/release.yml), which builds the universal binary, signs it with the Developer ID, notarizes and staples it, and creates a **draft** GitHub release with the zip attached. Review the draft and click **Publish**.

### Configuration

#### Build options

The build script reads a few environment variables — set them by prefixing the build command. For example, install into `/Applications` instead of `~/Applications`:

```sh
APP="/Applications/Emacs Launcher.app" ./emacs-launcher-build.sh
```

…or make a debug build with a pre-Tahoe icon:

```sh
CONFIG=debug ICON_SRC=~/icons/emacs.icns ./emacs-launcher-build.sh
```

| Variable | Default | Meaning |
|----------|---------|---------|
| `APP` | `~/Applications/Emacs Launcher.app` | Where to install the `.app`. |
| `CONFIG` | `release` | `release` or `debug`. |
| `ICON_NAME` | `dragon-plus` | Which `assets/icons/<name>.icon` to compile (see [Icon](#icon)). |
| `ICON_SRC` | — | Optional `.icns` for macOS versions before 26. |
| `UPDATE_PREBUILT` | — | `1` to also refresh the committed icon fallback (see [Icon](#icon)). |
| `UNIVERSAL` | — | `1` to build a fat **arm64 + x86_64** binary (see [below](#universal-build)). |
| `SIGN_ID` | `-` (ad-hoc) | codesign identity. A `Developer ID Application: …` value adds the hardened runtime + secure timestamp for notarization. |
| `REGISTER` | `1` | `0` skips the Launch Services registration (used by CI, where it's pointless). |

#### Universal build

By default `swift build` compiles only for the **host architecture** — an `arm64`-only app on Apple Silicon, `x86_64`-only on Intel. That's the right choice when you build on each machine you use. To instead compile **once and copy the app to machines of either architecture**, build a universal binary with `UNIVERSAL=1`:

```sh
UNIVERSAL=1 ./emacs-launcher-build.sh
```

Verify it:

```sh
lipo -archs "$HOME/Applications/Emacs Launcher.app/Contents/MacOS/EmacsLauncher"
# arm64 x86_64
```

Building for `x86_64` requires that architecture's SDK slice, which a standard Xcode / Command Line Tools install provides.

#### Runtime: the daemon socket

By default the app connects to Emacs's standard local socket (`$TMPDIR/emacs<uid>/server`).  If your daemon listens elsewhere — a custom path, or a named server started with `(setq server-name "foo")` / `emacs --daemon=foo` — point the app at it with **`EMACS_SOCKET_NAME`**.

Apps launched from Finder, the Dock, or Spotlight don't inherit the variables you set in your shell, so an `export` in `.zshrc` won't reach them. Set it where launchd agents pick it up instead (this takes effect after your next login):

```sh
launchctl setenv EMACS_SOCKET_NAME foo
```

`launchctl setenv` doesn't survive a logout, though. To make it permanent — and to keep the daemon and the app in agreement — set it on the [daemon LaunchAgent](goodies/#ioalberti42emacs-daemonplist--keep-the-daemon-running) itself, by adding an `EnvironmentVariables` dict to its plist:

```xml
<key>EnvironmentVariables</key>
<dict>
    <key>EMACS_SOCKET_NAME</key>
    <string>foo</string>
</dict>
```

Equivalently, name the server on the daemon's command line with `emacs --daemon=foo`.

For command-line use (running the binary directly), exporting it in your shell is enough:

```sh
export EMACS_SOCKET_NAME=foo
```

## Usage

**Recommended setup:** make **Emacs Launcher** the default for the file types you normally edit in Emacs (text, source, Org, Emacs Lisp, Markdown, …) — *Get Info → Open with → Change All…* on a file of each type. This isn't about Emacs Launcher claiming those types for its own sake; it's that opening them through Emacs Launcher always routes the file into your **running daemon session** (reusing your frame, near-instantly). Associating them with the regular Emacs.app instead starts a *separate, standalone* Emacs whenever no frame is open — see [If you instead open files with Emacs.app directly](#if-you-instead-open-files-with-emacsapp-directly).

- **Finder:** right-click a file → *Open With* → *Emacs Launcher* (or set it as the default for that type as above).
- **Dock / Spotlight:** launch *Emacs Launcher* to bring Emacs forward (opening a frame if needed).
- **Option-launch:** hold **⌥ Option** while launching the app (no file) to open the *daemon LaunchAgent* panel — install it (so a daemon starts at login and stays up), or uninstall it if it's already installed. See [Practical tips](#keeping-a-daemon-running-launchagent).
- **Drag-and-drop:** drop files onto the app.
- **Command line (via Launch Services):**

  ```sh
  open -a "Emacs Launcher" ~/notes.org
  ```

- **Command line (the binary directly), with optional line/column:** invoke the executable inside the bundle and pass files as arguments. An `emacsclient`-style `+LINE[:COLUMN]` token before a file jumps point there:

  ```sh
  "$HOME/Applications/Emacs Launcher.app/Contents/MacOS/EmacsLauncher" +12:4 ~/notes.org
  ```

  `+12` (line only) and plain paths work too; relative paths resolve against the current directory, and you can pass several `[+POS] FILE` pairs. (Note: a file path given to the **binary** is only honoured this way — passing it to `open -a` instead carries no line/column, since Launch Services has no notion of one.) Run it with `-h`/`--help` for usage, or `-V`/`--version`.

- **emacs:** links like `emacs://file/Users/you/notes.org+42:5` open a file at an optional line/column — see [Linking to a file](#linking-to-a-file-emacs-scheme) below.
- **org-protocol:** links like `org-protocol://capture?...` are handed straight to Emacs.  Note: stock GNU Emacs (the Cocoa/NS build) registers only `mailto`, so `org-protocol` has **no handler out of the box** — Emacs Launcher provides it, replacing emacs-plus's separate `Emacs Client.app` helper. (The emacs-mac port patches it into its own `Emacs.app`, so there it simply coexists.)

## Linking to a file (`emacs://` scheme)

Emacs Launcher registers an `emacs://` URL scheme, so a *link* can open a file in Emacs — optionally at a line and column:

```
emacs://file/<absolute-path>           open the file
emacs://file/<absolute-path>+42        …at line 42
emacs://file/<absolute-path>+42:5      …at line 42, column 5
```

The path is **percent-encoded** (spaces → `%20`; a literal `+` in a name → `%2B`, so it can't be confused with the `+LINE:COLUMN` delimiter). `+LINE:COLUMN` is Emacs's own position syntax. The app parses the URL itself and opens the file over the daemon socket — **no Emacs configuration is required**.

Use it anywhere macOS resolves URL schemes — an Obsidian or Things link, a note, a message:

```markdown
[foo.org, line 42](emacs://file/Users/andrea/notes/foo.org+42)
```

To *generate* these links, see [`goodies/`](goodies/): an AppleScript that copies a link for the current Finder selection, and an Emacs command (`emacs-uri-copy`) that copies a link to the current buffer at point.

> Unlike `org-protocol://` — which hands the URL to Emacs's Org library to interpret (capture, store-link, …) and needs Org configuration — the `emacs://` scheme is plain "open this file" and is handled entirely by the app.

## File types it handles

Org (`.org`, `.org_archive`), Emacs Lisp (`.el`, `.eld`), Texinfo (`.texi`, `.texinfo`), Markdown (`.md`), and a broad catch-all for plain-text, source-code, script, XML, and JSON files.

> The app registers as a **candidate** opener — it appears under *Open With* but does **not** hijack your existing defaults. You choose per type whether to make it the default.

## Practical tips

### Keep everything in one frame

Emacs Launcher already reuses your existing graphical frame and only ever creates a frame when none exists. To make Emacs itself *place* a visited buffer nicely — reuse the window already showing it, otherwise switch in the current window, rather than splitting or popping — set `server-window`:

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

Emacs Launcher talks to the daemon over the `emacsclient` protocol, so this is the setting that governs where your files land.

### If you instead open files with Emacs.app directly

**Associating files with the regular Emacs.app is not recommended.** When no graphical frame is open, opening a file that way launches a *standalone* Emacs instance instead of attaching to your daemon — so you end up with a second, separate Emacs (its own buffers, state, and init time) rather than the file landing in your running session. Emacs Launcher avoids this by always going through the daemon. The setting below is offered only **in case you deliberately point Finder's *Open With* at Emacs.app anyway**; with the recommended setup (files associated with Emacs Launcher) you don't need it:

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

macOS routes a URL scheme to a single app, with **no GUI to choose**. The goodies script lists the apps you can pick from for both schemes and sets one as the default:

```sh
swift goodies/set-default-handler.swift        # list, numbered (→ marks the current default)
swift goodies/set-default-handler.swift 01     # set option 01 as the default
swift goodies/set-default-handler.swift 01 02  # several at once, applied in order
```

This writes a reversible *user preference*; you do **not** deregister the other apps (that wouldn't stick — they re-register themselves). The list is keyed by **bundle id**, so it's often shorter than the raw registrations: emacs-mac's `Emacs.app` and emacs-plus's `Emacs Client.app` are usually shadowed by id collisions, leaving Emacs Launcher the only selectable handler for these schemes.

### Keeping a daemon running (LaunchAgent)

Emacs Launcher needs a running daemon. To have one start at login and restart if it exits, install the bundled LaunchAgent — three equivalent ways:

- **Option-launch:** hold **⌥ Option** while launching the app (no file) to open a panel
  that installs the agent (or uninstalls it if it's already installed).
- **When prompted:** if the daemon is ever unreachable, the error dialog offers to install
  it (and then reopens your file).
- **By hand:** see
  [`goodies/`](goodies/#ioalberti42emacs-daemonplist--keep-the-daemon-running).

The app's one-click install fills in your **login shell** and a standard `-l -c "exec emacs --fg-daemon"` invocation, which covers most setups. **For special needs** — a custom `PATH`/environment, a different shell or invocation (e.g. `-i` for interactive config), sourcing extra env files, or a non-default socket (`EMACS_SOCKET_NAME`) — **install [`goodies/io.alberti42.emacs-daemon.plist`](goodies/#ioalberti42emacs-daemonplist--keep-the-daemon-running) by hand and edit it** instead.

## Troubleshooting

- **"Can't reach the Emacs server."** The daemon isn't running, or is on a different socket. The dialog shows **which socket** it tried and offers to **Install LaunchAgent** — click it and the app copies the bundled [`io.alberti42.emacs-daemon.plist`](goodies/#ioalberti42emacs-daemonplist--keep-the-daemon-running) into `~/Library/LaunchAgents`, loads it (so a daemon starts now and at every login), and reopens your file. Or start one yourself with `emacs --daemon` (`emacsclient -e t` should then print `t`; the default socket is `$TMPDIR/emacs<uid>/server`); set `EMACS_SOCKET_NAME` for a non-default socket. Direct command-line runs print this to stderr instead of a dialog, so they don't hang a script.
- **It doesn't appear under "Open With".** Re-run `./emacs-launcher-build.sh` (it re-registers with Launch Services). If macOS is still confused, log out and back in.
- **Coexisting with emacs-plus.** emacs-plus ships its own separate `Emacs Client.app`; this app is **Emacs Launcher** with its own bundle id, so the two don't clash and you can keep both. Just pick *Emacs Launcher* in *Open With* / *Change All…* if you want this one to handle a file type.
- **Emacs comes up but doesn't take focus.** This is exactly the macOS 14+ case the app handles via Launch Services; confirm you launched *this* app and not a stale copy.

## How it works

Emacs normally runs as a background **daemon** (`emacs --daemon`): one long-lived process that has no window of its own. Your editing happens in *frames* — Emacs's word for windows — that clients ask the daemon to open or reuse. Emacs Launcher is one such client. Its job is to take a request from macOS (a file from Finder, an `org-protocol` link, or a plain Dock/Spotlight launch), carry it out in that daemon, and bring Emacs to the front. Here is what it does on each launch.

**1. It connects to the daemon.** The daemon listens on a Unix-domain socket — a special file on disk, typically `$TMPDIR/emacs<uid>/server`. Emacs Launcher opens that socket and speaks the Emacs server protocol directly. This is the same protocol the `emacsclient` command-line tool uses, which is why the app needs no `emacsclient` binary installed.

**2. It checks whether a window is already open.** It asks the daemon whether any *graphical* frame currently exists. This check matters because a daemon always keeps one invisible terminal frame alive in the background, so naively counting frames would always say "yes" and be misleading.

**3. It opens your files.** It asks the daemon to visit the file (or files) you gave it.  If a graphical frame already exists, the files open inside it; if none does, the app asks the daemon to create one first. With no file at all, it simply makes sure a frame is on screen.

**4. It brings Emacs to the front — and this takes two steps.** This is the tricky part, and really the reason the app exists:

- *Inside Emacs:* it tells the daemon to select and raise the correct window, so the right buffer is the one you land on.
- *At the macOS level:* since macOS 14, the system no longer lets a **background** process push itself to the foreground — a deliberate anti-focus-stealing measure. Because the daemon is a background process, it can no longer bring its own window forward. So Emacs Launcher does it from the outside: it asks **Launch Services** (the macOS service that opens and activates apps) to bring Emacs forward. macOS honors this, because it is one app activating *another* app on the user's behalf — exactly the case the restriction still allows.

  It activates the **exact** Emacs app bundle the daemon is running from — which it asks the daemon to report — in case you have more than one `Emacs.app` build installed.

**5. It gets out of the way.** Emacs Launcher runs as an *accessory* app: no Dock icon, no menu bar. It does this one job in a fraction of a second and then quits. All you see is Emacs coming to the front.

## Icon

The app icon is the **"dragon-plus"** icon from [d12frosted/homebrew-emacs-plus](https://github.com/d12frosted/homebrew-emacs-plus) ([`community/icons/dragon-plus`](https://github.com/d12frosted/homebrew-emacs-plus/tree/0df9688bb0f6b8e05585a5e8cdc82e0b14fb1921/community/icons/dragon-plus)).  All rights to the artwork remain with its original authors — see the emacs-plus repository for licensing and attribution.

It lives in the repo as its loose [Icon Composer](https://developer.apple.com/icon-composer/) source (`assets/icons/dragon-plus.icon`), and the build compiles it with `actool` into `Assets.car` (the macOS 26 "Tahoe" icon) plus an `.icns` for older macOS. Because `actool` ships only with full Xcode, the compiled artifacts are also committed under `assets/prebuilt/` as a fallback used when `actool` isn't available. After changing the icon, refresh that fallback with:

```sh
UPDATE_PREBUILT=1 ./emacs-launcher-build.sh
```

See [`assets/README.md`](assets/README.md) for details.

## License

MIT — see [LICENSE](LICENSE). The bundled icon artwork is excluded; see [Icon](#icon).
