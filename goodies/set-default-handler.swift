//
// set-default-handler.swift — make Emacs Launcher the default app for one or more URL
// schemes, overriding any other apps that also register them (e.g. emacs-mac's
// Emacs.app or emacs-plus's "Emacs Client.app" for org-protocol).
//
// Usage:
//   swift goodies/set-default-handler.swift                 # defaults to org-protocol
//   swift goodies/set-default-handler.swift org-protocol emacs
//
// This sets a *user preference* for the preferred handler — it does not unregister the
// other apps (that wouldn't stick; they re-register themselves). It is reversible:
// set another app as default, or run the same command pointing elsewhere.
//
import AppKit

let bundleID = "io.alberti42.EmacsLauncher"   // must match CFBundleIdentifier in Info.plist
let schemes = CommandLine.arguments.count > 1
    ? Array(CommandLine.arguments.dropFirst())
    : ["org-protocol"]

func err(_ s: String) { FileHandle.standardError.write(Data(s.utf8)) }

guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
    err("error: \(bundleID) not found — is Emacs Launcher installed and registered?\n")
    exit(1)
}

func currentHandler(_ scheme: String) -> String {
    guard let url = URL(string: "\(scheme)://example"),
          let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return "(none)" }
    return app.lastPathComponent
}

var failed = false
for scheme in schemes {
    print("\(scheme):// — was: \(currentHandler(scheme))")
    let done = DispatchSemaphore(value: 0)
    NSWorkspace.shared.setDefaultApplication(at: appURL, toOpenURLsWithScheme: scheme) { error in
        if let error = error {
            err("  failed: \(error.localizedDescription)\n")
            failed = true
        } else {
            print("  now:  \(appURL.lastPathComponent)")
        }
        done.signal()
    }
    done.wait()
}
exit(failed ? 1 : 0)
