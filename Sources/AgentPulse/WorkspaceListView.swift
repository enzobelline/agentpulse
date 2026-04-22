import SwiftUI
import AgentPulseLib

struct WorkspaceSessionMetrics {
    var contextPct: Double?
    var turnCount: Int?
    var durationSec: Double?
    var hasAny: Bool { contextPct != nil || turnCount != nil || durationSec != nil }
}

struct WorkspaceListView: View {
    var store: SessionStore
    let actions: SessionActions
    var dismiss: (() -> Void)?
    @State private var workspaces: [WorkspaceSnapshot] = []
    @State private var searchText = ""
    @State private var expandedId: String?
    @State private var expandedSessionId: String?
    @State private var editingWorkspaceId: String?
    @State private var historyCache: [String: HistoryEntry] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                TextField("Search workspaces...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                Spacer(minLength: 8)
                Text("\(workspaces.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !workspaces.isEmpty {
                    Button("Clear All") {
                        let alert = NSAlert()
                        alert.messageText = "Delete All Workspaces?"
                        alert.informativeText = "This will remove all saved workspaces. This cannot be undone."
                        alert.addButton(withTitle: "Delete All")
                        alert.addButton(withTitle: "Cancel")
                        alert.alertStyle = .warning
                        if alert.runModal() == .alertFirstButtonReturn {
                            for ws in workspaces {
                                WorkspaceManager.shared.delete(id: ws.id)
                            }
                            workspaces = []
                        }
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.red.opacity(0.8))
                    .onHover { h in if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() } }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            if filtered.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    if workspaces.isEmpty {
                        Image(systemName: "square.stack.3d.up")
                            .font(.system(size: 28))
                            .foregroundStyle(.quaternary)
                        Text("No saved workspaces")
                            .foregroundStyle(.secondary)
                        VStack(spacing: 4) {
                            Text("Save your active sessions as a workspace")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Text("Click \"Save\" in the Current tab to get started")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    } else {
                        Text("No matches")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filtered) { workspace in
                            WorkspaceRowView(
                                workspace: workspace,
                                isExpanded: expandedId == workspace.id,
                                actions: actions,
                                dismiss: dismiss,
                                metricsFor: { resolveMetrics(sessionId: $0) },
                                isEditing: editingWorkspaceId == workspace.id,
                                onStartEdit: { editingWorkspaceId = workspace.id },
                                onCommitEdit: { newName in
                                    let trimmed = newName.trimmingCharacters(in: .whitespaces)
                                    if !trimmed.isEmpty {
                                        WorkspaceManager.shared.rename(id: workspace.id, newName: trimmed)
                                        workspaces = WorkspaceManager.shared.loadAll()
                                    }
                                    editingWorkspaceId = nil
                                },
                                onCancelEdit: { editingWorkspaceId = nil },
                                onToggle: {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        expandedId = expandedId == workspace.id ? nil : workspace.id
                                    }
                                },
                                onDelete: {
                                    WorkspaceManager.shared.delete(id: workspace.id)
                                    workspaces = WorkspaceManager.shared.loadAll()
                                }
                            )
                            Divider().padding(.horizontal, 16).opacity(0.5)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            workspaces = WorkspaceManager.shared.loadAll()
            var cache: [String: HistoryEntry] = [:]
            for entry in SessionHistory.shared.load() {
                cache[entry.sessionId] = entry
            }
            historyCache = cache
        }
    }

    /// Pull whatever metrics we can for a session — live first, history fallback.
    private func resolveMetrics(sessionId: String) -> WorkspaceSessionMetrics {
        if let live = store.sessions[sessionId] {
            let duration: Double? = live.startedAt.map { Date().timeIntervalSince1970 - $0 }
            // No turn count for live sessions — not persisted on Session yet.
            return WorkspaceSessionMetrics(contextPct: live.contextPct, turnCount: nil, durationSec: duration)
        }
        if let past = historyCache[sessionId] {
            return WorkspaceSessionMetrics(
                contextPct: past.finalContextPct,
                turnCount: past.turnCount,
                durationSec: past.endedAt - past.startedAt
            )
        }
        return WorkspaceSessionMetrics(contextPct: nil, turnCount: nil, durationSec: nil)
    }

    private var filtered: [WorkspaceSnapshot] {
        guard !searchText.isEmpty else { return workspaces }
        let query = searchText.lowercased()
        return workspaces.filter { ws in
            ws.name.lowercased().contains(query) ||
            ws.sessions.contains(where: {
                $0.directory.lowercased().contains(query) ||
                ($0.displayName?.lowercased().contains(query) ?? false)
            })
        }
    }
}

// MARK: - Workspace Row

struct WorkspaceRowView: View {
    let workspace: WorkspaceSnapshot
    let isExpanded: Bool
    let actions: SessionActions
    var dismiss: (() -> Void)?
    let metricsFor: (String) -> WorkspaceSessionMetrics
    let isEditing: Bool
    let onStartEdit: () -> Void
    let onCommitEdit: (String) -> Void
    let onCancelEdit: () -> Void
    let onToggle: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false
    @State private var expandedSessionId: String?
    @State private var editBuffer: String = ""
    @FocusState private var editFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main row
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    if isEditing {
                        TextField("", text: $editBuffer)
                            .font(.system(size: 13, weight: .medium))
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .focused($editFieldFocused)
                            .onAppear {
                                editBuffer = workspace.name
                                editFieldFocused = true
                            }
                            .onSubmit { onCommitEdit(editBuffer) }
                            .onChange(of: editFieldFocused) { _, focused in
                                if !focused && isEditing { onCommitEdit(editBuffer) }
                            }
                            .onExitCommand { onCancelEdit() }
                    } else {
                        Text(workspace.name)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                    }

                    HStack(spacing: 6) {
                        Text("\(workspace.sessions.count) sessions")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.quaternary)
                        Text(WorkspaceManager.relativeTime(workspace.createdAt))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(isHovered ? Color.primary.opacity(0.06) : Color.clear)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .onTapGesture { onToggle() }

            // Expanded: session details
            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(workspace.sessions, id: \.sessionId) { session in
                        WorkspaceSessionRow(
                            session: session,
                            isExpanded: expandedSessionId == session.sessionId,
                            actions: actions,
                            dismiss: dismiss,
                            metrics: metricsFor(session.sessionId),
                            onToggle: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    expandedSessionId = expandedSessionId == session.sessionId ? nil : session.sessionId
                                }
                            }
                        )
                    }

                    // Restore button
                    HStack {
                        Spacer()
                        Button("Restore All") {
                            dismiss?()
                            WorkspaceManager.shared.restore(workspace, using: actions)
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .contextMenu {
            Button("Restore All Sessions") {
                dismiss?()
                WorkspaceManager.shared.restore(workspace, using: actions)
            }
            Divider()
            Button("Rename") {
                onStartEdit()
            }
            Divider()
            Button("Delete") { onDelete() }
        }
    }

    private func dirName(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

// MARK: - Workspace Session Row

struct WorkspaceSessionRow: View {
    let session: WorkspaceSession
    let isExpanded: Bool
    let actions: SessionActions
    var dismiss: (() -> Void)?
    let metrics: WorkspaceSessionMetrics
    let onToggle: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: 6, height: 6)

                VStack(alignment: .leading, spacing: 1) {
                    Text(session.displayName ?? dirName)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(dirName)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                        if metrics.hasAny {
                            ForEach(Array(metricTokens.enumerated()), id: \.offset) { idx, token in
                                Text("·")
                                    .font(.caption2)
                                    .foregroundStyle(.quaternary)
                                Text(token.text)
                                    .font(.caption2)
                                    .foregroundStyle(token.color)
                                    .monospacedDigit()
                            }
                        }
                    }
                }

                Spacer()

                if session.promptTimeline != nil {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8))
                        .foregroundStyle(.quaternary)
                }

                Text(String(session.sessionId.prefix(4)))
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
                    .monospacedDigit()
            }
            .padding(.vertical, 3)
            .background(isHovered ? Color.primary.opacity(0.06) : Color.clear)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            }
            .onTapGesture { onToggle() }
            .contextMenu {
                Button("Resume Session") {
                    dismiss?()
                    actions.resumeSession(directory: session.directory, sessionId: session.sessionId)
                }
                Button("Resume (Skip Perms)") {
                    dismiss?()
                    actions.resumeSessionDangerous(directory: session.directory, sessionId: session.sessionId)
                }
                Divider()
                Button("Copy Resume Command") {
                    actions.copyResumeCommand(directory: session.directory, sessionId: session.sessionId)
                }
            }

            // Prompt timeline
            if isExpanded, let prompts = session.promptTimeline, !prompts.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(prompts.enumerated()), id: \.offset) { idx, prompt in
                        HStack(alignment: .top, spacing: 4) {
                            Text("\(idx + 1).")
                                .font(.caption2)
                                .foregroundStyle(.quaternary)
                                .frame(width: 14, alignment: .trailing)
                            Text(prompt)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                        }
                    }
                }
                .padding(.leading, 14)
                .padding(.top, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 2)
    }

    private var dirName: String {
        URL(fileURLWithPath: session.directory).lastPathComponent
    }

    private func contextColor(for pct: Double) -> Color {
        if pct < 40 { return .green }
        if pct < 70 { return .yellow }
        return .red
    }

    private var metricTokens: [(text: String, color: Color)] {
        var tokens: [(String, Color)] = []
        if let pct = metrics.contextPct {
            tokens.append(("\(Int(pct.rounded()))%", contextColor(for: pct)))
        }
        if let turns = metrics.turnCount {
            tokens.append(("\(turns) turns", Color.secondary))
        }
        if let secs = metrics.durationSec {
            tokens.append((formatDurationShort(secs), Color.secondary))
        }
        return tokens
    }

    private func formatDurationShort(_ secs: Double) -> String {
        let mins = Int(secs) / 60
        if mins < 1 { return "<1m" }
        if mins < 60 { return "\(mins)m" }
        let hrs = mins / 60
        let rem = mins % 60
        return rem > 0 ? "\(hrs)h\(rem)m" : "\(hrs)h"
    }
}

