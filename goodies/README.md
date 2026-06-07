# Goodies

Optional helpers for Emacs Launcher's URL schemes. The first two *generate*
`emacs://` links (which open a file in Emacs at an optional line/column); the third
makes Emacs Launcher the **default handler** for a scheme.

| File | What it does | Where it runs |
|------|--------------|---------------|
| `copy-emacs-uri-from-finder.applescript` | copy an `emacs://` link to the file(s) selected in **Finder** | macOS / Finder |
| `emacs-uri.el` | copy an `emacs://` link to the **current buffer at point** (with line:column) | Emacs |
| `set-default-handler.swift` | make Emacs Launcher the **default** app for `org-protocol://` (or any scheme) | macOS |

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

`org-protocol://` is registered by several apps (emacs-mac's `Emacs.app`, emacs-plus's
`Emacs Client.app`, …), and macOS routes the scheme to just one of them — picked by
registration order, with **no GUI to choose**. To make Emacs Launcher the handler
durably:

```sh
swift goodies/set-default-handler.swift            # org-protocol (default)
swift goodies/set-default-handler.swift org-protocol emacs
```

It prints the previous handler and the new one. This sets a reversible *user
preference* for the preferred app — it does **not** unregister the other apps, which
wouldn't stick (they re-register themselves) and could disturb their other file/scheme
associations. To undo, set a different app as the default for that scheme.

