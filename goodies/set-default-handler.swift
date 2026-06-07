//
// set-default-handler.swift — list the apps macOS will let you choose as the handler
// for Emacs Launcher's URL schemes, and set one as the default.
//
// List (no arguments):
//   swift goodies/set-default-handler.swift
//     org-protocol://
//      → 01  Emacs Launcher    /Users/you/Applications/Emacs Launcher.app
//     emacs://
//      → 02  Emacs Launcher    /Users/you/Applications/Emacs Launcher.app
//   ("→" marks the current default.)
//
// Set (one or more numbers from the list, processed in order):
//   swift goodies/set-default-handler.swift 01
//   swift goodies/set-default-handler.swift 01 02
//
// Note: handlers are keyed by *bundle id*, not path. An app that registers a scheme
// but whose bundle id resolves (via Launch Services) to a different copy — or not at
// all — will NOT appear here, even though `lsregister -dump` lists it. That's why this
// list can be shorter than the raw registration dump. Setting a default writes a
// reversible user preference; it does not unregister anything.
//
import AppKit

let schemes = ["org-protocol", "emacs"]

func err(_ s: String) { FileHandle.standardError.write(Data(s.utf8)) }
func sampleURL(_ scheme: String) -> URL { URL(string: "\(scheme)://example")! }
func twoDigits(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
func name(_ app: URL) -> String { app.deletingPathExtension().lastPathComponent }

// Build a single, global numbering across both scheme groups (deterministic order).
struct Entry { let number: Int; let scheme: String; let app: URL }
var entries: [Entry] = []
var counter = 0
for scheme in schemes {
    for app in NSWorkspace.shared.urlsForApplications(toOpen: sampleURL(scheme)) {
        counter += 1
        entries.append(Entry(number: counter, scheme: scheme, app: app))
    }
}

func currentDefaultPath(_ scheme: String) -> String? {
    NSWorkspace.shared.urlForApplication(toOpen: sampleURL(scheme))?.path
}

let args = Array(CommandLine.arguments.dropFirst())

// ---- List mode ----
if args.isEmpty {
    for scheme in schemes {
        let def = currentDefaultPath(scheme)
        print("\(scheme)://")
        let group = entries.filter { $0.scheme == scheme }
        if group.isEmpty { print("   (no selectable handler registered)") }
        for e in group {
            let mark = e.app.path == def ? "\u{2192}" : " "   // → marks current default
            print(" \(mark) \(twoDigits(e.number))  \(name(e.app))   \(e.app.path)")
        }
        print("")
    }
    print("Set a default:  swift goodies/set-default-handler.swift <number> [<number> …]")
    print("Numbers are global across both lists; pass one per scheme, applied in order.")
    exit(0)
}

// ---- Set mode ----
var failed = false
for arg in args {
    guard let num = Int(arg), let e = entries.first(where: { $0.number == num }) else {
        err("skip: \"\(arg)\" is not a listed number (run with no arguments to list)\n")
        failed = true
        continue
    }
    let done = DispatchSemaphore(value: 0)
    NSWorkspace.shared.setDefaultApplication(at: e.app, toOpenURLsWithScheme: e.scheme) { error in
        if let error = error {
            err("\(twoDigits(num)) failed: \(error.localizedDescription)\n")
            failed = true
        } else {
            print("\(twoDigits(num))  \(e.scheme):// \u{2192} \(name(e.app))")
        }
        done.signal()
    }
    done.wait()
}
exit(failed ? 1 : 0)
