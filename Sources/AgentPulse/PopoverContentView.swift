import SwiftUI
import AgentPulseLib

enum PopoverTab: String, CaseIterable {
    case sessions = "Sessions"
    case history = "History"
    case settings = "Settings"
}

struct PopoverContentView: View {
    var store: SessionStore
    @State private var actions: SessionActions?
    @State private var selectedTab: PopoverTab = .sessions
    @State private var spinnerIdx = 0
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
                case .sessions:
                    sessionsContent
                case .history:
                    if let actions {
                        HistoryView(actions: actions)
                    }
                case .settings:
                    SettingsView(store: store)
                }
            }
            .transition(.opacity.animation(.easeInOut(duration: 0.15)))
        }
        .frame(width: 420, height: 440)
        .onReceive(timer) { _ in
            spinnerIdx = (spinnerIdx + 1) % Constants.spinnerFrames.count
        }
        .onAppear {
            if actions == nil {
                actions = SessionActions(store: store)
            }
        }
    }

    // MARK: - Tab Labels

    private func tabLabel(_ tab: PopoverTab) -> String {
        switch tab {
        case .sessions: return "Sessions (\(store.sessions.count))"
        case .history: return "History"
        case .settings: return "Settings"
        }
    }

    // MARK: - Sessions Tab

    private var sessionsContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.sessions.isEmpty {
                VStack {
                    Spacer()
                    Text("No active sessions")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        let sorted = AgentPulseLib.sortedByPriority(
                            store.sessions.map { $0 },
                            pinnedSessions: store.settings.pinnedSessions
                        )
                        ForEach(sorted, id: \.key) { key, session in
                            if let actions {
                                SessionRowView(key: key, session: session, actions: actions, spinnerIdx: spinnerIdx)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Divider()

            // Footer
            HStack {
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.caption)

                Spacer()

                Text("⌃⌥A")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
}

// MARK: - Session Row

struct SessionRowView: View {
    let key: String
    let session: Session
    let actions: SessionActions
    var spinnerIdx: Int = 0

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

            Text(AgentPulseLib.displaySymbol(for: session))
                .font(.system(size: 13))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(summaryText)
                    .font(.system(size: 13))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(directoryName)
                        .font(.caption)
                        .foregroundStyle(.secondary)

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

            if !duration.isEmpty {
                Text(duration)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .opacity(session.status == "done" ? 0.6 : 1.0)
        .onTapGesture {
            actions.goToTerminal(key: key)
        }
        .contextMenu {
            Button("Go to Terminal") {
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

    private var duration: String {
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
