//
// The "⌥ Option" panel — shown on a bare launch with Option held (and on an ⌥-reopen
// while the app is resident). A small app-modal window with three visually separated
// sections:
//
//   1. Emacs daemon LaunchAgent — explanation + a single Install / Uninstall button.
//   2. Recent files source — choose the Emacs `recentf` file; its path is shown and
//      remembered (in UserDefaults). The chosen file is intended to feed a future
//      "recent files in Spotlight" feature — the parsing itself is not implemented yet.
//   3. Background activation — why the launcher stays resident after first use, with
//      Done and Kill Emacs Launcher buttons.
//
// Replaces the old single-NSAlert panel. Runs as an app-modal window (the rest of the
// app already drives modals from this accessory process); reverts the app to .accessory
// on close via finish().
//
import Cocoa

final class OptionPanelController: NSObject, NSWindowDelegate {
    /// UserDefaults key for the chosen `recentf` source file. Read later by the (not yet
    /// implemented) Spotlight recent-files feature.
    static let recentfPathKey = "RecentfSourcePath"

    private let contentWidth: CGFloat = 460
    private let inset: CGFloat = 20
    private var innerWidth: CGFloat { contentWidth - 2 * inset }

    private var window: NSWindow!
    private var agentStatusLabel: NSTextField!
    private var agentButton: NSButton!
    private var recentPathField: NSTextField!

    /// Strong self-reference held for the lifetime of the modal so the controller isn't
    /// deallocated while its window is on screen.
    private static var active: OptionPanelController?

    /// Build and run the panel modally, then revert the app to its resident, Dock-invisible
    /// state. Mirrors how the other dialogs flip to `.regular` to come to the front.
    func show() {
        OptionPanelController.active = self
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: contentWidth, height: 200),
                           styleMask: [.titled, .closable],
                           backing: .buffered, defer: false)
        win.title = "Emacs Launcher"
        win.isReleasedWhenClosed = false
        win.delegate = self
        window = win

        let content = NSView()
        win.contentView = content
        let stack = buildSections()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: contentWidth),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -inset),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: inset),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -inset),
        ])
        content.layoutSubtreeIfNeeded()
        win.setContentSize(NSSize(width: contentWidth, height: content.fittingSize.height))

        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: win)

        win.orderOut(nil)
        OptionPanelController.active = nil
        finish()
    }

    // MARK: - Layout

    private func buildSections() -> NSStackView {
        let outer = NSStackView()
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 16
        outer.translatesAutoresizingMaskIntoConstraints = false

        // — Section 1: LaunchAgent ————————————————————————————————————————
        agentStatusLabel = wrappingLabel("")
        agentButton = makeButton("", #selector(toggleAgent))
        refreshAgentSection()        // sets the status text and button title from state
        let agentSection = section(
            header: "Emacs Daemon LaunchAgent",
            body: "Emacs Launcher talks to a running Emacs daemon (emacs --daemon). "
                + "Installing this LaunchAgent starts a daemon at login and restarts it if "
                + "it exits, so there is always a daemon to talk to.",
            extras: [agentStatusLabel, agentButton])

        // — Section 2: recent files source ————————————————————————————————
        recentPathField = NSTextField(labelWithString: "")
        recentPathField.lineBreakMode = .byTruncatingMiddle
        recentPathField.isSelectable = true
        recentPathField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        recentPathField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        updateRecentPathField()

        let chooseButton = makeButton("Choose…", #selector(selectRecentf))
        chooseButton.setContentHuggingPriority(.required, for: .horizontal)
        let recentRow = NSStackView(views: [chooseButton, recentPathField])
        recentRow.orientation = .horizontal
        recentRow.spacing = 10
        recentRow.alignment = .firstBaseline

        let recentSection = section(
            header: "Recent Files for Spotlight",
            body: "Choose your Emacs recentf file (for example "
                + "~/.cache/emacs/recentf.eld). Its entries will be offered as recent files "
                + "in Spotlight.",
            extras: [recentRow])

        // — Section 3: background activation + Done / Kill ————————————————
        let killButton = makeButton("Kill Emacs Launcher", #selector(killLauncher))
        let doneButton = makeButton("Done", #selector(done), key: "\r")
        let buttonRow = NSStackView(views: [flexibleSpacer(), killButton, doneButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 12

        let residencySection = section(
            header: "Background Activation",
            body: "After its first launch, Emacs Launcher stays running in the background. "
                + "Its memory footprint is tiny, and staying resident lets it respond "
                + "instantly to Finder, Dock, Spotlight, and org-protocol requests instead "
                + "of paying a cold start each time. Kill Emacs Launcher stops it; it will "
                + "start again the next time something opens a file.",
            extras: [buttonRow])

        // Assemble with separators between sections.
        for (index, element) in [agentSection, recentSection, residencySection].enumerated() {
            if index > 0 { outer.addArrangedSubview(fullWidthSeparator(in: outer)) }
            outer.addArrangedSubview(element)
            pinFullWidth(element, in: outer)
        }
        // Full-width rows inside sections so spacers / truncation behave.
        pinFullWidth(recentRow, in: outer)
        pinFullWidth(buttonRow, in: outer)
        return outer
    }

    /// One section: a bold header, a wrapping body paragraph, then any extra controls.
    private func section(header: String, body: String, extras: [NSView]) -> NSStackView {
        let vstack = NSStackView(views: [headerLabel(header), wrappingLabel(body)] + extras)
        vstack.orientation = .vertical
        vstack.alignment = .leading
        vstack.spacing = 8
        vstack.translatesAutoresizingMaskIntoConstraints = false
        return vstack
    }

    // MARK: - Actions

    /// Install the LaunchAgent if absent, uninstall it if present, then refresh the section
    /// and report the outcome in a sheet-style alert.
    @objc private func toggleAgent() {
        let installed = FileManager.default.fileExists(atPath: launchAgentDestination().path)
        let (ok, message) = installed ? uninstallLaunchAgent() : installLaunchAgent()
        refreshAgentSection()
        let alert = makeWideAlert()
        alert.alertStyle = ok ? .informational : .warning
        alert.messageText = ok
            ? (installed ? "Uninstalled the LaunchAgent." : "Installed the LaunchAgent.")
            : (installed ? "Couldn't uninstall." : "Couldn't install.")
        alert.informativeText = message
        alert.runModal()
    }

    /// Recompute installed/reachable state and update the section's status text + button.
    private func refreshAgentSection() {
        let installed = FileManager.default.fileExists(atPath: launchAgentDestination().path)
        let reachable = EmacsServer.socketPath().map(EmacsServer.isReachable) ?? false
        let daemon = reachable ? "the daemon is running" : "no daemon is responding"
        agentStatusLabel.stringValue = installed
            ? "Status: installed — \(daemon)."
            : "Status: not installed — \(daemon)."
        agentButton.title = installed ? "Uninstall…" : "Install"
    }

    /// Pick the `recentf` file and remember its path. Defaults the open panel to the
    /// previously chosen file's folder, or ~/.cache/emacs.
    @objc private func selectRecentf() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose your Emacs recentf file"
        panel.prompt = "Choose"

        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: Self.recentfPathKey) {
            panel.directoryURL = URL(fileURLWithPath: existing).deletingLastPathComponent()
        } else {
            let cache = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache/emacs")
            if FileManager.default.fileExists(atPath: cache.path) { panel.directoryURL = cache }
        }

        if panel.runModal() == .OK, let url = panel.url {
            defaults.set(url.path, forKey: Self.recentfPathKey)
            updateRecentPathField()
        }
    }

    private func updateRecentPathField() {
        if let path = UserDefaults.standard.string(forKey: Self.recentfPathKey), !path.isEmpty {
            recentPathField.stringValue = path
            recentPathField.textColor = .labelColor
        } else {
            recentPathField.stringValue = "No file selected"
            recentPathField.textColor = .secondaryLabelColor
        }
    }

    @objc private func killLauncher() {
        NSApp.terminate(nil)
    }

    @objc private func done() {
        NSApp.stopModal()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.stopModal()
    }

    // MARK: - Small view helpers

    private func headerLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        return label
    }

    private func wrappingLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.preferredMaxLayoutWidth = innerWidth
        label.textColor = .secondaryLabelColor
        return label
    }

    private func makeButton(_ title: String, _ action: Selector, key: String = "") -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.keyEquivalent = key
        return button
    }

    /// An invisible view that expands to push trailing buttons to the right.
    private func flexibleSpacer() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        view.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return view
    }

    private func fullWidthSeparator(in outer: NSStackView) -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        return box
    }

    /// Stretch a child to the outer stack's full width (the leading-aligned stack would
    /// otherwise leave separators and button rows at their intrinsic width).
    private func pinFullWidth(_ view: NSView, in outer: NSStackView) {
        view.widthAnchor.constraint(equalTo: outer.widthAnchor).isActive = true
    }
}
