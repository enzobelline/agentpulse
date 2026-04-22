import AppKit
import SwiftUI
import AgentPulseLib

@MainActor
final class StatusBarController: NSObject, SessionStoreDelegate {
    let store: SessionStore
    private let statusItem: NSStatusItem
    private let worktreeManager = WorktreeManager()
    private var spinnerIdx = 0
    private var popover: NSPopover
    private var globalHotkeyMonitor: Any?
    private var animationTimer: Timer?
    private let transcriptWatcher = TranscriptWatcher()

    init(store: SessionStore) {
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        super.init()

        statusItem.button?.title = Constants.iconSleeping
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover(_:))

        popover.contentSize = NSSize(width: 500, height: 350)
        popover.behavior = .transient
        let actions = SessionActions(store: store)
        popover.contentViewController = NSHostingController(
            rootView: PopoverContentView(store: store, dismiss: { [weak self] in
                self?.popover.performClose(nil)
            }, actions: actions)
        )

        registerGlobalHotkey()
        startAnimationTimer()
        transcriptWatcher.store = store
        transcriptWatcher.sync()
    }

    // MARK: - Popover

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else if let button = statusItem.button {
            // .accessory apps don't auto-activate, and without activation
            // NSPopover's .transient behavior can't detect outside clicks.
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    // MARK: - Global Hotkey

    private func registerGlobalHotkey() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let trusted = AXIsProcessTrustedWithOptions(
            [key: true] as CFDictionary
        )
        if !trusted { return }

        globalHotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let required: NSEvent.ModifierFlags = [.control, .option]
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(required),
                  event.charactersIgnoringModifiers == "a" else { return }
            MainActor.assumeIsolated {
                self?.togglePopover(nil)
            }
        }
    }

    // MARK: - SessionStoreDelegate

    nonisolated func sessionStoreDidUpdate() {
        MainActor.assumeIsolated {
            transcriptWatcher.sync()
            refresh()
        }
    }

    // MARK: - Refresh

    func refresh() {
        updateTitle()
    }

    func checkFirstRun() {
        guard !store.settings.firstRunComplete else { return }
        store.settings.firstRunComplete = true
        store.saveSettings()
    }

    // MARK: - Animation

    private func startAnimationTimer() {
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateTitle()
            }
        }
        RunLoop.current.add(timer, forMode: .common)
        animationTimer = timer
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

        // Prepend today's estimated cost across live and recently-closed sessions.
        // Only shows if we actually have cost data (skips quietly otherwise).
        if let costLabel = dailyCostLabel() {
            allParts.insert(costLabel, at: 0)
        }

        statusItem.button?.title = allParts.joined(separator: " ")
    }

    /// Sum live session cost_usd + today's history final_cost, local-day bucketed.
    /// Returns a `$X.YZ` string, or nil if there's nothing to show.
    private func dailyCostLabel() -> String? {
        var total: Double = 0

        for s in store.sessions.values {
            if let c = s.costUsd { total += c }
        }

        let now = Date()
        let cal = Calendar.current
        let today = cal.startOfDay(for: now).timeIntervalSince1970
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))?.timeIntervalSince1970 ?? (today + 86_400)

        let liveIds = Set(store.sessions.keys)
        for entry in SessionHistory.shared.load() {
            guard let c = entry.finalCost else { continue }
            guard entry.endedAt >= today, entry.endedAt < tomorrow else { continue }
            // Skip history entries whose session is still live — we already
            // counted their live costUsd above.
            if liveIds.contains(entry.sessionId) { continue }
            total += c
        }

        guard total > 0 else { return nil }
        return String(format: "$%.2f", total)
    }

    private func iconFor(_ s: Session) -> String {
        switch s.status {
        case "running": return Constants.spinnerFrames[spinnerIdx]
        case "waiting": return Constants.iconWaiting
        case "done":    return Constants.iconDone
        default:        return Constants.iconSleeping
        }
    }
}
