import SwiftUI
import AgentPulseLib

struct HistoryView: View {
    let actions: SessionActions
    var dismiss: (() -> Void)?
    @State private var searchText = ""
    @State private var entries: [HistoryEntry] = []
    @State private var expandedId: String?
    @State private var confirmingClear = false
    @State private var clearResetTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TextField("Search history...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                Spacer(minLength: 8)
                Text("\(entries.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !entries.isEmpty {
                    Button(confirmingClear ? "Confirm?" : "Clear") {
                        if confirmingClear {
                            clearResetTask?.cancel()
                            SessionHistory.shared.clearAll()
                            withAnimation(.easeOut(duration: 0.18)) {
                                entries = []
                                confirmingClear = false
                            }
                        } else {
                            withAnimation(.easeIn(duration: 0.15)) {
                                confirmingClear = true
                            }
                            clearResetTask?.cancel()
                            clearResetTask = Task {
                                try? await Task.sleep(nanoseconds: 3_000_000_000)
                                if !Task.isCancelled {
                                    await MainActor.run {
                                        withAnimation(.easeOut(duration: 0.2)) {
                                            confirmingClear = false
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .font(.caption.weight(confirmingClear ? .semibold : .regular))
                    .buttonStyle(.plain)
                    .foregroundStyle(confirmingClear ? Color.red : .red.opacity(0.75))
                    .onHover { h in if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() } }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            if filtered.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Text(entries.isEmpty ? "No history yet" : "No matches")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filtered, id: \.sessionId) { entry in
                            HistoryRowView(
                                entry: entry,
                                isExpanded: expandedId == entry.sessionId,
                                actions: actions,
                                dismiss: dismiss,
                                onToggle: {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        expandedId = expandedId == entry.sessionId ? nil : entry.sessionId
                                    }
                                },
                                onDelete: {
                                    SessionHistory.shared.removeEntry(sessionId: entry.sessionId)
                                    entries = SessionHistory.shared.load()
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
        .onAppear { entries = SessionHistory.shared.load() }
    }

    private var filtered: [HistoryEntry] {
        let source = Array(entries.prefix(50))
        guard !searchText.isEmpty else { return source }
        let query = searchText.lowercased()
        return source.filter { entry in
            entry.summary.lowercased().contains(query) ||
            entry.directory.lowercased().contains(query) ||
            (entry.displayName?.lowercased().contains(query) ?? false) ||
            (entry.keywords?.contains(where: { $0.lowercased().contains(query) }) ?? false)
        }
    }
}

struct HistoryRowView: View {
    let entry: HistoryEntry
    let isExpanded: Bool
    let actions: SessionActions
    var dismiss: (() -> Void)?
    let onToggle: () -> Void
    let onDelete: () -> Void
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main row
            HStack(spacing: 6) {
                Text(entry.symbol)
                    .font(.system(size: 13))
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(.system(size: 14))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(dirName)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        if let kw = entry.keywords, !kw.isEmpty {
                            Text(kw.prefix(3).joined(separator: ", "))
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer()

                Text(duration)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(isHovered ? Color.primary.opacity(0.06) : Color.clear)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .onTapGesture(count: 2) {
                dismiss?()
                actions.resumeSession(directory: entry.directory, sessionId: entry.sessionId)
            }
            .onTapGesture { onToggle() }

            // Expanded: metrics strip + prompt timeline
            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    if hasMetrics {
                        HStack(spacing: 6) {
                            ForEach(Array(metricTokens.enumerated()), id: \.offset) { idx, token in
                                if idx > 0 {
                                    Text("·")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.tertiary)
                                }
                                Text(token.text)
                                    .font(.system(size: 12))
                                    .monospacedDigit()
                                    .foregroundStyle(token.color)
                            }
                        }
                    }
                    if let timeline = entry.promptTimeline, !timeline.isEmpty {
                        ForEach(Array(timeline.enumerated()), id: \.offset) { idx, prompt in
                            HStack(alignment: .top, spacing: 6) {
                                Text("\(idx + 1).")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 16, alignment: .trailing)
                                Text(prompt)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    } else {
                        Text(entry.summary)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .contextMenu {
            Button("Resume Session") {
                actions.resumeSession(directory: entry.directory, sessionId: entry.sessionId)
            }
            Button("Resume (Skip Perms)") {
                actions.resumeSessionDangerous(directory: entry.directory, sessionId: entry.sessionId)
            }
            Divider()
            Button("Copy Resume Command") {
                actions.copyResumeCommand(directory: entry.directory, sessionId: entry.sessionId)
            }
            if let kw = entry.keywords, !kw.isEmpty {
                Button("Copy Keywords") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(kw.joined(separator: ", "), forType: .string)
                }
            }
            Divider()
            Button("Delete") { onDelete() }
        }
    }

    private var displayName: String {
        if let dn = entry.displayName, !dn.isEmpty { return dn }
        return entry.summary
    }

    private var dirName: String {
        URL(fileURLWithPath: entry.directory).lastPathComponent
    }

    private var duration: String {
        let secs = entry.endedAt - entry.startedAt
        let mins = Int(secs) / 60
        if mins < 1 { return "<1m" }
        if mins < 60 { return "\(mins)m" }
        let hrs = mins / 60
        return "\(hrs)h\(mins % 60 > 0 ? "\(mins % 60)m" : "")"
    }

    private var hasMetrics: Bool {
        entry.model != nil || entry.finalContextPct != nil
            || entry.finalCost != nil || entry.turnCount != nil
    }

    private var metricTokens: [(text: String, color: Color)] {
        var tokens: [(String, Color)] = []
        if let model = entry.model {
            tokens.append((shortModelName(model), .secondary))
        }
        if let cost = entry.finalCost {
            tokens.append((String(format: "$%.2f", cost), .secondary))
        }
        if let pct = entry.finalContextPct {
            tokens.append(("\(Int(pct.rounded()))% ctx", historyContextColor(for: pct)))
        }
        if let turns = entry.turnCount {
            tokens.append(("\(turns) turns", .secondary))
        }
        return tokens
    }

    private func shortModelName(_ id: String) -> String {
        // "claude-opus-4-7" → "Opus 4.7"
        let parts = id.replacingOccurrences(of: "claude-", with: "").split(separator: "-")
        guard parts.count >= 3 else { return id }
        let family = parts[0].prefix(1).uppercased() + parts[0].dropFirst()
        return "\(family) \(parts[1]).\(parts[2])"
    }

    private func historyContextColor(for pct: Double) -> Color {
        if pct < 40 { return .green }
        if pct < 70 { return .yellow }
        return .red
    }
}
