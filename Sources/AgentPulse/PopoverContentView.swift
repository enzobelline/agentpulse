import SwiftUI
import AgentPulseLib

struct PopoverContentView: View {
    var store: SessionStore
    @State private var actions: SessionActions?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("AgentPulse")
                    .font(.headline)
                Spacer()
                Text("\(store.sessions.count) sessions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            if store.sessions.isEmpty {
                VStack {
                    Spacer()
                    Text("No active sessions")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        let sorted = AgentPulseLib.sortedByPriority(
                            store.sessions.map { $0 },
                            pinnedSessions: store.settings.pinnedSessions
                        )
                        ForEach(sorted, id: \.key) { key, session in
                            if let actions {
                                SessionRowView(key: key, session: session, actions: actions)
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
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(width: 420, height: 400)
        .onAppear {
            if actions == nil {
                actions = SessionActions(store: store)
            }
        }
    }
}

// MARK: - Session Row

struct SessionRowView: View {
    let key: String
    let session: Session
    let actions: SessionActions

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Text(statusIcon)
                .font(.system(size: 14, design: .monospaced))
                .frame(width: 20)

            Text(AgentPulseLib.displaySymbol(for: session))
                .font(.system(size: 14))
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
        .onHover { hovering in
            isHovered = hovering
        }
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

        // Computed properties
    }

    private var statusIcon: String {
        switch session.status {
        case "running": return "◐"
        case "waiting": return "⏸"
        case "done":    return "✓"
        default:        return "○"
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
