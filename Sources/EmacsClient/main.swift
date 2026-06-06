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

/// Run emacsclient synchronously. stderr is discarded (matches the `2>/dev/null` in
/// the shell version — a missing/booting daemon should fail quietly). When `capture`
/// is set, stdout is returned trimmed of surrounding whitespace.
@discardableResult
func runEC(_ args: [String], capture: Bool = false) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: emacsclientPath())
    process.arguments = args
    process.standardError = FileHandle.nullDevice

    let pipe = Pipe()
    if capture {
        process.standardOutput = pipe
    }

    do {
        try process.run()
    } catch {
        return (-1, "")
    }

    var output = ""
    if capture {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        output = String(data: data, encoding: .utf8) ?? ""
    }
    process.waitUntilExit()
    return (process.terminationStatus, output.trimmingCharacters(in: .whitespacesAndNewlines))
}

// MARK: - Core logic (port of emacsgui)

/// Does a graphical frame already exist? A running daemon always keeps an invisible
/// *terminal* frame around, so counting `frame-list` would lie; instead we ask
/// whether any frame is on a graphical display.
func graphicalFrameExists() -> Bool {
    let result = runEC(
        ["-e", "(if (memq t (mapcar (function display-graphic-p) (frame-list))) t nil)"],
        capture: true
    )
    return result.output == "t"
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
    var path = result.output.replacingOccurrences(of: "\"", with: "")
    if let range = path.range(of: "/Contents/MacOS/") {
        path = String(path[..<range.lowerBound])
    }

    guard path.hasSuffix(".app"), FileManager.default.fileExists(atPath: path) else {
        terminateSoon()
        return
    }

    let config = NSWorkspace.OpenConfiguration()
    config.activates = true
    NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: config) { _, _ in
        terminateSoon()
    }
}

/// Quit on the main run loop. All exit paths funnel through here so the process never
/// lingers after doing its one job.
func terminateSoon() {
    DispatchQueue.main.async { NSApp.terminate(nil) }
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

    /// Plain launch (Spotlight / Dock / `open -a`): if no open event arrives shortly,
    /// just surface a frame. The small delay gives Launch Services time to deliver a
    /// pending open event first, so we don't double-act.
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
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
