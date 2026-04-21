import SwiftUI
import AgentPulseLib

enum PopoverTab: String, CaseIterable {
    case active = "Active"
    case workspaces = "Workspaces"
    case history = "History"
    case settings = "Settings"
}

struct PopoverContentView: View {
    var store: SessionStore
    var dismiss: (() -> Void)?
    var actions: SessionActions
    @State private var selectedTab: PopoverTab = .active
    @State private var spinnerIdx = 0
    @State private var tick = 0  // drives live timestamp updates
    @State private var showSavedConfirmation = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 0) {
                ForEach(PopoverTab.allCases, id: \.self) { tab in
                    Button {
                        withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.8)) {
                            selectedTab = tab
                        }
                    } label: {
                        Text(tabLabel(tab))
                            .font(.system(size: 12, weight: selectedTab == tab ? .semibold : .regular))
                            .foregroundStyle(selectedTab == tab ? .primary : .secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(selectedTab == tab ? Color.primary.opacity(0.08) : Color.clear)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 2)

            Divider()

            // Content
            Group {
                switch selectedTab {
                case .active:
                    sessionsContent
                case .workspaces:
                    WorkspaceListView(actions: actions, dismiss: dismiss)
                case .history:
                    HistoryView(actions: actions, dismiss: dismiss)
                case .settings:
                    SettingsView(store: store)
                }
            }
            .transition(.opacity.animation(.easeInOut(duration: 0.15)))
        }
        .frame(width: 500, height: 350)
        .onReceive(timer) { _ in
            spinnerIdx = (spinnerIdx + 1) % Constants.spinnerFrames.count
            tick += 1
        }
    }

    // MARK: - Tab Labels

    private func tabLabel(_ tab: PopoverTab) -> String {
        switch tab {
        case .active: return "Current (\(store.sessions.count))"
        case .workspaces: return "Workspaces"
        case .history: return "History"
        case .settings: return "Settings"
        }
    }

    // MARK: - Sessions Tab

    private var sessionsContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.sessions.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Text("○")
                        .font(.system(size: 32))
                        .foregroundStyle(.quaternary)
                    Text("No active sessions")
                        .foregroundStyle(.secondary)
                    Text("Start a Claude Code session to see it here")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let grouped = groupedSessions
                        ForEach(Array(grouped.enumerated()), id: \.offset) { groupIdx, group in
                            // Group header
                            if grouped.count > 1 {
                                if groupIdx > 0 {
                                    Divider().padding(.horizontal, 16).padding(.vertical, 4)
                                }
                                Text(URL(fileURLWithPath: group.directory).lastPathComponent)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 16)
                                    .padding(.top, groupIdx == 0 ? 6 : 2)
                                    .padding(.bottom, 2)
                            }

                            ForEach(group.items, id: \.key) { key, session in
                                SessionRowView(
                                    key: key,
                                    session: session,
                                    actions: actions,
                                    spinnerIdx: spinnerIdx,
                                    isPinned: store.settings.pinnedSessions.contains(key),
                                    tick: tick,
                                    dismiss: dismiss
                                )
                                Divider().padding(.horizontal, 16).opacity(0.5)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Divider()

            // Footer
            Divider()

            HStack(spacing: 6) {
                Button("Quit") {
                    confirmQuit()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.caption)
                .onHover { h in if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() } }

                if !store.sessions.isEmpty {
                    if showSavedConfirmation {
                        Text("Saved!")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .transition(.opacity)
                    } else {
                        Button("Save") {
                            WorkspaceManager.shared.save(sessions: store.sessions)
                            withAnimation { showSavedConfirmation = true }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                withAnimation { showSavedConfirmation = false }
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.blue)
                        .font(.caption)
                        .onHover { h in if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() } }
                        .transition(.opacity)
                    }

                    let doneCount = store.sessions.values.filter { $0.status == "done" }.count
                    if doneCount > 0 {
                        Button("Clear Done (\(doneCount))") {
                            let keys = store.sessions.filter { $0.value.status == "done" }.map(\.key)
                            store.removeSessions(keys)
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .onHover { h in if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() } }
                    }
                }

                Spacer()

                let counts = statusCounts
                if counts.running > 0 {
                    Text("\(counts.running) running")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
                if counts.waiting > 0 {
                    Text("· \(counts.waiting) waiting")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if counts.done > 0 {
                    Text("· \(counts.done) done")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }

    // MARK: - Grouping

    private var groupedSessions: [(directory: String, items: [(key: String, session: Session)])] {
        let sorted = AgentPulseLib.sortedByPriority(
            store.sessions.map { $0 },
            pinnedSessions: store.settings.pinnedSessions
        )
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
        return groups
    }

    private func confirmClearAll() {
        let alert = NSAlert()
        alert.messageText = "Clear All Sessions?"
        alert.informativeText = "This will remove all sessions from the list. They can still be resumed from History."
        alert.addButton(withTitle: "Clear All")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            store.removeSessions(Array(store.sessions.keys))
        }
    }

    private func confirmQuit() {
        let alert = NSAlert()
        alert.messageText = "Quit AgentPulse?"
        alert.informativeText = "AgentPulse will stop monitoring your sessions."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            NSApplication.shared.terminate(nil)
        }
    }

    private var statusCounts: (running: Int, waiting: Int, done: Int) {
        var r = 0, w = 0, d = 0
        for s in store.sessions.values {
            switch s.status {
            case "running": r += 1
            case "waiting": w += 1
            case "done": d += 1
            default: break
            }
        }
        return (r, w, d)
    }
}

// MARK: - Session Row

struct SessionRowView: View {
    let key: String
    let session: Session
    let actions: SessionActions
    var spinnerIdx: Int = 0
    var isPinned: Bool = false
    var tick: Int = 0  // triggers duration recalculation
    var dismiss: (() -> Void)?

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            // Status indicator dot
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Text(statusIcon)
                .font(.system(size: 13, design: .monospaced))
                .frame(width: 18)

            // Symbol + worktree lineage
            Text(symbolDisplay)
                .font(.system(size: 13))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                    }
                    Text(summaryText)
                        .font(.system(size: 13))
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    if !hasLineage {
                        Text(directoryName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let activity = AgentPulseLib.displayActivity(for: session),
                       session.status == "running" {
                        Text("— \(activity)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            if let pct = session.contextPct {
                Text("\(Int(pct.rounded()))%")
                    .font(.caption)
                    .foregroundStyle(contextColor(for: pct))
                    .monospacedDigit()
            }

            if !liveDuration.isEmpty {
                Text(liveDuration)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .opacity(session.status == "done" ? 0.6 : 1.0)
        .onTapGesture {
            dismiss?()
            actions.goToTerminal(key: key)
        }
        .contextMenu {
            Button("Go to Terminal") {
                dismiss?()
                actions.goToTerminal(key: key)
            }

            Divider()

            Button(actions.isPinned(key: key) ? "Unpin" : "Pin") {
                actions.togglePin(key: key)
            }

            Button("Rename") {
                actions.renameSession(key: key)
            }

            Divider()

            Button("Open New Session") {
                actions.openNewSession(directory: session.directory ?? session.name)
            }

            Button("Create New Worktree") {
                actions.createWorktree(directory: session.directory ?? session.name)
            }

            Divider()

            Button("Copy Session ID") {
                actions.copySessionId(key: key)
            }

            Button("Copy Path") {
                actions.copyPath(key: key)
            }

            Divider()

            Button("Dismiss") {
                actions.dismissSession(key: key)
            }
        }
    }

    private var statusIcon: String {
        switch session.status {
        case "running": return Constants.spinnerFrames[spinnerIdx % Constants.spinnerFrames.count]
        case "waiting": return Constants.iconWaiting
        case "done":    return Constants.iconDone
        default:        return Constants.iconSleeping
        }
    }

    private var statusColor: Color {
        switch session.status {
        case "running": return .green
        case "waiting": return .orange
        case "done":    return .gray
        default:        return .gray.opacity(0.5)
        }
    }

    // Worktree lineage: "◆ falcon → myrepo" or just "◆"
    private var symbolDisplay: String {
        let dirName = URL(fileURLWithPath: session.directory ?? session.name).lastPathComponent
        let symbol = AgentPulseLib.displaySymbol(for: session)
        if let lineage = AgentPulseLib.worktreeLineage(directoryName: dirName) {
            return "\(symbol) \(lineage.word) → \(lineage.repo)"
        }
        return symbol
    }

    private var hasLineage: Bool {
        let dirName = URL(fileURLWithPath: session.directory ?? session.name).lastPathComponent
        return AgentPulseLib.worktreeLineage(directoryName: dirName) != nil
    }

    private var summaryText: String {
        if let name = session.displayName, !name.isEmpty {
            let summary = AgentPulseLib.displaySummary(for: session)
            return summary.isEmpty ? name : "\(name) | \(summary)"
        }
        return AgentPulseLib.displaySummary(for: session)
    }

    private var directoryName: String {
        URL(fileURLWithPath: session.directory ?? session.name).lastPathComponent
    }

    private func contextColor(for pct: Double) -> Color {
        if pct < 40 { return .green }
        if pct < 70 { return .yellow }
        return .red
    }

    // Live-updating duration — `tick` dependency forces recalculation every second
    private var liveDuration: String {
        _ = tick
        let now = Date().timeIntervalSince1970
        guard session.updatedAt > 0 else { return "" }
        let seconds = now - session.updatedAt
        let minutes = Int(seconds) / 60
        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h\(minutes % 60 > 0 ? "\(minutes % 60)m" : "")" }
        return "\(hours / 24)d"
    }
}
