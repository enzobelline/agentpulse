import Foundation

/// Three-tier priority: pinned first, then attention-needing unpinned, then running unpinned.
public func sessionSortKey(key: String, session s: Session, pinnedSessions: [String]) -> (Int, TimeInterval) {
    let isPinned = pinnedSessions.contains(key)
    let needsAttention = s.status == "waiting" || s.status == "done"
    let tier: Int
    if isPinned {
        tier = 0
    } else if needsAttention {
        tier = 1
    } else {
        tier = 2
    }
    let t = needsAttention ? s.updatedAt : (s.startedAt ?? s.updatedAt)
    return (tier, t)
}

/// Sort session pairs by priority: pinned, then needs-attention, then running.
public func sortedByPriority(_ pairs: [(key: String, value: Session)], pinnedSessions: [String]) -> [(key: String, value: Session)] {
    pairs.sorted {
        sessionSortKey(key: $0.key, session: $0.value, pinnedSessions: pinnedSessions) <
        sessionSortKey(key: $1.key, session: $1.value, pinnedSessions: pinnedSessions)
    }
}
