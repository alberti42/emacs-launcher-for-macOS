// swift-tools-version:5.9
//
// SwiftPM package for the "Emacs Launcher" app.
//
// `swift build -c release` produces the bare executable; emacs-launcher-build.sh
// then wraps it in a proper .app bundle (Info.plist, icon) and registers the file
// type / org-protocol associations with Launch Services. SwiftPM alone does not
// emit a .app, hence the separate bundling step.
import PackageDescription

let package = Package(
    name: "EmacsLauncher",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "EmacsLauncher",
            path: "Sources/EmacsLauncher"
        )
    ]
)
