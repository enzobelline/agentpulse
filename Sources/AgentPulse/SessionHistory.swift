import Foundation
import AgentPulseLib

@MainActor
final class SessionHistory {
    static let shared = SessionHistory()
    private let maxEntries = 50

    private var historyFile: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.claude/session-history.json"
    }

    private init() {}

    func addEntry(from session: Session, key: String) {
        let existing = load()
        let entry = HistoryEntry(
            symbol: session.symbol ?? "?",
            directory: session.directory ?? session.name,
            summary: session.summary ?? session.name,
            sessionId: key,
            startedAt: session.startedAt ?? session.updatedAt,
            endedAt: session.updatedAt,
            lastMessage: session.lastMessage
        )
        let updated = applyHistoryEntry(entry, to: existing, maxEntries: maxEntries)
        guard updated.count != existing.count || updated.first?.sessionId != existing.first?.sessionId else { return }
        save(updated)
    }

    func load() -> [HistoryEntry] {
        guard FileManager.default.fileExists(atPath: historyFile) else { return [] }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: historyFile))
            return try JSONDecoder().decode([HistoryEntry].self, from: data)
        } catch {
            return []
        }
    }

    func removeEntry(at index: Int) {
        var entries = load()
        guard index >= 0, index < entries.count else { return }
        entries.remove(at: index)
        save(entries)
    }

    func clearAll() {
        save([])
    }

    private func save(_ entries: [HistoryEntry]) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(entries)
            try data.write(to: URL(fileURLWithPath: historyFile))
        } catch {
            // Ignore
        }
    }
}
