import Foundation

/// Decides whether a session should be recorded to history.
///
/// Checks (in order):
/// 1. Summary must be non-nil and not a placeholder
/// 2. PID must not be alive (alive = `/clear`, not a real exit)
/// 3. Session ID must not already be in history (dedup)
public func shouldRecordToHistory(
    session: Session,
    sessionId: String,
    existingIds: Set<String>,
    pidAlive: Bool
) -> Bool {
    guard let summary = session.summary else { return false }
    guard !placeholderSummaries.contains(summary) else { return false }
    guard !pidAlive else { return false }
    guard !existingIds.contains(sessionId) else { return false }
    return true
}

/// Pure array operation: prepend a history entry with dedup and max-entries cap.
///
/// Returns the original array unchanged if the entry's sessionId already exists.
public func applyHistoryEntry(
    _ entry: HistoryEntry,
    to entries: [HistoryEntry],
    maxEntries: Int = 50
) -> [HistoryEntry] {
    guard !entries.contains(where: { $0.sessionId == entry.sessionId }) else { return entries }
    var result = [entry] + entries
    if result.count > maxEntries {
        result = Array(result.prefix(maxEntries))
    }
    return result
}
