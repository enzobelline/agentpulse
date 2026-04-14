import AppKit
import AgentPulseLib

@MainActor
final class StatusBarController: NSObject, SessionStoreDelegate, NSMenuDelegate {
    private let store: SessionStore
    private let statusItem: NSStatusItem
    private let worktreeManager = WorktreeManager()
    private var spinnerIdx = 0

    /// Tracked session menu items for in-place title updates (spinner animation while menu is open)
    private var sessionMenuItems: [(key: String, item: NSMenuItem)] = []
    /// Whether the menu structure needs a full rebuild (sessions added/removed/reordered)
    var menuNeedsRebuild = true
    /// Fast timer for spinner animation while the menu is open
    private var animationTimer: Timer?
    /// Whether the dropdown menu is currently open (tracking events)
    private var menuIsOpen = false

    private var globalHotkeyMonitor: Any?
    private let historySearchHandler = HistorySearchHandler()
    private let historyActionTarget = HistoryActionTarget()

    init(store: SessionStore) {
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        statusItem.button?.title = Constants.iconSleeping
        registerGlobalHotkey()
    }

    private func registerGlobalHotkey() {
        // Request Accessibility permission if not already granted
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let trusted = AXIsProcessTrustedWithOptions(
            [key: true] as CFDictionary
        )
        if !trusted {
            // macOS will show the Accessibility prompt — hotkey will work after user grants it and restarts
            return
        }

        // Ctrl+Option+A to toggle the dropdown
        globalHotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let required: NSEvent.ModifierFlags = [.control, .option]
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(required),
                  event.charactersIgnoringModifiers == "a" else { return }
            MainActor.assumeIsolated {
                self?.toggleMenu()
            }
        }
    }

    private func toggleMenu() {
        guard let button = statusItem.button else { return }
        button.performClick(nil)
    }

    // MARK: - SessionStoreDelegate

    nonisolated func sessionStoreDidUpdate() {
        MainActor.assumeIsolated {
            refresh()
        }
    }

    // MARK: - Public

    func refresh() {
        updateTitle()
        if menuNeedsRebuild || sessionKeysChanged() {
            if menuIsOpen {
                // Defer rebuild — replacing the menu while it's open breaks item references
                menuNeedsRebuild = true
                updateMenuTitles()
            } else {
                buildMenu()
                menuNeedsRebuild = false
            }
        } else {
            updateMenuTitles()
        }
    }

    func checkFirstRun() {
        guard !store.settings.firstRunComplete else { return }

        let alert = NSAlert()
        alert.messageText = "AgentPulse"
        alert.informativeText = """
            Claude Code session monitoring is active.

            Icons in the menubar show each session's status:
            \(Constants.spinnerFrames[0]) Running  \(Constants.iconWaiting) Waiting  \(Constants.iconDone) Done  \(Constants.iconSleeping) No sessions

            You'll get desktop notifications when sessions finish or need input.

            Tip: On MacBooks with a notch, the icon may be hidden behind other menubar items. Hold ⌘ and drag it to a visible spot, or go to System Settings → Displays → "More Space" for extra menubar room.

            Permissions needed:
            • Automation → Terminal: Required for "Attach to Session" and "Open in Terminal" (macOS will prompt on first use)
            • Notifications: Allow when prompted for desktop notification banners
            """
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't show this again"
        alert.addButton(withTitle: "OK")
        alert.runModal()

        if alert.suppressionButton?.state == .on {
            store.settings.firstRunComplete = true
            store.saveSettings()
        }
    }

    // MARK: - NSMenuDelegate

    nonisolated func menuWillOpen(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            menuIsOpen = true
            startAnimationTimer()
        }
    }

    nonisolated func menuDidClose(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            menuIsOpen = false
            stopAnimationTimer()
            // Apply any deferred rebuild
            if menuNeedsRebuild {
                refresh()
            }
        }
    }

    private func startAnimationTimer() {
        guard animationTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.animateSpinner()
            }
        }
        RunLoop.current.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func stopAnimationTimer() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    private func animateSpinner() {
        updateTitle()
        updateMenuTitles()
    }

    // MARK: - Title

    private func updateTitle() {
        let all = store.sessions
        guard !all.isEmpty else {
            statusItem.button?.title = Constants.iconSleeping
            return
        }

        spinnerIdx = (spinnerIdx + 1) % Constants.spinnerFrames.count

        let sorted = AgentPulseLib.sortedByPriority(all.map { $0 }, pinnedSessions: store.settings.pinnedSessions)
        let pinnedSet = Set(store.settings.pinnedSessions)
        let maxVisible = store.settings.maxVisibleSessions

        // Pinned always show; fill remaining slots with unpinned
        let allPinned = sorted.filter { pinnedSet.contains($0.key) }
        let allUnpinned = sorted.filter { !pinnedSet.contains($0.key) }
        let unpinnedSlots = max(0, maxVisible - allPinned.count)
        let pinnedVisible = allPinned
        let unpinnedVisible = Array(allUnpinned.prefix(unpinnedSlots))
        let overflow = sorted.count - pinnedVisible.count - unpinnedVisible.count

        var allParts: [String] = []

        if !pinnedVisible.isEmpty {
            var pinnedParts: [String] = []
            for (_, session) in pinnedVisible {
                let icon = iconFor(session)
                let sym = AgentPulseLib.displaySymbol(for: session)
                pinnedParts.append("\(icon) \(sym)")
            }
            allParts.append("[ \(pinnedParts.joined(separator: "  ")) ]")
        }

        for (_, session) in unpinnedVisible {
            let icon = iconFor(session)
            let sym = AgentPulseLib.displaySymbol(for: session)
            allParts.append("\(icon) \(sym)")
        }

        if overflow > 0 {
            allParts.append("(\(overflow))")
        }

        statusItem.button?.title = allParts.joined(separator: " ")
    }

    // MARK: - Menu

    /// Check if the session keys/order changed since last menu build
    private func sessionKeysChanged() -> Bool {
        let sorted = AgentPulseLib.sortedByPriority(store.sessions.map { $0 }, pinnedSessions: store.settings.pinnedSessions)
        let currentKeys = sorted.map(\.key)
        let trackedKeys = sessionMenuItems.map(\.key)
        return currentKeys != trackedKeys
    }

    /// Build the title string for a session menu item
    private func sessionTitle(key: String, session: Session, isPinned: Bool, now: TimeInterval) -> String {
        let icon = iconFor(session)
        let pinPrefix = isPinned ? "▸ " : ""
        let dirName = URL(fileURLWithPath: session.directory ?? session.name).lastPathComponent
        let symbol = AgentPulseLib.displaySymbol(for: session)
        let sym: String
        if let lineage = AgentPulseLib.worktreeLineage(directoryName: dirName) {
            sym = "\(symbol) \(lineage.word) → \(lineage.repo)"
        } else {
            sym = symbol
        }
        let summary = AgentPulseLib.displaySummary(for: session)
        let lastUpdate = session.updatedAt > 0
            ? formatDuration(now - session.updatedAt) : ""

        // Build the description part: "Name | prompt" if renamed, just "prompt" otherwise
        // Total budget ~65 chars. Name displays up to 25, prompt gets the rest.
        let desc: String
        if let name = session.displayName, !name.isEmpty {
            let maxNameDisplay = 25
            let displayName = name.count > maxNameDisplay
                ? String(name.prefix(maxNameDisplay - 1)) + "…"
                : name
            let promptBudget = max(0, 65 - displayName.count - 3) // -3 for " | "
            if promptBudget > 8, !summary.isEmpty {
                let truncated = summary.count > promptBudget
                    ? String(summary.prefix(promptBudget - 1)) + "…"
                    : summary
                desc = "\(displayName) | \(truncated)"
            } else {
                desc = displayName
            }
        } else {
            desc = summary
        }

        let prefix = "\(pinPrefix)\(icon) \(sym) · "
        let suffix = !lastUpdate.isEmpty ? " (\(lastUpdate))" : ""
        let maxDesc = 75 - prefix.count - suffix.count

        // Truncate desc if needed to fit budget
        let fitDesc = desc.count > maxDesc && maxDesc > 3
            ? String(desc.prefix(maxDesc - 1)) + "…"
            : desc

        var label = "\(prefix)\(fitDesc)\(suffix)"

        // Show activity inline if running
        if session.status == "running", let activity = AgentPulseLib.displayActivity(for: session) {
            let actBudget = 80 - label.count - 3 // -3 for " — "
            if actBudget > 5 {
                let fitAct = activity.count > actBudget
                    ? String(activity.prefix(actBudget - 1)) + "…"
                    : activity
                label += " — \(fitAct)"
            }
        }
        return label
    }

    /// Update just the titles of existing session menu items (spinner + durations)
    private func updateMenuTitles() {
        let now = Date().timeIntervalSince1970
        let pinnedSet = Set(store.settings.pinnedSessions)

        let all = store.sessions
        for (key, item) in sessionMenuItems {
            guard let session = all[key] else { continue }
            let isPinned = pinnedSet.contains(key)
            item.title = sessionTitle(key: key, session: session, isPinned: isPinned, now: now)
            item.image = nil
        }
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.minimumWidth = 550
        sessionMenuItems = []

        let allForMenu = store.sessions
        if allForMenu.isEmpty {
            let noSessions = NSMenuItem(title: "No active sessions", action: nil, keyEquivalent: "")
            noSessions.isEnabled = false
            menu.addItem(noSessions)
            menu.addItem(.separator())
        } else {
            let now = Date().timeIntervalSince1970
            let sorted = AgentPulseLib.sortedByPriority(allForMenu.map { $0 }, pinnedSessions: store.settings.pinnedSessions)

            let pinnedSet = Set(store.settings.pinnedSessions)

            // Group sessions by directory for visual clarity
            // Worktree directories group with their parent repo
            var groups: [(directory: String, items: [(key: String, session: Session)])] = []
            var groupIndex: [String: Int] = [:]
            for (key, session) in sorted {
                let dir = session.directory ?? session.name
                let gk = AgentPulseLib.groupKey(forDirectory: dir)
                if let idx = groupIndex[gk] {
                    groups[idx].items.append((key: key, session: session))
                } else {
                    groupIndex[gk] = groups.count
                    groups.append((directory: gk, items: [(key: key, session: session)]))
                }
            }

            let needsGroupHeaders = groups.count > 1

            for (groupIdx, group) in groups.enumerated() {
                if needsGroupHeaders {
                    if groupIdx > 0 {
                        menu.addItem(.separator())
                    }
                    let dirName = URL(fileURLWithPath: group.directory).lastPathComponent
                    let header = NSMenuItem(title: dirName, action: nil, keyEquivalent: "")
                    header.isEnabled = false
                    // Bold font for group headers
                    header.attributedTitle = NSAttributedString(
                        string: dirName,
                        attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)]
                    )
                    menu.addItem(header)
                }

                for (key, session) in group.items {
                    let isPinned = pinnedSet.contains(key)
                    let started = session.startedAt ?? session.updatedAt
                    let duration = started > 0 ? formatDuration(now - started) : ""

                    let label = sessionTitle(key: key, session: session, isPinned: isPinned, now: now)
                    let sessionItem = NSMenuItem(title: label, action: nil, keyEquivalent: "")
                    sessionItem.representedObject = key
                    sessionItem.image = nil
                    if needsGroupHeaders {
                        sessionItem.indentationLevel = 1
                    }
                    let submenu = NSMenu()

                    // Go to Terminal (first item — primary action)
                    let goItem = NSMenuItem(title: "Go to Terminal", action: #selector(attachToSession(_:)), keyEquivalent: "")
                    goItem.target = self
                    goItem.representedObject = key
                    submenu.addItem(goItem)
                    submenu.addItem(.separator())

                    // Pin
                    let pinLabel = isPinned ? "▸ Unpin" : "▹ Pin"
                    let pinItem = NSMenuItem(title: pinLabel, action: #selector(togglePin(_:)), keyEquivalent: "")
                    pinItem.target = self
                    pinItem.representedObject = key
                    submenu.addItem(pinItem)

                    // Rename
                    let renameItem = NSMenuItem(title: "Rename", action: #selector(renameSession(_:)), keyEquivalent: "")
                    renameItem.target = self
                    renameItem.representedObject = key
                    submenu.addItem(renameItem)

                    // Open New Session (opens Terminal + runs claude)
                    let openItem = NSMenuItem(title: "Open New Session", action: #selector(openNewSession(_:)), keyEquivalent: "")
                    openItem.target = self
                    openItem.representedObject = session.directory ?? session.name
                    submenu.addItem(openItem)

                    // Create New Worktree
                    let worktreeItem = NSMenuItem(title: "Create New Worktree", action: #selector(branchSession(_:)), keyEquivalent: "")
                    worktreeItem.target = self
                    worktreeItem.representedObject = session.directory ?? session.name
                    submenu.addItem(worktreeItem)

                    // Copy Session ID
                    let sidLabel = shortSessionId(key)
                    let sidItem = NSMenuItem(title: sidLabel, action: #selector(copySessionId(_:)), keyEquivalent: "")
                    sidItem.target = self
                    sidItem.representedObject = key
                    submenu.addItem(sidItem)

                    // Copy Path
                    let pathLabel = "Copy Path · \(abbreviatedPath(session.directory ?? session.name))"
                    let pathItem = NSMenuItem(title: pathLabel, action: #selector(copySessionPath(_:)), keyEquivalent: "")
                    pathItem.target = self
                    pathItem.representedObject = session.directory ?? session.name
                    submenu.addItem(pathItem)

                    let dismissLabel = duration.isEmpty ? "Dismiss" : "\(duration) · Dismiss"
                    let dismissItem = NSMenuItem(title: dismissLabel, action: #selector(dismissSession(_:)), keyEquivalent: "")
                    dismissItem.target = self
                    dismissItem.representedObject = key
                    submenu.addItem(dismissItem)

                    sessionItem.submenu = submenu
                    menu.addItem(sessionItem)
                    sessionMenuItems.append((key: key, item: sessionItem))
                }
            }

            menu.addItem(.separator())
        }

        // Clear done sessions (local only)
        let doneCount = store.sessions.values.filter { $0.status == "done" }.count
        // Clear submenu
        let clearItem = NSMenuItem(title: "Clear", action: nil, keyEquivalent: "")
        let clearSubmenu = NSMenu()

        if doneCount > 0 {
            let clearDone = NSMenuItem(
                title: "Clear Done Sessions (\(doneCount))",
                action: #selector(clearDoneSessions),
                keyEquivalent: ""
            )
            clearDone.target = self
            clearSubmenu.addItem(clearDone)
        }
        if !store.sessions.isEmpty {
            let clearAll = NSMenuItem(
                title: "Clear All Sessions",
                action: #selector(clearAllSessions),
                keyEquivalent: ""
            )
            clearAll.target = self
            clearSubmenu.addItem(clearAll)
        }
        if doneCount > 0 || !store.sessions.isEmpty {
            clearSubmenu.addItem(.separator())
        }

        let ttl = store.settings.autoClearAfterMinutes
        let ttlLabel = "Auto-Clear Done: \(AgentPulseLib.autoClearLabel(ttl))"
        let ttlItem = NSMenuItem(title: ttlLabel, action: nil, keyEquivalent: "")
        let ttlSubmenu = NSMenu()
        for option in Constants.autoClearOptions {
            let label = AgentPulseLib.autoClearLabel(option)
            let item = NSMenuItem(title: label, action: #selector(setAutoClear(_:)), keyEquivalent: "")
            item.target = self
            item.tag = option
            if option == ttl { item.state = .on }
            ttlSubmenu.addItem(item)
        }
        ttlItem.submenu = ttlSubmenu
        clearSubmenu.addItem(ttlItem)

        clearItem.submenu = clearSubmenu
        menu.addItem(clearItem)

        // Notifications submenu
        let notifItem = NSMenuItem(title: "Notifications", action: nil, keyEquivalent: "")
        let notifSubmenu = NSMenu()

        let notifToggleLabel = "Notifications: \(store.settings.notificationsEnabled ? "On" : "Off")"
        let notifToggle = NSMenuItem(title: notifToggleLabel, action: #selector(toggleNotifications), keyEquivalent: "")
        notifToggle.target = self
        notifSubmenu.addItem(notifToggle)

        let soundOn = store.settings.soundEnabled
        let soundToggle = NSMenuItem(title: "Sound: \(soundOn ? "On" : "Off")", action: #selector(toggleSound), keyEquivalent: "")
        soundToggle.target = self
        notifSubmenu.addItem(soundToggle)

        notifSubmenu.addItem(.separator())

        let waitingItem = NSMenuItem(title: "Waiting: \(store.settings.waitingSound)", action: nil, keyEquivalent: "")
        waitingItem.submenu = SoundPickerMenu(current: store.settings.waitingSound) { [weak self] sound in
            self?.store.settings.waitingSound = sound
            self?.store.saveSettings()
            self?.menuNeedsRebuild = true
            self?.refresh()
        }
        notifSubmenu.addItem(waitingItem)

        let doneItem = NSMenuItem(title: "Done: \(store.settings.doneSound)", action: nil, keyEquivalent: "")
        doneItem.submenu = SoundPickerMenu(current: store.settings.doneSound) { [weak self] sound in
            self?.store.settings.doneSound = sound
            self?.store.saveSettings()
            self?.menuNeedsRebuild = true
            self?.refresh()
        }
        notifSubmenu.addItem(doneItem)

        notifItem.submenu = notifSubmenu
        menu.addItem(notifItem)

        // Visible sessions count
        let visibleItem = NSMenuItem(title: "Visible: \(store.settings.maxVisibleSessions)", action: nil, keyEquivalent: "")
        let visibleSubmenu = NSMenu()
        for n in Constants.maxVisibleRange {
            let item = NSMenuItem(title: "\(n)", action: #selector(setMaxVisible(_:)), keyEquivalent: "")
            item.target = self
            item.tag = n
            if n == store.settings.maxVisibleSessions {
                item.state = .on
            }
            visibleSubmenu.addItem(item)
        }
        visibleItem.submenu = visibleSubmenu
        menu.addItem(visibleItem)

        // Session history
        let history = SessionHistory.shared.load()
        if !history.isEmpty {
            let historyItem = NSMenuItem(title: "History (\(history.count))", action: nil, keyEquivalent: "")
            let historySubmenu = NSMenu()
            historySubmenu.delegate = historySearchHandler
            historySearchHandler.buildHistoryMenu(historySubmenu, history: history, controller: self, actionTarget: historyActionTarget)

            historyItem.submenu = historySubmenu
            menu.addItem(historyItem)
        }

        menu.addItem(.separator())

        // Help submenu
        let helpItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        let helpSubmenu = NSMenu()

        let shortcutsItem = NSMenuItem(title: "Keyboard Shortcuts", action: #selector(showShortcuts), keyEquivalent: "")
        shortcutsItem.target = self
        helpSubmenu.addItem(shortcutsItem)

        let bugItem = NSMenuItem(title: "Report a Bug", action: #selector(openBugReport), keyEquivalent: "")
        bugItem.target = self
        helpSubmenu.addItem(bugItem)

        helpSubmenu.addItem(.separator())

        let aboutItem = NSMenuItem(title: "About AgentPulse", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        helpSubmenu.addItem(aboutItem)

        helpItem.submenu = helpSubmenu
        menu.addItem(helpItem)

        let quit = NSMenuItem(title: "Quit AgentPulse", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        menu.delegate = self
        statusItem.menu = menu
    }

    // MARK: - Helpers

    private func iconFor(_ s: Session) -> String {
        switch s.status {
        case "running": return Constants.spinnerFrames[spinnerIdx]
        case "waiting": return Constants.iconWaiting
        case "done":    return Constants.iconDone
        default:        return Constants.iconSleeping
        }
    }


    // MARK: - Actions

    @objc private func copySessionId(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key, forType: .string)
    }

    @objc private func copySessionPath(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    @objc private func togglePin(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        store.togglePin(key)
        menuNeedsRebuild = true
        refresh()
    }

    @objc private func dismissSession(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        store.removeSessions([key])
        menuNeedsRebuild = true
        refresh()
    }

    @objc private func clearDoneSessions() {
        let doneKeys = store.sessions.filter { $0.value.status == "done" }.map(\.key)
        store.removeSessions(doneKeys)
        menuNeedsRebuild = true
        refresh()
    }

    @objc private func clearAllSessions() {
        let allKeys = Array(store.sessions.keys)
        store.removeSessions(allKeys)
        menuNeedsRebuild = true
        refresh()
    }

    @objc private func toggleNotifications() {
        store.settings.notificationsEnabled.toggle()
        store.saveSettings()
        menuNeedsRebuild = true
        refresh()
    }

    @objc private func toggleSound() {
        store.settings.soundEnabled.toggle()
        store.saveSettings()
        menuNeedsRebuild = true
        refresh()
    }

    @objc private func setMaxVisible(_ sender: NSMenuItem) {
        store.settings.maxVisibleSessions = sender.tag
        store.saveSettings()
        menuNeedsRebuild = true
        refresh()
    }

    @objc private func setAutoClear(_ sender: NSMenuItem) {
        store.settings.autoClearAfterMinutes = sender.tag
        store.saveSettings()
        menuNeedsRebuild = true
        refresh()
    }

    @objc private func attachToSession(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        let session = store.sessions[key]

        switch resolveAttachAction(session: session, sessionKey: key) {
        case .openTerminal(let dir):
            openTerminalAt(dir)

        case .activateWindow(let tty):
            // Shell out to osascript — NSAppleScript from ad-hoc signed apps
            // doesn't get Space-switching privileges, but osascript does.
            let script = """
                tell application "Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is "\(tty)" then
                                set selected tab of w to t
                                set frontmost of w to true
                                activate
                                return "found"
                            end if
                        end repeat
                    end repeat
                    return "not found"
                end tell
                """
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if output != "found" {
                    let dir = session?.directory ?? key
                    openTerminalAt(dir)
                }
            } catch {
                let dir = session?.directory ?? key
                openTerminalAt(dir)
            }
        }
    }

    /// Open a new Terminal window cd'd to the given path
    private func openTerminalAt(_ path: String) {
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
            tell application "Terminal"
                activate
                do script "cd \\"\(escaped)\\""
            end tell
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }

    @objc private func branchSession(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        worktreeManager.branchFromSession(directory: path)
    }

    @objc nonisolated func copyKeywords(_ sender: NSMenuItem) {
        guard let kw = sender.representedObject as? [String] else { return }
        let text = kw.joined(separator: ", ")
        nonisolated(unsafe) let item = sender
        MainActor.assumeIsolated {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            item.title = "🏷 Copied!"
        }
    }

    @objc nonisolated func deleteHistoryEntry(_ sender: NSMenuItem) {
        let tag = sender.tag
        MainActor.assumeIsolated {
            SessionHistory.shared.removeEntry(at: tag)
            self.menuNeedsRebuild = true
            self.refresh()
        }
    }

    @objc nonisolated func clearHistory() {
        MainActor.assumeIsolated {
            let alert = NSAlert()
            alert.messageText = "Clear History"
            alert.informativeText = "Are you sure you want to clear all session history? This cannot be undone."
            alert.addButton(withTitle: "Clear")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                SessionHistory.shared.clearAll()
                self.menuNeedsRebuild = true
                self.refresh()
            }
        }
    }

    @objc private func openNewSession(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
            tell application "Terminal"
                activate
                do script "cd \\"\(escaped)\\" && claude"
            end tell
            """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }

    @objc private func renameSession(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        let currentName = store.sessions[key]?.displayName ?? store.sessions[key]?.summary ?? ""

        let alert = NSAlert()
        alert.messageText = "Rename Session"
        alert.informativeText = "Enter a name for this session (max 40 chars):"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = currentName
        input.placeholderString = "e.g. auth refactor, bug #342"
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let raw = input.stringValue.trimmingCharacters(in: .whitespaces)
            let newName = raw.count > 40 ? String(raw.prefix(40)) : raw
            store.renameSession(key, displayName: newName.isEmpty ? nil : newName)
            // Update Terminal tab title via AppleScript (safe — no TTY writes)
            if let tty = store.sessions[key]?.tty {
                setTerminalTabTitle(tty: tty, title: newName.isEmpty ? nil : newName)
            }
            menuNeedsRebuild = true
            refresh()
        }
    }

    /// Set or clear the Terminal.app tab title for a given TTY, using AppleScript.
    /// Does not write to the TTY stream — purely Terminal.app UI.
    private func setTerminalTabTitle(tty: String, title: String?) {
        let escaped = tty.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script: String
        if let title = title {
            let escapedTitle = title.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            script = """
                tell application "Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is "\(escaped)" then
                                set custom title of t to "\(escapedTitle)"
                                set title displays custom title of t to true
                            end if
                        end repeat
                    end repeat
                end tell
                """
        } else {
            // Clear custom title — revert to default
            script = """
                tell application "Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is "\(escaped)" then
                                set title displays custom title of t to false
                            end if
                        end repeat
                    end repeat
                end tell
                """
        }
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }

    @objc private func showShortcuts() {
        let alert = NSAlert()
        alert.messageText = "Keyboard Shortcuts"
        alert.informativeText = """
            ⌃⌥A — Toggle AgentPulse dropdown
            ⌘Q — Quit AgentPulse (from dropdown)

            Click a session row to attach to its Terminal tab.
            """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func openBugReport() {
        if let url = URL(string: "https://github.com/enzobelline/agentpulse/issues/new") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "AgentPulse"
        alert.informativeText = """
            Real-time Claude Code session monitor for your macOS menubar.

            Version 3.0.0
            github.com/enzobelline/agentpulse
            """
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open GitHub")
        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            if let url = URL(string: "https://github.com/enzobelline/agentpulse") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    /// Short session ID (first 4 chars of UUID) for display
    private func shortSessionId(_ key: String) -> String {
        let prefix = String(key.prefix(4))
        return "Copy Session ID · \(prefix)"
    }

    /// Abbreviated path: "/…" + last component truncated to 9 chars
    private func abbreviatedPath(_ path: String) -> String {
        let last = URL(fileURLWithPath: path).lastPathComponent
        let truncated = last.count > 9 ? String(last.prefix(9)) : last
        return "/…\(truncated)"
    }
}

// MARK: - History Action Target (NOT @MainActor — required for NSMenu dispatch)

/// Plain NSObject target for history submenu actions.
/// NSMenu's ObjC runtime cannot dispatch to @MainActor classes.
final class HistoryActionTarget: NSObject {
    @objc func resumeSession(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let dir = info["directory"] as? String,
              let sessionId = info["sessionId"] as? String else { return }
        // Write a .command file that Terminal opens natively — no automation permission needed
        let tmpPath = NSTemporaryDirectory() + "agentpulse-resume.command"
        let script = "#!/bin/bash\ncd \"\(dir)\" && claude --resume \(sessionId)\n"
        do {
            try script.write(toFile: tmpPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmpPath)
            NSWorkspace.shared.open(URL(fileURLWithPath: tmpPath))
        } catch {}
    }

    @objc func resumeSessionDangerous(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let dir = info["directory"] as? String,
              let sessionId = info["sessionId"] as? String else { return }
        let tmpPath = NSTemporaryDirectory() + "agentpulse-resume.command"
        let script = "#!/bin/bash\ncd \"\(dir)\" && claude --resume \(sessionId) --dangerously-skip-permissions\n"
        do {
            try script.write(toFile: tmpPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmpPath)
            NSWorkspace.shared.open(URL(fileURLWithPath: tmpPath))
        } catch {}
    }

    @objc func copyResumeCommand(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let dir = info["directory"] as? String,
              let sessionId = info["sessionId"] as? String else { return }
        let command = "cd \"\(dir)\" && claude --resume \(sessionId)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        sender.title = "Copied!"
    }

    @objc func copyKeywords(_ sender: NSMenuItem) {
        guard let kw = sender.representedObject as? [String] else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(kw.joined(separator: ", "), forType: .string)
        sender.title = "🏷 Copied!"
    }

    @objc func deleteHistoryEntry(_ sender: NSMenuItem) {
        let tag = sender.tag
        DispatchQueue.main.async {
            SessionHistory.shared.removeEntry(at: tag)
        }
    }

    @objc func clearHistory(_ sender: NSMenuItem) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Clear History"
            alert.informativeText = "Are you sure you want to clear all session history? This cannot be undone."
            alert.addButton(withTitle: "Clear")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            if alert.runModal() == .alertFirstButtonReturn {
                SessionHistory.shared.clearAll()
            }
        }
    }
}

// MARK: - Menu Search Field View

/// Container view that holds an NSSearchField with padding and ensures it gets focus in a menu.
final class MenuSearchFieldView: NSView {
    let searchField: NSSearchField

    init(width: CGFloat = 300) {
        let hPadding: CGFloat = 16
        let vPadding: CGFloat = 8
        let fieldHeight: CGFloat = 24
        searchField = NSSearchField(frame: NSRect(x: hPadding, y: vPadding, width: width - hPadding * 2, height: fieldHeight))
        searchField.focusRingType = .none
        searchField.sendsSearchStringImmediately = true
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: fieldHeight + vPadding * 2))
        addSubview(searchField)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let field = self?.searchField else { return }
            field.window?.makeFirstResponder(field)
        }
    }
}

// MARK: - History Search Handler

/// Manages the history submenu with a search field that filters entries by keyword/displayName/summary.
@MainActor
final class HistorySearchHandler: NSObject, NSMenuDelegate, NSSearchFieldDelegate {
    private var controller: StatusBarController?
    private var actionTarget: HistoryActionTarget?
    private var allHistory: [HistoryEntry] = []
    private weak var historyMenu: NSMenu?

    func buildHistoryMenu(_ menu: NSMenu, history: [HistoryEntry], controller: StatusBarController, actionTarget: HistoryActionTarget) {
        self.controller = controller
        self.actionTarget = actionTarget
        self.allHistory = history
        self.historyMenu = menu
        menu.removeAllItems()

        // Search field
        let searchView = MenuSearchFieldView(width: 300)
        searchView.searchField.placeholderString = "Search history…"
        searchView.searchField.delegate = self
        searchView.searchField.target = self
        searchView.searchField.action = #selector(searchChanged(_:))
        let searchItem = NSMenuItem()
        searchItem.view = searchView
        menu.addItem(searchItem)
        menu.addItem(.separator())

        addHistoryEntries(to: menu, entries: Array(history.prefix(20)))
    }

    private func addHistoryEntries(to menu: NSMenu, entries: [(Int, HistoryEntry)]) {
        let now = Date().timeIntervalSince1970
        for (origIndex, entry) in entries {
            let dirName = URL(fileURLWithPath: entry.directory).lastPathComponent
            let ago = formatDuration(now - entry.endedAt)
            let label: String
            if let dn = entry.displayName, !dn.isEmpty {
                label = "\(entry.symbol) · \(dn) (\(ago) ago)"
            } else {
                label = "\(entry.symbol) · \(dirName) (\(ago) ago)"
            }
            let hItem = NSMenuItem(title: label, action: nil, keyEquivalent: "")

            let hSub = NSMenu()

            // Header: directory + duration
            let duration = entry.endedAt - entry.startedAt
            let headerItem = NSMenuItem(title: "📁 \(dirName)  ·  ⏱ \(formatDuration(duration))", action: nil, keyEquivalent: "")
            headerItem.isEnabled = false
            hSub.addItem(headerItem)
            hSub.addItem(.separator())

            // Prompt timeline (what you asked, in order)
            let timeline = entry.promptTimeline ?? []
            if !timeline.isEmpty {
                let timelineLabel = NSMenuItem(title: "Conversation:", action: nil, keyEquivalent: "")
                timelineLabel.isEnabled = false
                hSub.addItem(timelineLabel)
                for (i, prompt) in timeline.enumerated() {
                    let text = prompt.count > 55 ? String(prompt.prefix(52)) + "…" : prompt
                    let item = NSMenuItem(title: "  \(i + 1). \(text)", action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    hSub.addItem(item)
                }
            } else {
                // Fallback for old entries: show summary + lastMessage
                let summaryText = entry.summary.count > 60 ? String(entry.summary.prefix(57)) + "…" : entry.summary
                let summaryItem = NSMenuItem(title: "💬 \(summaryText)", action: nil, keyEquivalent: "")
                summaryItem.isEnabled = false
                hSub.addItem(summaryItem)

                if let msg = entry.lastMessage, !msg.isEmpty {
                    let clean = msg
                        .replacingOccurrences(of: #"#{1,6}\s*"#, with: "", options: .regularExpression)
                        .replacingOccurrences(of: #"\*{1,2}([^*]+)\*{1,2}"#, with: "$1", options: .regularExpression)
                        .replacingOccurrences(of: #"`([^`]+)`"#, with: "$1", options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let firstLine = clean.components(separatedBy: .newlines)
                        .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? clean
                    let text = firstLine.count > 60 ? String(firstLine.prefix(57)) + "…" : firstLine
                    let item = NSMenuItem(title: "🤖 \(text)", action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    hSub.addItem(item)
                }
            }

            // Keywords (click to copy)
            let kw = entry.keywords ?? []
            if !kw.isEmpty {
                hSub.addItem(.separator())
                let kwText = kw.prefix(10).joined(separator: ", ")
                let kwLabel = kw.count > 10 ? "\(kwText) +\(kw.count - 10) more" : kwText
                let kwItem = NSMenuItem(title: "🏷 \(kwLabel)", action: #selector(HistoryActionTarget.copyKeywords(_:)), keyEquivalent: "")
                kwItem.target = actionTarget
                kwItem.representedObject = kw
                kwItem.toolTip = kw.joined(separator: ", ")
                hSub.addItem(kwItem)
            }

            hSub.addItem(.separator())

            let resumeInfo = ["directory": entry.directory, "sessionId": entry.sessionId] as [String: Any]
            let resumeItem = NSMenuItem(title: "Resume", action: nil, keyEquivalent: "")
            let resumeSub = NSMenu()

            let normalItem = NSMenuItem(title: "Resume Session", action: #selector(HistoryActionTarget.resumeSession(_:)), keyEquivalent: "")
            normalItem.target = actionTarget
            normalItem.representedObject = resumeInfo
            resumeSub.addItem(normalItem)

            let dangerItem = NSMenuItem(title: "Resume (Skip Perms)", action: #selector(HistoryActionTarget.resumeSessionDangerous(_:)), keyEquivalent: "")
            dangerItem.target = actionTarget
            dangerItem.representedObject = resumeInfo
            resumeSub.addItem(dangerItem)

            resumeSub.addItem(.separator())

            let copyItem = NSMenuItem(title: "Copy Resume Command", action: #selector(HistoryActionTarget.copyResumeCommand(_:)), keyEquivalent: "")
            copyItem.target = actionTarget
            copyItem.representedObject = resumeInfo
            resumeSub.addItem(copyItem)

            resumeItem.submenu = resumeSub
            hSub.addItem(resumeItem)

            let deleteItem = NSMenuItem(title: "Delete", action: #selector(HistoryActionTarget.deleteHistoryEntry(_:)), keyEquivalent: "")
            deleteItem.target = actionTarget
            deleteItem.tag = origIndex
            hSub.addItem(deleteItem)

            hItem.submenu = hSub
            menu.addItem(hItem)
        }

        menu.addItem(.separator())
        let clearItem = NSMenuItem(title: "Clear History", action: #selector(HistoryActionTarget.clearHistory(_:)), keyEquivalent: "")
        clearItem.target = actionTarget
        menu.addItem(clearItem)
    }

    private func addHistoryEntries(to menu: NSMenu, entries: [HistoryEntry]) {
        addHistoryEntries(to: menu, entries: entries.enumerated().map { ($0.offset, $0.element) })
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        guard let menu = historyMenu else { return }
        // Remove all items after the search field + separator
        while menu.items.count > 2 {
            menu.removeItem(at: 2)
        }

        let query = sender.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        if query.isEmpty {
            addHistoryEntries(to: menu, entries: Array(allHistory.prefix(20)))
            return
        }

        // Filter: match against displayName, summary, lastMessage, keywords, directory
        var matched: [(Int, HistoryEntry)] = []
        for (index, entry) in allHistory.enumerated() {
            let haystack = [
                entry.displayName,
                entry.summary,
                entry.lastMessage,
                URL(fileURLWithPath: entry.directory).lastPathComponent,
            ].compactMap { $0?.lowercased() }
            let keywordMatch = entry.keywords?.contains { $0.lowercased().contains(query) } ?? false
            if keywordMatch || haystack.contains(where: { $0.contains(query) }) {
                matched.append((index, entry))
            }
            if matched.count >= 20 { break }
        }

        if matched.isEmpty {
            let noMatch = NSMenuItem(title: "No matches", action: nil, keyEquivalent: "")
            noMatch.isEnabled = false
            menu.addItem(noMatch)
            menu.addItem(.separator())
            let clearItem = NSMenuItem(title: "Clear History", action: #selector(StatusBarController.clearHistory), keyEquivalent: "")
            clearItem.target = controller
            menu.addItem(clearItem)
        } else {
            addHistoryEntries(to: menu, entries: matched)
        }
    }

    nonisolated func menuWillOpen(_ menu: NSMenu) {
        // Keep search field focused when submenu opens
    }
}

// MARK: - Sound Picker Menu (hover to preview)

/// Submenu that plays each sound when hovered and saves on click.
final class SoundPickerMenu: NSMenu, NSMenuDelegate {
    private let onSelect: (String) -> Void
    private let current: String

    init(current: String, onSelect: @escaping (String) -> Void) {
        self.current = current
        self.onSelect = onSelect
        super.init(title: "")
        self.delegate = self

        for sound in Settings.availableSounds {
            let item = NSMenuItem(title: sound, action: #selector(soundChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = sound
            if sound == current { item.state = .on }
            addItem(item)
        }
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    @objc private func soundChosen(_ sender: NSMenuItem) {
        guard let sound = sender.representedObject as? String else { return }
        onSelect(sound)
    }

    // Play sound on hover
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        guard let sound = item?.representedObject as? String else { return }
        NSSound(named: NSSound.Name(sound))?.play()
    }
}

