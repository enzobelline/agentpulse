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
        popover.contentViewController = NSHostingController(
            rootView: PopoverContentView(store: store, dismiss: { [weak self] in
                self?.popover.performClose(nil)
            })
        )

        registerGlobalHotkey()
        startAnimationTimer()
    }

    // MARK: - Popover

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else if let button = statusItem.button {
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

        statusItem.button?.title = allParts.joined(separator: " ")
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
