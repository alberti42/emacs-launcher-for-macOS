# Goodies

Optional helpers for the `emacs://` URL scheme that Emacs Launcher registers. An
`emacs://` link opens a file in Emacs (at an optional line/column); these scripts
*generate* such links.

| File | Generates a link to… | Where it runs |
|------|----------------------|---------------|
| `copy-emacs-uri-from-finder.applescript` | the file(s) selected in **Finder** | macOS / Finder |
| `emacs-uri.el` | the **current buffer at point** (with line:column) | Emacs |

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
