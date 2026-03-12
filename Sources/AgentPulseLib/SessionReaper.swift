import Foundation

// MARK: - Session Attach

/// The action the app should take when a user clicks a session row.
public enum AttachAction: Equatable {
    /// Found the session's TTY — activate Terminal via Cocoa API for reliable cross-Space switching.
    case activateWindow(tty: String)
    /// No TTY available — open a new Terminal window cd'd to the session's directory.
    case openTerminal(directory: String)
}

/// Determines how to attach to a clicked session.
///
/// Edge cases handled:
/// - Session not found (reaped/expired) → open terminal at fallback directory
/// - Session exists but TTY is nil or empty → open terminal at session directory
/// - Session exists with valid TTY → activate the Terminal window matching that TTY
/// - TTY is a known-bad value from hook failures ("??", "/dev/??") → treated as missing
public func resolveAttachAction(session: Session?, sessionKey: String) -> AttachAction {
    let dir = session?.directory ?? sessionKey

    guard let tty = session?.tty?.trimmingCharacters(in: .whitespaces),
          isValidTTY(tty) else {
        return .openTerminal(directory: dir)
    }

    return .activateWindow(tty: tty)
}

/// Checks whether a TTY path looks valid for Terminal.app matching.
///
/// Valid: "/dev/ttys003", "/dev/ttys042"
/// Invalid: nil, "", "??", "/dev/??", "not a tty", paths missing /dev/ prefix,
///          bare device names without /dev/ prefix ("ttys003")
public func isValidTTY(_ tty: String) -> Bool {
    let trimmed = tty.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return false }
    guard trimmed.hasPrefix("/dev/ttys") else { return false }
    guard trimmed.count > "/dev/ttys".count else { return false }
    // The suffix after /dev/ttys should be all digits
    let suffix = trimmed.dropFirst("/dev/ttys".count)
    return suffix.allSatisfy(\.isNumber)
}

// MARK: - Status Transition Detection

/// Determines which sessions changed status between two snapshots.
/// Returns (key, oldStatus, newStatus) for each transition.
/// This is the core logic that drives notification firing and UI updates.
public func detectStatusTransitions(
    old: [String: Session],
    new: [String: Session]
) -> [(key: String, oldStatus: String?, newStatus: String)] {
    var transitions: [(key: String, oldStatus: String?, newStatus: String)] = []
    for (key, newSession) in new {
        let oldStatus = old[key]?.status
        if oldStatus != newSession.status {
            transitions.append((key: key, oldStatus: oldStatus, newStatus: newSession.status))
        }
    }
    return transitions
}

/// Simulates the mtime-based change detection used by SessionStore.
/// Returns true if the file would be re-read (mtime changed).
///
/// This models the core polling logic: the app stores the last-seen mtime
/// and only reloads when it differs. Two rapid writes with the same
/// filesystem timestamp will cause the second write to be missed until
/// the next timer tick.
public func wouldDetectChange(lastSeenMtime: TimeInterval, currentMtime: TimeInterval) -> Bool {
    return currentMtime != lastSeenMtime
}

// MARK: - TTL Expiry

/// Returns keys of "done" sessions whose updatedAt is older than the TTL.
/// Pure function — no side effects, caller handles removal.
public func expiredSessionKeys(_ sessions: [String: Session], ttlMinutes: Int, now: TimeInterval) -> [String] {
    guard ttlMinutes > 0 else { return [] }
    let ttlSeconds = TimeInterval(ttlMinutes * 60)
    return sessions.compactMap { (key, session) -> String? in
        guard session.status == "done" else { return nil }
        guard now - session.updatedAt >= ttlSeconds else { return nil }
        return key
    }
}

/// Check if sessions with stored PIDs are still alive.
/// - Running/waiting sessions with dead PIDs are marked as done.
/// - Done sessions with dead PIDs are removed entirely.
/// The caller is responsible for persisting any changes.
public func reapStaleSessions(_ sessions: [String: Session]) -> [String: Session] {
    var result = sessions
    for (key, session) in sessions {
        guard let pid = session.pid else { continue }
        let alive = kill(Int32(pid), 0) == 0
        if !alive {
            if session.status == "done" {
                result.removeValue(forKey: key)
            } else if session.status == "running" || session.status == "waiting" {
                result[key]?.status = "done"
                // Preserve the real summary for history recording.
                // Only fall back to "Process ended" if there's no meaningful summary.
                if let existing = session.summary, !existing.isEmpty, !placeholderSummaries.contains(existing) {
                    // Keep the existing summary
                } else {
                    result[key]?.summary = "Process ended"
                }
                result[key]?.updatedAt = Date().timeIntervalSince1970
            }
        }
    }
    return result
}
