//
// Emacs Client — a compiled macOS launcher that bridges Finder / Dock / Spotlight /
// org-protocol to a running emacsclient, with the macOS 14+ raise workaround applied.
//
// This is a native Swift port of the `emacsgui` zsh script (kept as the reference
// for the logic and its rationale). Two layers of "raise" are needed on macOS 14+:
//
//   1. WINDOW layer — `(select-frame-set-input-focus (selected-frame))` tells the
//      Emacs daemon which window to key-order. The daemon knows how to do this part.
//
//   2. APP layer — macOS 14+ ignores `activateIgnoringOtherApps:` for a *background*
//      app, so the daemon can no longer bring *itself* to the foreground. We supply
//      that activation from this launcher via Launch Services (NSWorkspace), which
//      the OS still honours because it routes through a user-initiated foreground
//      request targeting *another* app's bundle.
//
// We deliberately run as an LSUIElement (accessory) app: invisible in the Dock, no
// flashing icon, while still able to receive document/URL open events from Launch
// Services and to activate the Emacs bundle on the user's behalf.
//
import Cocoa

// MARK: - emacsclient invocation

/// Resolve the emacsclient binary. Overridable via $EC (e.g. the build pipeline can
/// point elsewhere); defaults to ~/.local/bin/emacsclient like the shell version.
func emacsclientPath() -> String {
    if let ec = ProcessInfo.processInfo.environment["EC"], !ec.isEmpty {
        return ec
    }
    return (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/emacsclient")
}

/// Spawn a child process synchronously via `posix_spawn` and wait for it. stderr is
/// always discarded (matches the `2>/dev/null` in the shell version — a missing or
/// still-booting daemon should fail quietly). When `capture` is set, stdout is read
/// through a pipe and returned trimmed; otherwise stdout goes to /dev/null.
///
/// We deliberately avoid Foundation's `Process`: measured at ~66ms of pure overhead
/// per spawn here (its termination-monitoring / waitUntilExit machinery) versus ~7ms
/// for posix_spawn. With four emacsclient round-trips per invocation that difference
/// is the bulk of the launch latency, and is why the shell entry point feels instant.
@discardableResult
func spawn(_ exe: String, _ args: [String], capture: Bool = false) -> String {
    var fds: [Int32] = [-1, -1]
    if capture, pipe(&fds) != 0 { return "" }

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    if capture {
        posix_spawn_file_actions_adddup2(&actions, fds[1], 1)   // child stdout -> pipe
        posix_spawn_file_actions_addclose(&actions, fds[0])
        posix_spawn_file_actions_addclose(&actions, fds[1])
    } else {
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
    }
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
    defer { posix_spawn_file_actions_destroy(&actions) }

    let argv: [UnsafeMutablePointer<CChar>?] = ([exe] + args).map { strdup($0) } + [nil]
    defer { for arg in argv where arg != nil { free(arg) } }

    var pid: pid_t = 0
    let rc = posix_spawn(&pid, exe, &actions, nil, argv, environ)
    guard rc == 0 else {
        if capture { close(fds[0]); close(fds[1]) }
        return ""
    }

    var output = ""
    if capture {
        close(fds[1])                                   // parent only reads
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fds[0], &buffer, buffer.count)
            if n <= 0 { break }
            output += String(decoding: buffer[0..<n], as: UTF8.self)
        }
        close(fds[0])
    }
    var status: Int32 = 0
    waitpid(pid, &status, 0)
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Convenience wrapper for an emacsclient call. Returns its trimmed stdout (empty
/// unless `capture` is set).
@discardableResult
func runEC(_ args: [String], capture: Bool = false) -> String {
    spawn(emacsclientPath(), args, capture: capture)
}

// MARK: - Core logic (port of emacsgui)

/// Does a graphical frame already exist? A running daemon always keeps an invisible
/// *terminal* frame around, so counting `frame-list` would lie; instead we ask
/// whether any frame is on a graphical display.
func graphicalFrameExists() -> Bool {
    let output = runEC(
        ["-e", "(if (memq t (mapcar (function display-graphic-p) (frame-list))) t nil)"],
        capture: true
    )
    return output == "t"
}

/// Open the given files/URLs (or just surface a frame when none are given), then
/// perform both raise layers and terminate. Args are file paths and/or
/// org-protocol:// URLs, passed straight through to `emacsclient -n`.
func runEmacsGui(files: [String]) {
    let frameExists = graphicalFrameExists()

    // Reuse the existing frame, or create one with -c only when none exists yet.
    // `-n` is non-blocking; `server-window` in init.el places the buffer in the
    // current frame, so -c is needed solely for the cold case of a running server
    // with no graphical window.
    let create = frameExists ? [] : ["-c"]

    if !files.isEmpty {
        runEC(["-n"] + create + files)        // open file(s)/URL(s), creating a frame if needed
    } else if !frameExists {
        runEC(["-n", "-c"])                    // no files and no frame: just open a window
    }

    // WINDOW layer: key-order the right window within Emacs.
    runEC(["-e", "(select-frame-set-input-focus (selected-frame))"])

    // APP layer: activate the daemon's *exact* bundle (this machine may host several
    // Emacs.app builds sharing org.gnu.Emacs, so `open -b`/`open -a Emacs` would be
    // ambiguous). Ask the daemon for its own executable path and strip to the bundle.
    activateEmacsBundle()

    // One job done — quit immediately. We're already on the main thread here (invoked
    // from a delegate callback), so this is the last thing the process does.
    NSApp.terminate(nil)
}

/// Bring the Emacs daemon's own .app bundle to the foreground via Launch Services,
/// then terminate this launcher. Falls back to an immediate terminate if the bundle
/// can't be resolved.
func activateEmacsBundle() {
    let result = runEC(
        ["-e", "(expand-file-name invocation-name invocation-directory)"],
        capture: true
    )

    // Strip the elisp string quotes, then trim .../Emacs.app/Contents/MacOS/Emacs
    // back to the .app bundle.
    var path = result.replacingOccurrences(of: "\"", with: "")
    if let range = path.range(of: "/Contents/MacOS/") {
        path = String(path[..<range.lowerBound])
    }

    guard path.hasSuffix(".app"), FileManager.default.fileExists(atPath: path) else { return }

    // Fire-and-forget activation, exactly like the shell's `open -a`: hand the request
    // to Launch Services and return as soon as it's accepted. We deliberately do NOT
    // use NSWorkspace.openApplication's completion handler — waiting for it to confirm
    // Emacs is frontmost added ~200ms before we could exit, and (since we terminate
    // right after) risked delaying the activation itself. `open` brings Emacs forward
    // immediately and lets this process quit at once, matching the snappy shell path.
    // `open` hands the request to Launch Services and exits promptly; spawning it via
    // posix_spawn keeps the activation on the fast path too (no Foundation Process tax).
    spawn("/usr/bin/open", ["-a", path])
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set once an open event (files or org-protocol URL) has been handled, so the
    /// bare-launch fallback below knows to stand down. Mirrors the AppleScript split
    /// between `on open` / `on open location` and `on run`.
    private var handledOpen = false

    /// Finder "Open With", drag-and-drop, and org-protocol:// URLs all arrive here on
    /// modern macOS — file URLs and scheme URLs in one unified callback.
    func application(_ application: NSApplication, open urls: [URL]) {
        handledOpen = true
        let args = urls.map { url -> String in
            url.isFileURL ? url.path : url.absoluteString   // org-protocol://... kept verbatim
        }
        runEmacsGui(files: args)
    }

    /// Plain launch (Spotlight / Dock / `open -a`): if no open event arrives almost
    /// immediately, just surface a frame. A short hop lets Launch Services deliver a
    /// pending open event first (so we don't create an empty frame *and* open a file),
    /// but it's kept tight because for a true bare launch this delay is pure waiting —
    /// the user is staring at the screen until it elapses. ~60ms is below perception
    /// yet comfortably covers the open-event race observed in practice.
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self, !self.handledOpen else { return }
            runEmacsGui(files: [])
        }
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // belt-and-braces alongside LSUIElement in Info.plist
app.run()
