# Goodies

Optional helpers for Emacs Launcher's URL schemes. The first two *generate*
`emacs://` links (which open a file in Emacs at an optional line/column); the third
makes Emacs Launcher the **default handler** for a scheme.

| File | What it does | Where it runs |
|------|--------------|---------------|
| `copy-emacs-uri-from-finder.applescript` | copy an `emacs://` link to the file(s) selected in **Finder** | macOS / Finder |
| `emacs-uri.el` | copy an `emacs://` link to the **current buffer at point** (with line:column) | Emacs |
| `set-default-handler.swift` | list / choose the **default** app for `org-protocol://` and `emacs://` | macOS |

The link format is `emacs://file/<percent-encoded-path>[+LINE[:COLUMN]]` — see the
main [README](../README.md#linking-to-a-file-emacs-scheme).

## `copy-emacs-uri-from-finder.applescript`

Copies an `emacs://file/…` URL for each selected Finder item to the clipboard (one per
line). Finder has no cursor, so these carry no `+LINE:COLUMN`.

Quickest way to use it: turn it into a hotkey.

- **Shortcuts.app:** new Shortcut → *Run AppleScript* (paste the file's contents) → add a
  keyboard shortcut in *Shortcut Details*. Or
- **Automator:** new *Quick Action*, "no input", in *Finder* → *Run AppleScript* → save;
  then bind a key in *System Settings → Keyboard → Keyboard Shortcuts → Services*.

You can also just run it from **Script Editor**, or:

```sh
osascript goodies/copy-emacs-uri-from-finder.applescript
```

## `emacs-uri.el`

Adds `emacs-uri-copy`: copy an `emacs://file/…+LINE:COLUMN` URL for the current buffer
at point to the kill ring. Load and (optionally) bind it:

```elisp
(load "/path/to/goodies/emacs-uri.el")   ; or put it on your `load-path' and (require 'emacs-uri)
(global-set-key (kbd "C-c u") #'emacs-uri-copy)
```

Then `M-x emacs-uri-copy` (or `C-c u`) and paste the link into Obsidian, Things, a note,
a message — clicking it reopens that exact spot in Emacs.

If you renamed the scheme in the app, match it here via `M-x customize-variable
emacs-uri-scheme` (and `kPrefix` in the AppleScript).

## `set-default-handler.swift`

macOS routes a URL scheme to a single handler app, with **no GUI to choose**. This
script lists the apps you can pick from for `org-protocol://` and `emacs://`, numbered,
and sets one as the default.

**List** (no arguments) — `→` marks the current default:

```sh
swift goodies/set-default-handler.swift
```

```
org-protocol://
 → 01  Emacs Launcher   /Users/you/Applications/Emacs Launcher.app
emacs://
 → 02  Emacs Launcher   /Users/you/Applications/Emacs Launcher.app
```

**Set** by number — global across both lists; pass several, applied in order:

```sh
swift goodies/set-default-handler.swift 01        # org-protocol → option 01
swift goodies/set-default-handler.swift 01 02     # …and emacs → option 02
```

This writes a reversible *user preference*; it does **not** unregister anything.

The list is keyed by **bundle id**, not file path, so it can be shorter than
`lsregister -dump`: an app whose bundle id resolves to a *different* copy (or to none at
all) won't appear. On a typical setup only Emacs Launcher is a valid handler for these
two schemes — emacs-mac's `Emacs.app` (`org.gnu.Emacs`) and emacs-plus's
`Emacs Client.app` (`org.gnu.emacsclient`) are usually shadowed by id collisions.

