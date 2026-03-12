import AppKit
import AgentPulseLib

enum DirtyAction {
    case branchAnyway
    case commitAndBranch
    case cancel
}

@MainActor
final class WorktreeManager {

    /// One-click worktree creation from a running session's directory.
    func branchFromSession(directory: String) {
        guard !directory.isEmpty else {
            showError("No directory for this session.")
            return
        }

        // Resolve repo root (works from subdirs and existing worktrees)
        guard let repoRoot = repoRoot(directory) else {
            showError("No git repository found in \(URL(fileURLWithPath: directory).lastPathComponent). Worktrees require a git repo.")
            return
        }

        guard let branch = currentBranch(repoRoot) else {
            showError("Cannot branch — HEAD is detached or repo is empty.")
            return
        }

        // Check for uncommitted changes
        let dirtyCheck = isRepoDirty(repoRoot)
        guard let dirty = dirtyCheck.value else {
            showError("Git error: \(dirtyCheck.error ?? "")")
            return
        }

        // Pick the word early so we can use it in the commit message
        let repoName = URL(fileURLWithPath: repoRoot).lastPathComponent
        let existingNames = existingWorktreeNames(repoRoot)

        guard let word = pickUnusedWord(existingWorktrees: existingNames, repoName: repoName) else {
            showError("All worktree names in use. Remove some worktrees first.")
            return
        }

        if dirty {
            let action = showDirtyDialog(repoName: repoName)
            switch action {
            case .cancel:
                return
            case .commitAndBranch:
                if !commitCheckpoint(dir: repoRoot, word: word) {
                    return // error already shown
                }
            case .branchAnyway:
                break // proceed from last commit
            }
        }

        createWorktreeAndLaunch(repoDir: repoRoot, repoName: repoName, branch: branch, word: word)
    }

    // MARK: - Git Queries

    private func repoRoot(_ dir: String) -> String? {
        let result = shell("git", "-C", dir, "rev-parse", "--show-toplevel")
        guard result.status == 0, !result.output.isEmpty else { return nil }
        return result.output
    }

    private func currentBranch(_ dir: String) -> String? {
        let result = shell("git", "-C", dir, "rev-parse", "--abbrev-ref", "HEAD")
        guard result.status == 0, !result.output.isEmpty, result.output != "HEAD" else { return nil }
        return result.output
    }

    private func isRepoDirty(_ dir: String) -> (value: Bool?, error: String?) {
        let result = shell("git", "-C", dir, "status", "--porcelain")
        guard result.status == 0 else {
            return (nil, result.output)
        }
        return (!result.output.isEmpty, nil)
    }

    private func existingWorktreeNames(_ dir: String) -> [String] {
        let result = shell("git", "-C", dir, "worktree", "list", "--porcelain")
        // Gracefully fall back to empty on failure
        guard result.status == 0 else { return [] }

        // Parse porcelain output — each worktree block starts with "worktree <path>"
        return result.output
            .components(separatedBy: "\n")
            .compactMap { line -> String? in
                guard line.hasPrefix("worktree ") else { return nil }
                let path = String(line.dropFirst("worktree ".count))
                return URL(fileURLWithPath: path).lastPathComponent
            }
    }

    // MARK: - Dialogs

    private func showDirtyDialog(repoName: String) -> DirtyAction {
        let alert = NSAlert()
        alert.messageText = "Uncommitted Changes"
        alert.informativeText = "\(repoName) has uncommitted changes. The new worktree will branch from the last commit."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Branch Anyway")
        alert.addButton(withTitle: "Commit & Branch")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn: return .branchAnyway
        case .alertSecondButtonReturn: return .commitAndBranch
        default: return .cancel
        }
    }

    // MARK: - Git Mutations

    private func commitCheckpoint(dir: String, word: String) -> Bool {
        let addResult = shell("git", "-C", dir, "add", "-A")
        guard addResult.status == 0 else {
            showError("Failed to stage changes: \(addResult.output)")
            return false
        }

        let commitResult = shell("git", "-C", dir, "commit", "-m", "WIP: checkpoint before branch \(word)")
        guard commitResult.status == 0 else {
            showError("Commit failed: \(commitResult.output)")
            return false
        }

        return true
    }

    private func createWorktreeAndLaunch(repoDir: String, repoName: String, branch: String, word: String) {
        let parentDir = URL(fileURLWithPath: repoDir).deletingLastPathComponent().path
        let worktreePath = "\(parentDir)/\(repoName)-\(word)"
        let newBranch = "\(branch)-\(word)"

        let result = shell("git", "-C", repoDir, "worktree", "add", worktreePath, "-b", newBranch)
        guard result.status == 0 else {
            showError("Failed to create worktree: \(result.output)")
            return
        }

        openTerminal(directory: worktreePath, command: "claude")
    }

    // MARK: - Terminal

    private func openTerminal(directory: String, command: String? = nil) {
        var terminalCmd = "cd \"\(directory)\""
        if let command, !command.isEmpty {
            terminalCmd += " && \(command)"
        }

        let escaped = terminalCmd
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
            tell application "Terminal"
                activate
                do script "\(escaped)"
            end tell
            """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }

    // MARK: - Helpers

    private func shell(_ args: String...) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return (process.terminationStatus, output.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return (1, error.localizedDescription)
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
