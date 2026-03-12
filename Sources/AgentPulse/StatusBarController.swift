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
    private var menuNeedsRebuild = true
    /// Fast timer for spinner animation while the menu is open
    private var animationTimer: Timer?
    /// Whether the dropdown menu is currently open (tracking events)
    private var menuIsOpen = false

    init(store: SessionStore) {
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        statusItem.button?.title = Constants.iconSleeping
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
            allParts.append("…(\(overflow))")
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
        let sum = AgentPulseLib.displaySummary(for: session)
        let lastUpdate = session.updatedAt > 0
            ? formatDuration(now - session.updatedAt) : ""

        var label = "\(pinPrefix)\(icon) \(sym) · \(sum) - \(session.status)"
        if !lastUpdate.isEmpty {
            label += " (\(lastUpdate) ago)"
        }
        // Show activity inline if running
        if session.status == "running", let activity = AgentPulseLib.displayActivity(for: session) {
            label += " — \(activity)"
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
                    let sessionItem = NSMenuItem(title: label, action: #selector(attachToSession(_:)), keyEquivalent: "")
                    sessionItem.target = self
                    sessionItem.representedObject = key
                    sessionItem.image = nil
                    if needsGroupHeaders {
                        sessionItem.indentationLevel = 1
                    }
                    let submenu = NSMenu()

                    // Create New Worktree
                    let worktreeItem = NSMenuItem(title: "Create New Worktree", action: #selector(branchSession(_:)), keyEquivalent: "")
                    worktreeItem.target = self
                    worktreeItem.representedObject = session.directory ?? session.name
                    submenu.addItem(worktreeItem)

                    // Open in Terminal
                    let openItem = NSMenuItem(title: "Open in Terminal", action: #selector(openTerminal(_:)), keyEquivalent: "")
                    openItem.target = self
                    openItem.representedObject = session.directory ?? session.name
                    submenu.addItem(openItem)

                    // Session ID (click to copy)
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

                    let pinLabel = isPinned ? "▸ Unpin" : "▹ Pin"
                    let pinItem = NSMenuItem(title: pinLabel, action: #selector(togglePin(_:)), keyEquivalent: "")
                    pinItem.target = self
                    pinItem.representedObject = key
                    submenu.addItem(pinItem)

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
        if doneCount > 0 {
            let clearDone = NSMenuItem(
                title: "Clear Done Sessions (\(doneCount))",
                action: #selector(clearDoneSessions),
                keyEquivalent: ""
            )
            clearDone.target = self
            menu.addItem(clearDone)
        }

        // Clear all sessions
        if !store.sessions.isEmpty {
            let clearAll = NSMenuItem(
                title: "Clear All Sessions",
                action: #selector(clearAllSessions),
                keyEquivalent: ""
            )
            clearAll.target = self
            menu.addItem(clearAll)
        }

        // Notifications toggle
        let notifLabel = "Notifications: \(store.settings.notificationsEnabled ? "On" : "Off")"
        let notifItem = NSMenuItem(title: notifLabel, action: #selector(toggleNotifications), keyEquivalent: "")
        notifItem.target = self
        menu.addItem(notifItem)

        // Sound: On/Off ▸ Waiting: Purr ▸ [sounds...], Done: Glass ▸ [sounds...]
        let soundOn = store.settings.soundEnabled
        let soundLabel = "Sound: \(soundOn ? "On" : "Off")"
        let soundItem = NSMenuItem(title: soundLabel, action: nil, keyEquivalent: "")
        let soundSubmenu = NSMenu()

        let toggleItem = NSMenuItem(title: soundOn ? "Turn Off" : "Turn On", action: #selector(toggleSound), keyEquivalent: "")
        toggleItem.target = self
        soundSubmenu.addItem(toggleItem)
        soundSubmenu.addItem(.separator())

        let waitingItem = NSMenuItem(title: "Waiting: \(store.settings.waitingSound)", action: nil, keyEquivalent: "")
        waitingItem.submenu = SoundPickerMenu(current: store.settings.waitingSound) { [weak self] sound in
            self?.store.settings.waitingSound = sound
            self?.store.saveSettings()
            self?.menuNeedsRebuild = true
            self?.refresh()
        }
        soundSubmenu.addItem(waitingItem)

        let doneItem = NSMenuItem(title: "Done: \(store.settings.doneSound)", action: nil, keyEquivalent: "")
        doneItem.submenu = SoundPickerMenu(current: store.settings.doneSound) { [weak self] sound in
            self?.store.settings.doneSound = sound
            self?.store.saveSettings()
            self?.menuNeedsRebuild = true
            self?.refresh()
        }
        soundSubmenu.addItem(doneItem)

        soundItem.submenu = soundSubmenu
        menu.addItem(soundItem)

        // Auto-clear TTL
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
        menu.addItem(ttlItem)

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
            let now = Date().timeIntervalSince1970
            for (index, entry) in history.prefix(20).enumerated() {
                let dirName = URL(fileURLWithPath: entry.directory).lastPathComponent
                let ago = formatDuration(now - entry.endedAt)
                // Use lastMessage if available, otherwise fall back to prompt summary
                let displaySummary: String
                if let msg = entry.lastMessage, !msg.isEmpty {
                    displaySummary = msg.count > 50
                        ? String(msg.prefix(47)) + "…" : msg
                } else {
                    displaySummary = entry.summary.count > 50
                        ? String(entry.summary.prefix(47)) + "…" : entry.summary
                }
                let title = "\(entry.symbol) · \(dirName) (\(ago) ago)"
                let hItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                hItem.toolTip = displaySummary

                // Submenu with Resume and Delete
                let hSub = NSMenu()
                let info: [String: Any] = [
                    "directory": entry.directory,
                    "sessionId": entry.sessionId,
                ]
                let resumeItem = NSMenuItem(title: "Resume", action: #selector(resumeSession(_:)), keyEquivalent: "")
                resumeItem.target = self
                resumeItem.representedObject = info
                hSub.addItem(resumeItem)

                let deleteItem = NSMenuItem(title: "Delete", action: #selector(deleteHistoryEntry(_:)), keyEquivalent: "")
                deleteItem.target = self
                deleteItem.tag = index
                hSub.addItem(deleteItem)

                hItem.submenu = hSub
                historySubmenu.addItem(hItem)
            }

            historySubmenu.addItem(.separator())
            let clearItem = NSMenuItem(title: "Clear History", action: #selector(clearHistory), keyEquivalent: "")
            clearItem.target = self
            historySubmenu.addItem(clearItem)

            historyItem.submenu = historySubmenu
            menu.addItem(historyItem)
        }

        menu.addItem(.separator())

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
            // Step 1: Find the Terminal tab with matching TTY, select it, and make its window frontmost.
            // We do NOT call `activate` from AppleScript — it's less reliable for cross-Space switching.
            let findScript = """
                tell application "Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is "\(tty)" then
                                set selected tab of w to t
                                set index of w to 1
                                return true
                            end if
                        end repeat
                    end repeat
                    return false
                end tell
                """
            var found = false
            if let appleScript = NSAppleScript(source: findScript) {
                var error: NSDictionary?
                let result = appleScript.executeAndReturnError(&error)
                found = result.booleanValue
            }

            if found {
                // Step 2: Activate Terminal via Cocoa API — more reliable for switching Spaces.
                // NSRunningApplication.activate() goes through the window server's native activation
                // path, which respects the "switch to Space with open windows" Mission Control setting
                // more consistently than AppleScript's `activate` command.
                if let terminal = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").first {
                    terminal.activate()
                }
            } else {
                // TTY not found in any Terminal window — tab was closed, fall back
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
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }

    @objc private func branchSession(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        worktreeManager.branchFromSession(directory: path)
    }

    @objc private func resumeSession(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let dir = info["directory"] as? String,
              let sessionId = info["sessionId"] as? String else { return }
        let escaped = dir.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
            tell application "Terminal"
                activate
                do script "cd \\"\(escaped)\\" && claude --resume \(sessionId)"
            end tell
            """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }

    @objc private func deleteHistoryEntry(_ sender: NSMenuItem) {
        SessionHistory.shared.removeEntry(at: sender.tag)
        menuNeedsRebuild = true
        refresh()
    }

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear History"
        alert.informativeText = "Are you sure you want to clear all session history? This cannot be undone."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            SessionHistory.shared.clearAll()
            menuNeedsRebuild = true
            refresh()
        }
    }

    @objc private func openTerminal(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
            tell application "Terminal"
                activate
                do script "cd \\"\(escaped)\\""
            end tell
            """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    /// Short session ID (first 4 chars of UUID) for display
    private func shortSessionId(_ key: String) -> String {
        let prefix = String(key.prefix(4))
        return "Copy ID · \(prefix)"
    }

    /// Abbreviated path: "/…" + last component truncated to 9 chars
    private func abbreviatedPath(_ path: String) -> String {
        let last = URL(fileURLWithPath: path).lastPathComponent
        let truncated = last.count > 9 ? String(last.prefix(9)) : last
        return "/…\(truncated)"
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

