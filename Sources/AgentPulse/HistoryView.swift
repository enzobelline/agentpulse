import SwiftUI
import AgentPulseLib

struct HistoryView: View {
    let actions: SessionActions
    @State private var searchText = ""
    @State private var entries: [HistoryEntry] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("History")
                    .font(.headline)
                Spacer()
                Text("\(entries.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Clear All") {
                    SessionHistory.shared.clearAll()
                    entries = []
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.red.opacity(0.8))
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Search
            TextField("Search history...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            Divider()

            if filtered.isEmpty {
                VStack {
                    Spacer()
                    Text(entries.isEmpty ? "No history" : "No matches")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(filtered.enumerated()), id: \.offset) { idx, entry in
                            HistoryRowView(entry: entry, index: idx, actions: actions, onDelete: {
                                // Find original index for deletion
                                if let origIdx = entries.firstIndex(where: { $0.sessionId == entry.sessionId }) {
                                    SessionHistory.shared.removeEntry(at: origIdx)
                                    entries = SessionHistory.shared.load()
                                }
                            })
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(width: 420, height: 400)
        .onAppear { entries = SessionHistory.shared.load() }
    }

    private var filtered: [HistoryEntry] {
        guard !searchText.isEmpty else { return Array(entries.prefix(30)) }
        let query = searchText.lowercased()
        return entries.filter { entry in
            entry.summary.lowercased().contains(query) ||
            entry.directory.lowercased().contains(query) ||
            (entry.displayName?.lowercased().contains(query) ?? false) ||
            (entry.keywords?.contains(where: { $0.lowercased().contains(query) }) ?? false)
        }.prefix(30).map { $0 }
    }
}

struct HistoryRowView: View {
    let entry: HistoryEntry
    let index: Int
    let actions: SessionActions
    let onDelete: () -> Void
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(entry.symbol)
                    .font(.system(size: 13))
                    .frame(width: 16)

                Text(displayName)
                    .font(.system(size: 13))
                    .lineLimit(1)

                Spacer()

                Text(duration)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            HStack(spacing: 6) {
                Text(dirName)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let kw = entry.keywords, !kw.isEmpty {
                    Text(kw.prefix(3).joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
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
            Button("Copy Keywords") {
                if let kw = entry.keywords {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(kw.joined(separator: ", "), forType: .string)
                }
            }
            .disabled(entry.keywords?.isEmpty ?? true)
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
}
