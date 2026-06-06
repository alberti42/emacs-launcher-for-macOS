//
// Emacs Launcher — a compiled macOS launcher that bridges Finder / Dock / Spotlight /
// org-protocol to a running Emacs daemon, with the macOS 14+ raise workaround applied.
//
// It speaks the Emacs server protocol directly over the daemon's local socket (see
// EmacsServer.swift) — there is no dependency on an `emacsclient` binary. Two layers
// of "raise" are needed on macOS 14+:
//
//   1. WINDOW layer — `(select-frame-set-input-focus (selected-frame))` tells the
//      Emacs daemon which window to key-order. The daemon knows how to do this part.
//
//   2. APP layer — macOS 14+ ignores `activateIgnoringOtherApps:` for a *background*
//      app, so the daemon can no longer bring *itself* to the foreground. We supply
//      that activation from this launcher via Launch Services (`open -a`), which the
//      OS still honours because it routes through a user-initiated foreground request
//      targeting *another* app's bundle.
//
// We deliberately run as an LSUIElement (accessory) app: invisible in the Dock, no
// flashing icon, while still able to receive document/URL open events from Launch
// Services and to activate the Emacs bundle on the user's behalf.
//
import Cocoa

// MARK: - Core logic

/// A file or org-protocol:// URL to open, with an optional `+LINE[:COLUMN]` position
/// (only ever set for command-line invocations — Launch Services carries no position).
struct OpenTarget {
    let arg: String
    let position: String?
}

/// Open the given targets (or just surface a frame when none are given), then perform
/// both raise layers and terminate.
///
/// Two short socket exchanges with the daemon:
///   1. Ask whether a graphical frame already exists, and for the daemon's own
///      bundle path — both in one `-eval`.
///   2. Open the files / create a frame, then raise the window.
/// A running daemon always keeps an invisible *terminal* frame around, so counting
/// `frame-list` would lie; we ask whether any frame is on a graphical display.
func runEmacsGui(targets: [OpenTarget]) {
    guard let socket = EmacsServer.socketPath() else { NSApp.terminate(nil); return }

    // Exchange 1: graphical-frame check + bundle path, returned as `(t/nil "PATH")`.
    var probe = dirToken()
    probe += EmacsServer.token("-current-frame")
    probe += EmacsServer.token("-eval",
        "(list (if (memq t (mapcar (function display-graphic-p) (frame-list))) t nil)"
        + " (expand-file-name invocation-name invocation-directory))")
    guard let reply = EmacsServer.send(socket, probe), let result = reply.prints.last else {
        // No daemon / no response — nothing we can do.
        NSApp.terminate(nil)
        return
    }
    let frameExists = result.hasPrefix("(t ")
    let bundlePath = parseBundlePath(result)

    // Exchange 2: open files / create a frame (only when none is graphical yet),
    // then key-order the right window. `-window-system` + `-display ns` creates a
    // graphical frame the same way `emacsclient -c` does on macOS.
    var cmd = dirToken()
    cmd += EmacsServer.token("-nowait")
    if frameExists {
        cmd += EmacsServer.token("-current-frame")
    } else {
        cmd += EmacsServer.token("-display", "ns")
        cmd += EmacsServer.token("-window-system")
    }
    for target in targets {
        // `-position +LINE:COL` precedes its file, exactly as emacsclient sends it.
        if let position = target.position {
            cmd += EmacsServer.token("-position", position)
        }
        cmd += EmacsServer.token("-file", target.arg)   // file paths and org-protocol:// URLs
    }
    cmd += EmacsServer.token("-eval", "(select-frame-set-input-focus (selected-frame))")
    _ = EmacsServer.send(socket, cmd)

    // APP layer: activate the daemon's *exact* bundle (this machine may host several
    // Emacs.app builds sharing org.gnu.Emacs, so `open -b`/`open -a Emacs` would be
    // ambiguous).
    activateEmacsBundle(bundlePath)

    // One job done — quit immediately. We're already on the main thread here (invoked
    // from a delegate callback), so this is the last thing the process does.
    NSApp.terminate(nil)
}

/// The `-dir <cwd>/` directive every exchange opens with, matching emacsclient: the
/// value is the quoted working directory with a trailing slash.
func dirToken() -> [UInt8] {
    let cwd = FileManager.default.currentDirectoryPath
    return Array("-dir ".utf8) + EmacsServer.quote(cwd) + Array("/ ".utf8)
}

/// Extract the .app bundle from a `(t/nil "…/Emacs.app/Contents/MacOS/Emacs")` reply:
/// take the quoted string and trim back to the bundle.
func parseBundlePath(_ result: String) -> String? {
    guard let open = result.firstIndex(of: "\""),
          let close = result.lastIndex(of: "\""), open < close else { return nil }
    var path = String(result[result.index(after: open)..<close])
    if let range = path.range(of: "/Contents/MacOS/") {
        path = String(path[..<range.lowerBound])
    }
    return path.hasSuffix(".app") ? path : nil
}

/// Bring the Emacs bundle to the foreground via Launch Services. `open` hands the
/// request to LS and exits promptly; spawning it via posix_spawn keeps activation on
/// the fast path (no Foundation Process tax). No-op if the bundle can't be resolved.
func activateEmacsBundle(_ bundlePath: String?) {
    guard let path = bundlePath, FileManager.default.fileExists(atPath: path) else { return }

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
    defer { posix_spawn_file_actions_destroy(&actions) }

    let args: [String] = ["/usr/bin/open", "-a", path]
    let argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
    defer { for arg in argv where arg != nil { free(arg) } }

    var pid: pid_t = 0
    if posix_spawn(&pid, "/usr/bin/open", &actions, nil, argv, environ) == 0 {
        var status: Int32 = 0
        waitpid(pid, &status, 0)
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set once an open event (files or org-protocol URL) has been handled, so the
    /// bare-launch fallback below knows to stand down. Mirrors the AppleScript split
    /// between `on open` / `on open location` and `on run`.
    private var handledOpen = false

    /// Finder "Open With", drag-and-drop, and org-protocol:// URLs all arrive here on
    /// modern macOS — file URLs and scheme URLs in one unified callback. Launch Services
    /// carries no line/column, so positions are always nil here.
    func application(_ application: NSApplication, open urls: [URL]) {
        handledOpen = true
        let targets = urls.map { url in
            // org-protocol://... kept verbatim; file URLs become plain paths.
            OpenTarget(arg: url.isFileURL ? url.path : url.absoluteString, position: nil)
        }
        runEmacsGui(targets: targets)
    }

    /// Either a command-line invocation (the binary run directly with file args, e.g.
    /// `EmacsLauncher +12:4 notes.org`) or a bare launch (Spotlight / Dock / `open -a`).
    /// CLI args are handled at once; otherwise a short hop lets Launch Services deliver
    /// a pending open event first (so we don't create an empty frame *and* open a file),
    /// kept tight because for a true bare launch this delay is pure waiting.
    func applicationDidFinishLaunching(_ notification: Notification) {
        let cliTargets = parseCommandLine()
        if !cliTargets.isEmpty {
            handledOpen = true
            runEmacsGui(targets: cliTargets)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self, !self.handledOpen else { return }
            runEmacsGui(targets: [])
        }
    }
}

/// Parse direct command-line arguments into open targets. Mirrors emacsclient's
/// `[+LINE[:COLUMN]] FILE...` syntax: a `+12` or `+12:4` token sets the position for
/// the file that follows. Args beginning with `-` are ignored (Launch Services / Cocoa
/// noise such as `-psn_…` or `-NSDocumentRevisionsDebugMode`). Returns [] when the
/// binary was launched normally (no file args) — the open-event / bare-launch paths
/// then take over.
func parseCommandLine() -> [OpenTarget] {
    var targets: [OpenTarget] = []
    var pendingPosition: String?
    for arg in CommandLine.arguments.dropFirst() {
        let body = arg.dropFirst()
        if arg.hasPrefix("+"), let first = body.first, first.isNumber,
           body.allSatisfy({ $0.isNumber || $0 == ":" }) {
            pendingPosition = arg                     // +LINE or +LINE:COLUMN
            continue
        }
        if arg.hasPrefix("-") { continue }            // skip option-looking noise
        targets.append(OpenTarget(arg: arg, position: pendingPosition))
        pendingPosition = nil
    }
    return targets
}

/// Handle `-h`/`--help` and `-V`/`--version` and exit, before any AppKit / Emacs work.
/// Only exact tokens are matched, so Launch Services noise (`-psn_…`, `-NS…`) is never
/// mistaken for a flag. Returns normally when no such flag is present.
func handleCLIFlags() {
    let args = CommandLine.arguments.dropFirst()
    if args.contains("-V") || args.contains("--version") {
        let info = Bundle.main.infoDictionary
        let name = (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String) ?? "Emacs Launcher"
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        print("\(name) (\(version))")
        exit(0)
    }
    guard args.contains("-h") || args.contains("--help") else { return }
    print("""
    Emacs Launcher — open files in your running Emacs daemon and bring it to the front.

    Usage:
      EmacsLauncher [+LINE[:COLUMN]] FILE...   open FILE(s), optionally at a position
      EmacsLauncher                            just raise Emacs (create a frame if none)

    Files (and org-protocol:// URLs) are sent to the Emacs server over its local
    socket; Emacs is then activated via Launch Services. Relative paths resolve
    against the current directory, and a +LINE / +LINE:COLUMN token applies to the
    file that follows it.

    Normally this app is launched by Finder / Dock / Spotlight / org-protocol; running
    the binary directly is for command-line use.

    Options:
      -h, --help       show this help and exit
      -V, --version    show version and exit

    Environment:
      EMACS_SOCKET_NAME   override the daemon socket (a path, or a server-name)
    """)
    exit(0)
}

// MARK: - Entry point

handleCLIFlags()   // prints help/version and exits if requested; otherwise returns

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // belt-and-braces alongside LSUIElement in Info.plist
app.run()
