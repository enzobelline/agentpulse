import Foundation
import AgentPulseLib

// MARK: - Models

struct WorkspaceSession: Codable {
    var sessionId: String
    var directory: String
    var displayName: String?
    var promptTimeline: [String]?
}

struct WorkspaceSnapshot: Codable, Identifiable {
    var id: String  // UUID
    var name: String
    var createdAt: TimeInterval
    var sessions: [WorkspaceSession]
}

struct WorkspaceFile: Codable {
    var workspaces: [WorkspaceSnapshot]
}

// MARK: - Manager

@MainActor
final class WorkspaceManager {
    static let shared = WorkspaceManager()

    private let filePath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.claude/agentpulse-workspaces.json"
    }()

    // MARK: - CRUD

    func loadAll() -> [WorkspaceSnapshot] {
        guard FileManager.default.fileExists(atPath: filePath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
              let file = try? JSONDecoder().decode(WorkspaceFile.self, from: data) else {
            return []
        }
        return file.workspaces.sorted { $0.createdAt > $1.createdAt }
    }

    func save(sessions: [String: Session]) {
        var workspaces = loadAll()

        let snapshot = WorkspaceSnapshot(
            id: UUID().uuidString,
            name: defaultName(),
            createdAt: Date().timeIntervalSince1970,
            sessions: sessions.map { key, session in
                WorkspaceSession(
                    sessionId: key,
                    directory: session.directory ?? session.name,
                    displayName: session.displayName,
                    promptTimeline: session.promptTimeline
                )
            }
        )

        workspaces.insert(snapshot, at: 0)
        persist(workspaces)
    }

    func rename(id: String, newName: String) {
        var workspaces = loadAll()
        if let idx = workspaces.firstIndex(where: { $0.id == id }) {
            workspaces[idx].name = newName
            persist(workspaces)
        }
    }

    func delete(id: String) {
        var workspaces = loadAll()
        workspaces.removeAll { $0.id == id }
        persist(workspaces)
    }

    // MARK: - Restore

    func restore(_ snapshot: WorkspaceSnapshot, using actions: SessionActions) {
        for session in snapshot.sessions {
            actions.resumeSession(directory: session.directory, sessionId: session.sessionId)
            // Small delay between terminal opens to avoid race conditions
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    // MARK: - Helpers

    private func defaultName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter.string(from: Date())
    }

    private func persist(_ workspaces: [WorkspaceSnapshot]) {
        let file = WorkspaceFile(workspaces: workspaces)
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: URL(fileURLWithPath: filePath), options: .atomic)
    }

    // MARK: - Relative Time

    static func relativeTime(_ timestamp: TimeInterval) -> String {
        let now = Date().timeIntervalSince1970
        let seconds = Int(now - timestamp)

        if seconds < 60 { return "just now" }

        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }

        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }

        let days = hours / 24
        if days < 7 { return "\(days)d ago" }

        let weeks = days / 7
        if weeks < 4 { return "\(weeks)w ago" }

        let months = days / 30
        if months < 12 { return "\(months)mo ago" }

        return "\(days / 365)y ago"
    }
}
