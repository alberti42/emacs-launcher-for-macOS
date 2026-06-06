// swift-tools-version:5.9
//
// SwiftPM package for the "Emacs Client" launcher app.
//
// `swift build -c release` produces the bare executable; emacsclient-swift-build.sh
// then wraps it in a proper .app bundle (Info.plist, icon) and registers the file
// type / org-protocol associations with Launch Services. SwiftPM alone does not
// emit a .app, hence the separate bundling step.
import PackageDescription

let package = Package(
    name: "EmacsClient",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "EmacsClient",
            path: "Sources/EmacsClient"
        )
    ]
)
