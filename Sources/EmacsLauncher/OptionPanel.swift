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
    private let contentWidth: CGFloat = 460
    private let inset: CGFloat = 20
    private var innerWidth: CGFloat { contentWidth - 2 * inset }

    private var window: NSWindow!
    private var agentStatusLabel: NSTextField!
    private var agentButton: NSButton!
    private var recentPathField: NSTextField!
    private var useDetectedButton: NSButton!
    private var killButton: NSButton!

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

        let chooseButton = makeButton("Choose Override…", #selector(selectRecentf))
        useDetectedButton = makeButton("Use Detected", #selector(useDetected))
        let recentButtons = NSStackView(views: [chooseButton, useDetectedButton])
        recentButtons.orientation = .horizontal
        recentButtons.spacing = 10

        let spotlightToggle = NSButton(checkboxWithTitle: "Index recent files in Spotlight",
                                       target: self, action: #selector(toggleSpotlight))
        spotlightToggle.state = SpotlightIndex.isEnabled ? .on : .off

        RecentFiles.detectPath()        // refresh the detected-path cache for display
        updateRecentPathField()

        let recentSection = section(
            header: "Recent Files for Spotlight",
            body: "Emacs Launcher detects your recentf file automatically from the running "
                + "daemon and offers its recent entries in Spotlight, opening them in Emacs. "
                + "Choose an override only if you want to point at a specific file instead.",
            extras: [spotlightToggle, recentButtons, recentPathField])

        // — Section 3: background activation + Done / Kill ————————————————
        let warmStartToggle = NSButton(checkboxWithTitle: "Keep running in the background (recommended)",
                                       target: self, action: #selector(toggleWarmStart))
        warmStartToggle.state = residentModeEnabled ? .on : .off

        killButton = makeButton("Kill Emacs Launcher", #selector(killLauncher))
        killButton.isEnabled = residentModeEnabled       // nothing to kill in cold-start mode
        let doneButton = makeButton("Done", #selector(done), key: "\r")
        let buttonRow = NSStackView(views: [flexibleSpacer(), killButton, doneButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 12

        let residencySection = section(
            header: "Background Activation",
            body: "After its first launch, Emacs Launcher can stay resident in the background "
                + "(warm start) so it responds instantly to Finder, Dock, Spotlight, and "
                + "org-protocol requests instead of paying a cold start each time; its memory "
                + "footprint is tiny (~10 MB, mostly the AppKit framework). This is "
                + "recommended. Turn it off for a cold start — the app quits after each use, "
                + "and Kill Emacs Launcher then has nothing to stop.",
            extras: [warmStartToggle, buttonRow])

        // Assemble with separators between sections.
        for (index, element) in [agentSection, recentSection, residencySection].enumerated() {
            if index > 0 { outer.addArrangedSubview(fullWidthSeparator(in: outer)) }
            outer.addArrangedSubview(element)
            pinFullWidth(element, in: outer)
        }
        // Full-width rows inside sections so spacers / truncation behave.
        pinFullWidth(recentPathField, in: outer)
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

    /// Pick a `recentf` file to use as an override and remember it. Defaults the open panel
    /// to the current override / detected file's folder, or ~/.cache/emacs.
    @objc private func selectRecentf() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a recentf file to use instead of the detected one"
        panel.prompt = "Choose"

        if let existing = RecentFiles.effectivePath() {
            panel.directoryURL = URL(fileURLWithPath: existing).deletingLastPathComponent()
        } else {
            let cache = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache/emacs")
            if FileManager.default.fileExists(atPath: cache.path) { panel.directoryURL = cache }
        }

        if panel.runModal() == .OK, let url = panel.url {
            UserDefaults.standard.set(url.path, forKey: RecentFiles.overridePathKey)
            updateRecentPathField()
        }
    }

    /// Turn Spotlight indexing on (reindex now) or off (clear our items).
    @objc private func toggleSpotlight(_ sender: NSButton) {
        SpotlightIndex.setEnabled(sender.state == .on)
    }

    /// Turn warm start (resident) on or off. The change takes effect when the panel closes
    /// (`finish()` keeps the app alive or quits accordingly). With it off there's nothing
    /// for Kill Emacs Launcher to act on, so disable that button.
    @objc private func toggleWarmStart(_ sender: NSButton) {
        let on = sender.state == .on
        UserDefaults.standard.set(on, forKey: residentModeKey)
        killButton.isEnabled = on
    }

    /// Clear the override and go back to the auto-detected path.
    @objc private func useDetected() {
        UserDefaults.standard.removeObject(forKey: RecentFiles.overridePathKey)
        updateRecentPathField()
    }

    /// Show the override (if set) or the detected path, and enable "Use Detected" only when
    /// an override is in effect.
    private func updateRecentPathField() {
        let defaults = UserDefaults.standard
        let override = defaults.string(forKey: RecentFiles.overridePathKey)
        let detected = defaults.string(forKey: RecentFiles.detectedPathKey)
        useDetectedButton.isEnabled = !(override?.isEmpty ?? true)

        if let override, !override.isEmpty {
            recentPathField.stringValue = "Override: \(override)"
            recentPathField.textColor = .labelColor
        } else if let detected, !detected.isEmpty {
            recentPathField.stringValue = "Detected: \(detected)"
            recentPathField.textColor = .secondaryLabelColor
        } else {
            recentPathField.stringValue = "Not detected — is the Emacs daemon running?"
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
