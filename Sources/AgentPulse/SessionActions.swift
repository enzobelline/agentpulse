import AppKit
import AgentPulseLib

/// Encapsulates session actions that require AppKit (osascript, pasteboard, alerts).
/// Called from SwiftUI views via closures.
@MainActor
final class SessionActions {
    let store: SessionStore

    init(store: SessionStore) {
        self.store = store
    }

    // MARK: - Go to Terminal

    func goToTerminal(key: String) {
        let session = store.sessions[key]
        // Try TTY attach for any status — the AppleScript's "not found" path
        // gracefully falls back to openTerminalAt if the window actually is gone.
        switch resolveAttachAction(session: session, sessionKey: key) {
        case .openTerminal(let dir):
            openTerminalAt(dir)
        case .activateWindow(let tty):
            let fallbackDir = session?.directory ?? key
            let script = """
                tell application "Terminal"
                    repeat with w in windows
                        try
                            repeat with t in tabs of w
                                if tty of t is "\(tty)" then
                                    set selected tab of w to t
                                    set frontmost of w to true
                                    activate
                                    return "found"
                                end if
                            end repeat
                        end try
                    end repeat
                    return "not found"
                end tell
                """
            // Run off main thread to avoid blocking UI
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", script]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if output != "found" {
                        DispatchQueue.main.async { self?.openTerminalAt(fallbackDir) }
                    }
                } catch {
                    DispatchQueue.main.async { self?.openTerminalAt(fallbackDir) }
                }
            }
        }
    }

    private func openTerminalAt(_ path: String) {
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
            tell application "Terminal"
                activate
                do script "cd \\"\(escaped)\\""
            end tell
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }

    // MARK: - Pin / Unpin

    func togglePin(key: String) {
        store.togglePin(key)
    }

    func isPinned(key: String) -> Bool {
        store.settings.pinnedSessions.contains(key)
    }

    // MARK: - Dismiss

    func dismissSession(key: String) {
        store.removeSessions([key])
    }

    // MARK: - Copy

    func copySessionId(key: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key, forType: .string)
    }

    func copyPath(key: String) {
        let path = store.sessions[key]?.directory ?? store.sessions[key]?.name ?? key
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    // MARK: - Resume (History)

    private func shellEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "$", with: "\\$")
         .replacingOccurrences(of: "`", with: "\\`")
    }

    private func isValidSessionId(_ id: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return id.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    func resumeSession(directory: String, sessionId: String) {
        guard isValidSessionId(sessionId) else { return }
        let escapedDir = shellEscape(directory)
        let tmpPath = NSTemporaryDirectory() + "agentpulse-resume.command"
        let script = "#!/bin/bash\ncd \"\(escapedDir)\" && claude --resume \(sessionId)\n"
        do {
            try script.write(toFile: tmpPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmpPath)
            NSWorkspace.shared.open(URL(fileURLWithPath: tmpPath))
        } catch {}
    }

    func resumeSessionDangerous(directory: String, sessionId: String) {
        guard isValidSessionId(sessionId) else { return }
        let escapedDir = shellEscape(directory)
        let tmpPath = NSTemporaryDirectory() + "agentpulse-resume.command"
        let script = "#!/bin/bash\ncd \"\(escapedDir)\" && claude --resume \(sessionId) --dangerously-skip-permissions\n"
        do {
            try script.write(toFile: tmpPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmpPath)
            NSWorkspace.shared.open(URL(fileURLWithPath: tmpPath))
        } catch {}
    }

    func copyResumeCommand(directory: String, sessionId: String) {
        let escapedDir = shellEscape(directory)
        let command = "cd \"\(escapedDir)\" && claude --resume \(sessionId)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    // MARK: - Open New Session

    func openNewSession(directory: String) {
        openTerminalAt(directory)
    }

    // MARK: - Worktree

    func createWorktree(directory: String) {
        WorktreeManager().branchFromSession(directory: directory)
    }
}
