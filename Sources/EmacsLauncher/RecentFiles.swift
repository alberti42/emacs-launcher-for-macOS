//
// RecentFiles — resolve the user's Emacs "recent files" list, to feed a future
// "recent files in Spotlight" feature.
//
// Source of truth is Emacs itself: we ask the running daemon for `recentf-list` over
// the same local socket the launcher already uses (no hardcoded path, so it works with
// no-littering / custom `recentf-save-file` setups). The live in-memory list is fresher
// than the saved file, which Emacs only flushes periodically.
//
// When the daemon isn't running we fall back to parsing the `recentf-save-file` `.eld`
// from disk. Its path is whatever Emacs last reported (cached in UserDefaults), or an
// explicit override the user picked in the ⌥-Option panel.
//
import Foundation

enum RecentFiles {
    /// UserDefaults key for an explicit, user-chosen `.eld` path (the ⌥-panel picker).
    /// Empty/absent means "auto-detect".
    static let overridePathKey = "RecentfSourcePath"
    /// UserDefaults key caching the last `recentf-save-file` path reported by Emacs, so
    /// the disk fallback has a path to read when the daemon is down.
    static let detectedPathKey = "DetectedRecentfPath"

    // MARK: Public API

    /// The recent files, most-recent-first. Live `recentf-list` from the daemon when it's
    /// reachable; otherwise the `.eld` parsed from disk. Empty if neither is available.
    static func list() -> [String] {
        if let socket = EmacsServer.socketPath(), EmacsServer.isReachable(socket),
           let strings = probeLive(socket), let savePath = strings.first {
            UserDefaults.standard.set(savePath, forKey: detectedPathKey)   // keep cache warm
            return Array(strings.dropFirst())
        }
        return diskList()
    }

    /// Probe the daemon for `recentf-save-file`, cache it, and return it. nil if the daemon
    /// is unreachable or recentf isn't loaded. Used by the panel to show the detected path.
    @discardableResult
    static func detectPath() -> String? {
        guard let socket = EmacsServer.socketPath() else { return nil }
        let reply = eval(socket,
            "(progn (require 'recentf nil t)"
            + " (if (boundp 'recentf-save-file) (expand-file-name recentf-save-file) nil))")
        guard let out = reply, let path = parseElispStrings(out).first else { return nil }
        UserDefaults.standard.set(path, forKey: detectedPathKey)
        return path
    }

    /// The `.eld` path used for the disk fallback / panel display: explicit override first,
    /// else the last detected path.
    static func effectivePath() -> String? {
        let defaults = UserDefaults.standard
        if let override = defaults.string(forKey: overridePathKey), !override.isEmpty { return override }
        if let detected = defaults.string(forKey: detectedPathKey), !detected.isEmpty { return detected }
        return nil
    }

    // MARK: Daemon

    /// Ask the daemon for `(cons recentf-save-file recentf-list)` in one eval, so the
    /// reply is `("<save-file>" "<recent1>" "<recent2>" …)` — first element is the path
    /// (used to refresh the cache), the rest is the list. nil if recentf isn't loaded.
    private static func probeLive(_ socket: String) -> [String]? {
        let reply = eval(socket,
            "(progn (require 'recentf nil t)"
            + " (if (and (boundp 'recentf-save-file) (boundp 'recentf-list))"
            + " (cons (expand-file-name recentf-save-file) recentf-list) nil))")
        guard let out = reply else { return nil }
        let strings = parseElispStrings(out)
        return strings.isEmpty ? nil : strings
    }

    /// Send one `-eval` exchange and return the (decoded) prin1'd result string, or nil if
    /// the daemon couldn't be reached or returned an error. Mirrors the probe in
    /// `runEmacsGui`: `-dir … -current-frame -eval …`.
    private static func eval(_ socket: String, _ expr: String) -> String? {
        var cmd = dirToken()
        cmd += EmacsServer.token("-current-frame")
        cmd += EmacsServer.token("-eval", expr)
        guard let reply = EmacsServer.send(socket, cmd), reply.error == nil else { return nil }
        return reply.prints.last
    }

    // MARK: Disk fallback

    /// Parse `recentf-list` out of the `.eld` file at `effectivePath()`. The file is elisp:
    /// `(setq recentf-list '("/a" "/b" …))`. We isolate that list (so unrelated strings in
    /// the file aren't picked up) and scan it for string literals.
    static func diskList() -> [String] {
        guard let path = effectivePath(),
              let text = try? String(contentsOfFile: path, encoding: .utf8),
              let marker = text.range(of: "recentf-list") else { return [] }
        let after = text[marker.upperBound...]
        guard let open = after.firstIndex(of: "(") else { return [] }

        // Balance parens from the opening one, skipping over string contents so a ')' or
        // '(' inside a file name can't unbalance us. Stop at the matching close paren.
        var depth = 0
        var inString = false
        var escaped = false
        var idx = open
        var end = after.endIndex
        while idx < after.endIndex {
            let c = after[idx]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == "(" {
                depth += 1
            } else if c == ")" {
                depth -= 1
                if depth == 0 { end = after.index(after: idx); break }
            }
            idx = after.index(after: idx)
        }
        return parseElispStrings(String(after[open..<end]))
    }

    // MARK: Parsing

    /// Extract elisp string literals (`"…"`) from `text`, in order, decoding `\"` and `\\`.
    /// Used for both the prin1'd daemon reply and the `recentf-list` region of the `.eld`.
    static func parseElispStrings(_ text: String) -> [String] {
        var out: [String] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            guard chars[i] == "\"" else { i += 1; continue }
            i += 1
            var s = ""
            while i < chars.count {
                let c = chars[i]
                if c == "\\" {
                    i += 1
                    if i < chars.count { s.append(chars[i]); i += 1 }
                } else if c == "\"" {
                    i += 1
                    break
                } else {
                    s.append(c); i += 1
                }
            }
            out.append(s)
        }
        return out
    }
}
