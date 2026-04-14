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
        switch resolveAttachAction(session: session, sessionKey: key) {
        case .openTerminal(let dir):
            openTerminalAt(dir)
        case .activateWindow(let tty):
            let script = """
                tell application "Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is "\(tty)" then
                                set selected tab of w to t
                                set frontmost of w to true
                                activate
                                return "found"
                            end if
                        end repeat
                    end repeat
                    return "not found"
                end tell
                """
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
                    let dir = session?.directory ?? key
                    openTerminalAt(dir)
                }
            } catch {
                let dir = session?.directory ?? key
                openTerminalAt(dir)
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

    // MARK: - Rename

    func renameSession(key: String) {
        let currentName = store.sessions[key]?.displayName ?? store.sessions[key]?.summary ?? ""
        let alert = NSAlert()
        alert.messageText = "Rename Session"
        alert.informativeText = "Enter a name for this session (max 40 chars):"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = currentName
        input.placeholderString = "e.g. auth refactor, bug #342"
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let raw = input.stringValue.trimmingCharacters(in: .whitespaces)
            let newName = raw.count > 40 ? String(raw.prefix(40)) : raw
            store.renameSession(key, displayName: newName.isEmpty ? nil : newName)
        }
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

    func resumeSession(directory: String, sessionId: String) {
        let tmpPath = NSTemporaryDirectory() + "agentpulse-resume.command"
        let script = "#!/bin/bash\ncd \"\(directory)\" && claude --resume \(sessionId)\n"
        do {
            try script.write(toFile: tmpPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmpPath)
            NSWorkspace.shared.open(URL(fileURLWithPath: tmpPath))
        } catch {}
    }

    func resumeSessionDangerous(directory: String, sessionId: String) {
        let tmpPath = NSTemporaryDirectory() + "agentpulse-resume.command"
        let script = "#!/bin/bash\ncd \"\(directory)\" && claude --resume \(sessionId) --dangerously-skip-permissions\n"
        do {
            try script.write(toFile: tmpPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmpPath)
            NSWorkspace.shared.open(URL(fileURLWithPath: tmpPath))
        } catch {}
    }

    func copyResumeCommand(directory: String, sessionId: String) {
        let command = "cd \"\(directory)\" && claude --resume \(sessionId)"
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
