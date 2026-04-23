import Foundation

/// Returns the assigned symbol for a session, or "?" if none.
public func displaySymbol(for session: Session) -> String {
    session.symbol ?? "?"
}

/// Returns a short activity label (e.g. "Editing Models.swift…") or nil.
public func displayActivity(for session: Session) -> String? {
    guard let activity = session.activity, !activity.isEmpty else { return nil }
    if activity.count <= 40 { return activity }
    return String(activity.prefix(37)) + "…"
}

/// Human-readable label for auto-clear TTL in minutes (e.g. 60 → "1h", 1440 → "1d").
public func autoClearLabel(_ minutes: Int) -> String {
    switch minutes {
    case 0: return "Off"
    case let m where m >= 1440: return "\(m / 1440)d"
    case let m where m >= 60: return "\(m / 60)h"
    default: return "\(minutes)m"
    }
}

/// Generic placeholder summaries that should fall back to directory basename.
/// Used by DisplayLabels, SessionStore (history filter), and tests.
public let placeholderSummaries: Set<String> = [
    "Processing...", "Needs permission", "Session started",
    "Process ended", "Finished",
]

/// Composes a session row's main label from display name + summary, budgeting
/// so both stay visible on one line.
///
/// Rules:
///   - No display name → just the summary
///   - Display name + empty summary → just the name (capped to maxName)
///   - Both → "name | summary", each truncated with … so the total fits totalBudget
///   - If summary budget would shrink below minSummary, return just the name
public func composedRowLabel(
    displayName: String?,
    summary: String,
    maxName: Int = 25,
    totalBudget: Int = 65,
    minSummary: Int = 9
) -> String {
    guard let rawName = displayName, !rawName.isEmpty else {
        return summary
    }
    let name = rawName.count > maxName
        ? String(rawName.prefix(maxName - 1)) + "…"
        : rawName
    guard !summary.isEmpty else { return name }
    let summaryBudget = max(0, totalBudget - name.count - 3)  // " | "
    guard summaryBudget >= minSummary else { return name }
    let cleanSummary = summary.count > summaryBudget
        ? String(summary.prefix(summaryBudget - 1)) + "…"
        : summary
    return "\(name) | \(cleanSummary)"
}

/// Returns a display summary for a session, truncated on a word boundary.
/// Falls back to the directory basename if summary is nil, empty, or a generic placeholder.
public func displaySummary(for session: Session, maxLength: Int = 40) -> String {
    let raw = session.summary ?? ""
    if raw.isEmpty || placeholderSummaries.contains(raw) {
        let dir = session.directory ?? session.name
        return URL(fileURLWithPath: dir).lastPathComponent
    }

    if raw.count <= maxLength {
        return raw
    }

    let truncated = String(raw.prefix(maxLength))
    if let lastSpace = truncated.lastIndex(of: " "),
       truncated.distance(from: truncated.startIndex, to: lastSpace) > maxLength / 2 {
        return String(truncated[..<lastSpace]) + "…"
    }
    return truncated + "…"
}
