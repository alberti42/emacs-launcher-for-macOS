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

/// The URL scheme this app handles for "open a file in Emacs" links:
/// `emacs://file/<percent-encoded-path>[+LINE[:COLUMN]]`. Must match the scheme
/// registered in Info.plist (`CFBundleURLTypes`). Change both together to rename it.
let openFileScheme = "emacs"

/// True when the binary was run directly with file arguments (the CLI path), as opposed
/// to a Launch Services open event / bare launch. Errors are reported to stderr in this
/// case (a modal dialog would hang a script) and via a modal alert otherwise.
var launchedFromCommandLine = false

// MARK: - Core logic

/// A file or org-protocol:// URL to open, with an optional `+LINE[:COLUMN]` position
/// (only ever set for command-line invocations — Launch Services carries no position).
struct OpenTarget {
    let arg: String
    let position: String?
}

/// End-of-work disposition. Direct-CLI invocations (`EmacsLauncher file…`) are one-shot
/// and must `terminate` so they don't hang a script. Launch Services / GUI launches
/// instead stay **resident**: the process keeps running so the next Finder / Dock /
/// Spotlight / org-protocol / `emacs://` event lands in `application(_:open:)` on the
/// live process, skipping the cold start (spawn + dyld + AppKit init). We're an
/// `.accessory` app, so staying resident shows no Dock icon. A failure path may have
/// switched us to `.regular` to front a modal — drop back to `.accessory` so the
/// resident process is invisible again.
func finish() {
    if launchedFromCommandLine {
        NSApp.terminate(nil)
    } else if NSApp.activationPolicy() != .accessory {
        NSApp.setActivationPolicy(.accessory)
    }
}

/// Open the given targets (or just surface a frame when none are given), then perform
/// both raise layers and `finish()` (stay resident for GUI launches, terminate for CLI).
///
/// Two short socket exchanges with the daemon:
///   1. Ask whether a graphical frame already exists, and for the daemon's own
///      bundle path — both in one `-eval`.
///   2. Open the files / create a frame, then raise the window.
/// A running daemon always keeps an invisible *terminal* frame around, so counting
/// `frame-list` would lie; we ask whether any frame is on a graphical display.
func runEmacsGui(targets: [OpenTarget]) {
    guard let socket = EmacsServer.socketPath() else {
        reportFailure("Can't locate the Emacs server socket.",
                      "Set EMACS_SOCKET_NAME if your daemon uses a non-default socket.")
        return
    }

    // Exchange 1: graphical-frame check + bundle path, returned as `(t/nil "PATH")`.
    var probe = dirToken()
    probe += EmacsServer.token("-current-frame")
    probe += EmacsServer.token("-eval",
        "(list (if (memq t (mapcar (function display-graphic-p) (frame-list))) t nil)"
        + " (expand-file-name invocation-name invocation-directory))")
    guard let reply = EmacsServer.send(socket, probe), let result = reply.prints.last else {
        // Couldn't connect (or no usable response) — almost always a daemon that isn't
        // running. Tell the user (and offer to install the daemon LaunchAgent).
        handleNoDaemon(socket: socket, targets: targets)
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

    // One job done. We're already on the main thread here (invoked from a delegate
    // callback). For a one-shot CLI run this terminates; for a GUI launch it stays
    // resident, ready for the next event.
    finish()
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

/// Parse an `emacs://file/<percent-encoded-path>[+LINE[:COLUMN]]` URL into an
/// `OpenTarget`. The trailing `+LINE:COLUMN` is matched against the *raw* (still
/// percent-encoded) path, so a literal `+` inside a file name — which must be encoded
/// as `%2B` in the URL — is never mistaken for the position delimiter. The `+LINE:COL`
/// token is Emacs's own position syntax, so it passes straight through as the position.
/// Returns nil if the URL is malformed (e.g. wrong host or empty path).
func parseOpenFileURL(_ url: URL) -> OpenTarget? {
    guard url.host?.lowercased() == "file",
          let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath,
          !raw.isEmpty else { return nil }

    var encodedPath = raw
    var position: String?
    if let range = raw.range(of: "\\+[0-9]+(:[0-9]+)?$", options: .regularExpression) {
        position = String(raw[range])                        // e.g. "+42:5"
        encodedPath = String(raw[raw.startIndex..<range.lowerBound])
    }

    let path = encodedPath.removingPercentEncoding ?? encodedPath
    return path.isEmpty ? nil : OpenTarget(arg: path, position: position)
}

/// Spawn `exe` with `args` via posix_spawn (never Foundation `Process` — see the memory
/// `foundation-process-spawn-tax`), discard its stdout/stderr, wait, and return its exit
/// status (-1 if it couldn't be spawned).
@discardableResult
func runProcess(_ exe: String, _ args: [String]) -> Int32 {
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
    defer { posix_spawn_file_actions_destroy(&actions) }

    let argv: [UnsafeMutablePointer<CChar>?] = ([exe] + args).map { strdup($0) } + [nil]
    defer { for arg in argv where arg != nil { free(arg) } }

    var pid: pid_t = 0
    guard posix_spawn(&pid, exe, &actions, nil, argv, environ) == 0 else { return -1 }
    var status: Int32 = 0
    waitpid(pid, &status, 0)
    return status
}

/// Bring the Emacs bundle to the foreground via Launch Services. `open` hands the
/// request to LS and exits promptly. No-op if the bundle can't be resolved.
func activateEmacsBundle(_ bundlePath: String?) {
    guard let path = bundlePath, FileManager.default.fileExists(atPath: path) else { return }
    runProcess("/usr/bin/open", ["-a", path])
}

/// Report an error and terminate. Always written to stderr (useful for the CLI path);
/// for GUI launches (Finder / Dock / open events) it also shows a modal alert, since a
/// silent no-op there is baffling. A modal is *not* shown for CLI launches — that would
/// hang a script.
func reportFailure(_ message: String, _ detail: String) {
    FileHandle.standardError.write(Data("\(message) \(detail)\n".utf8))
    if !launchedFromCommandLine {
        NSApp.setActivationPolicy(.regular)        // so the alert can come to the front
        NSApp.activate(ignoringOtherApps: true)
        let alert = makeWideAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.runModal()
    }
    finish()
}

// MARK: - Daemon-unreachable handling (offer to install the LaunchAgent)

/// File name of the bundled LaunchAgent (in Contents/Resources and, once installed, in
/// ~/Library/LaunchAgents). Keep in sync with goodies/<this name>.
let launchAgentName = "io.alberti42.emacs-daemon.plist"

/// Set once we've offered to install the agent this run, so a post-install retry can't
/// loop back into offering it again.
var alreadyOfferedInstall = false

/// Where the LaunchAgent is installed for the current user.
func launchAgentDestination() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/\(launchAgentName)")
}

/// An NSAlert sizes itself to its text, which is uncomfortably narrow for our file
/// paths and socket strings. A fixed-width (zero-height) spacer accessory forces the
/// dialog wider. Use this instead of `NSAlert()` for every alert we show.
func makeWideAlert(width: CGFloat = 460) -> NSAlert {
    let alert = NSAlert()
    alert.accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 0))
    return alert
}

/// Show a simple informational alert (assumes activation policy is already `.regular`).
func infoAlert(_ message: String, _ detail: String) {
    let alert = makeWideAlert()
    alert.messageText = message
    alert.informativeText = detail
    alert.alertStyle = .informational
    alert.runModal()
}

/// The daemon couldn't be reached. Report it — to stderr for CLI launches, and as a
/// dialog for GUI launches that also offers to install the bundled LaunchAgent (so a
/// daemon starts at login and stays up). On a successful install we wait briefly for
/// the daemon and then retry the original open.
func handleNoDaemon(socket: String, targets: [OpenTarget]) {
    FileHandle.standardError.write(Data(
        ("Can't reach the Emacs server (socket: \(socket)). "
         + "Start the daemon with \"emacs --daemon\".\n").utf8))
    if launchedFromCommandLine { finish(); return }

    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)

    // If the agent is already installed (or we've already offered), don't re-offer.
    if alreadyOfferedInstall || FileManager.default.fileExists(atPath: launchAgentDestination().path) {
        infoAlert("Can't reach the Emacs server.",
                  "No daemon is responding on:\n  \(socket)\n\n"
                  + "The daemon LaunchAgent is installed; it may still be starting — try "
                  + "again in a moment, or run \"emacs --daemon\".")
        finish()
        return
    }

    alreadyOfferedInstall = true
    let alert = makeWideAlert()
    alert.messageText = "Can't reach the Emacs server."
    alert.informativeText =
        "No Emacs daemon is responding on:\n  \(socket)\n\n"
        + "Install a LaunchAgent to start a daemon at login and keep it running? "
        + "(See the README for details, or to point at a different socket via "
        + "EMACS_SOCKET_NAME.)"
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Install LaunchAgent")
    alert.addButton(withTitle: "Not Now")
    guard alert.runModal() == .alertFirstButtonReturn else { finish(); return }

    let (ok, message) = installLaunchAgent()
    guard ok else { infoAlert("Couldn't install the LaunchAgent.", message); finish(); return }

    // Daemon is starting (RunAtLoad). Wait for it, then retry the original open.
    if waitForDaemon(socket, timeout: 8) {
        runEmacsGui(targets: targets)        // succeeds now; won't re-offer (flag set)
    } else {
        infoAlert("LaunchAgent installed.",
                  "\(message)\nThe Emacs daemon is still starting — try again in a moment.")
        finish()
    }
}

/// Copy the bundled LaunchAgent into ~/Library/LaunchAgents and `launchctl bootstrap`
/// it into the current GUI session (which also starts it, via RunAtLoad). Returns
/// whether the file was installed, plus a message to show.
func installLaunchAgent() -> (ok: Bool, message: String) {
    let resource = (launchAgentName as NSString).deletingPathExtension
    guard let src = Bundle.main.url(forResource: resource, withExtension: "plist"),
          let data = try? Data(contentsOf: src),
          var plist = (try? PropertyListSerialization.propertyList(from: data, format: nil))
              as? [String: Any] else {
        return (false, "The LaunchAgent template is missing or unreadable in the app bundle.")
    }

    // Run the user's *login shell* (from the password database) rather than a hardcoded
    // one, so the daemon — and therefore every Emacs session and subprocess — inherits
    // the right PATH and environment. The bundled plist's `-l -c "exec emacs --fg-daemon"`
    // works across zsh/bash/fish; we only swap the shell path (ProgramArguments[0]).
    let shell = loginShell()
    if var args = plist["ProgramArguments"] as? [String], !args.isEmpty {
        args[0] = shell
        plist["ProgramArguments"] = args
    }
    guard let out = try? PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0) else {
        return (false, "Couldn't build the LaunchAgent plist.")
    }

    let dst = launchAgentDestination()
    let fm = FileManager.default
    do {
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try out.write(to: dst, options: .atomic)
    } catch {
        return (false, "Couldn't write \(dst.path):\n\(error.localizedDescription)")
    }
    // Load it into the GUI session now (nonzero just means already loaded — harmless).
    runProcess("/bin/launchctl", ["bootstrap", "gui/\(getuid())", dst.path])
    return (true, "Installed \(dst.path)\nusing your login shell: \(shell)")
}

/// The user's login shell from the password database (what they set with `chsh`) — the
/// authoritative "their shell", independent of the `$SHELL` env var. Falls back to
/// `/bin/zsh` if it can't be read or isn't executable.
func loginShell() -> String {
    if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell {
        let path = String(cString: sh)
        if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) { return path }
    }
    return "/bin/zsh"
}

/// Poll the socket until the daemon answers or `timeout` seconds elapse.
func waitForDaemon(_ socket: String, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if EmacsServer.isReachable(socket) { return true }
        Thread.sleep(forTimeInterval: 0.3)
    }
    return false
}

/// The deliberate ⌥-Option panel, shown when the app is launched with Option held (a
/// bare double-click in Finder / Dock) or re-activated with Option while resident. Its
/// multi-section UI (LaunchAgent install/uninstall, recent-files source, background-
/// activation info with Done / Kill) lives in `OptionPanelController`, which handles its
/// own activation-policy flip and `finish()`.
func showLaunchAgentPanel() {
    OptionPanelController().show()
}

/// `launchctl bootout` the agent and remove its plist. (Booting it out stops the daemon
/// it was supervising — hence the warning in the panel.)
func uninstallLaunchAgent() -> (ok: Bool, message: String) {
    let label = (launchAgentName as NSString).deletingPathExtension
    runProcess("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
    let dst = launchAgentDestination()
    guard FileManager.default.fileExists(atPath: dst.path) else {
        return (true, "It was not installed.")
    }
    do { try FileManager.default.removeItem(at: dst) }
    catch { return (false, "Couldn't remove \(dst.path):\n\(error.localizedDescription)") }
    return (true, "Removed \(dst.path).")
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set once an open event (files or org-protocol URL) has been handled, so the
    /// bare-launch fallback below knows to stand down. Mirrors the AppleScript split
    /// between `on open` / `on open location` and `on run`.
    private var handledOpen = false

    /// Finder "Open With", drag-and-drop, `file://`, `emacs://file/…`, and
    /// `org-protocol://` URLs all arrive here on modern macOS, in one unified callback.
    func application(_ application: NSApplication, open urls: [URL]) {
        handledOpen = true
        alreadyOfferedInstall = false        // fresh event: allow the install offer again
        let targets: [OpenTarget] = urls.compactMap { url in
            if url.scheme?.lowercased() == openFileScheme {
                return parseOpenFileURL(url)        // emacs://file/… (nil if malformed → dropped)
            }
            // file URLs become plain paths; org-protocol://… is kept verbatim.
            return OpenTarget(arg: url.isFileURL ? url.path : url.absoluteString, position: nil)
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
            launchedFromCommandLine = true
            runEmacsGui(targets: cliTargets)
            return
        }
        // Holding Option during a bare launch (double-clicking the app in Finder/Dock)
        // opens the daemon LaunchAgent panel instead of surfacing a frame. Capture the
        // modifier now, before the hop, while the key is still down.
        let optionHeld = NSEvent.modifierFlags.contains(.option)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self, !self.handledOpen else { return }
            if optionHeld {
                showLaunchAgentPanel()
            } else {
                runEmacsGui(targets: [])
            }
        }
    }

    /// Once the app is **resident** (it stayed alive after a previous GUI launch), a fresh
    /// launch — Spotlight, `open -a "Emacs Launcher"`, or re-selecting it — no longer
    /// re-runs `applicationDidFinishLaunching`; it arrives here instead. (A document/URL
    /// open still goes through `application(_:open:)`.) Mirror the bare-launch behavior:
    /// surface a frame, or show the LaunchAgent panel when ⌥ Option is held.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        alreadyOfferedInstall = false
        if NSEvent.modifierFlags.contains(.option) {
            showLaunchAgentPanel()
        } else {
            runEmacsGui(targets: [])
        }
        return true
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
    // Undocumented developer aid: print the resolved recent-files source and list, then
    // exit. Verifies the daemon probe and the .eld fallback without launching the GUI.
    if args.contains("--print-recent") {
        print("detected recentf-save-file: \(RecentFiles.detectPath() ?? "<none>")")
        let files = RecentFiles.list()
        print("recent files (\(files.count)):")
        for file in files { print("  \(file)") }
        exit(0)
    }
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
