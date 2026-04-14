import Foundation
import Testing
@testable import AgentPulseLib

struct WorktreeHelpersTests {

    // MARK: - pickUnusedWord

    @Test("pickUnusedWord with no existing worktrees returns a word")
    func pickUnusedWordNoExisting() {
        let word = pickUnusedWord(existingWorktrees: [], repoName: "myproject")
        #expect(word != nil)
        #expect(worktreeWords.contains(word!))
    }

    @Test("pickUnusedWord with some words taken returns an unused word")
    func pickUnusedWordSomeTaken() {
        let taken = ["myproject-falcon", "myproject-otter", "myproject-raven"]
        let word = pickUnusedWord(existingWorktrees: taken, repoName: "myproject")
        #expect(word != nil)
        #expect(word != "falcon")
        #expect(word != "otter")
        #expect(word != "raven")
    }

    @Test("pickUnusedWord with ALL words taken returns nil")
    func pickUnusedWordAllTaken() {
        let taken = worktreeWords.map { "myproject-\($0)" }
        let word = pickUnusedWord(existingWorktrees: taken, repoName: "myproject")
        #expect(word == nil)
    }

    @Test("pickUnusedWord ignores unrelated directory names")
    func pickUnusedWordIgnoresUnrelated() {
        let dirs = ["otherproject-falcon", "random-dir", "notarepo"]
        let word = pickUnusedWord(existingWorktrees: dirs, repoName: "myproject")
        #expect(word != nil)
        // "falcon" should still be available since it's under a different repo name
    }

    @Test("pickUnusedWord result is in worktreeWords")
    func pickUnusedWordResultValid() {
        let word = pickUnusedWord(existingWorktrees: ["myproject-badger"], repoName: "myproject")
        #expect(word != nil)
        #expect(worktreeWords.contains(word!))
        #expect(word != "badger")
    }

    // MARK: - worktreeLineage

    @Test("worktreeLineage with repo-word pattern returns lineage")
    func lineageBasicMatch() {
        let result = worktreeLineage(directoryName: "myproject-falcon")
        #expect(result != nil)
        #expect(result?.word == "falcon")
        #expect(result?.repo == "myproject")
    }

    @Test("worktreeLineage with no suffix returns nil")
    func lineageNoSuffix() {
        let result = worktreeLineage(directoryName: "myproject")
        #expect(result == nil)
    }

    @Test("worktreeLineage with hyphenated repo name works")
    func lineageHyphenatedRepo() {
        let result = worktreeLineage(directoryName: "my-project-falcon")
        #expect(result != nil)
        #expect(result?.word == "falcon")
        #expect(result?.repo == "my-project")
    }

    @Test("worktreeLineage with unknown word returns nil")
    func lineageUnknownWord() {
        let result = worktreeLineage(directoryName: "myproject-xyznotaword")
        #expect(result == nil)
    }

    @Test("worktreeLineage with empty prefix returns nil")
    func lineageEmptyPrefix() {
        let result = worktreeLineage(directoryName: "-falcon")
        #expect(result == nil)
    }

    @Test("worktreeLineage with no hyphen returns nil")
    func lineageNoHyphen() {
        let result = worktreeLineage(directoryName: "projectfalcon")
        #expect(result == nil)
    }

    // MARK: - groupKey

    @Test("groupKey for non-worktree directory returns unchanged")
    func groupKeyPlainDirectory() {
        let result = groupKey(forDirectory: "/home/dev/myproject")
        #expect(result == "/home/dev/myproject")
    }

    @Test("groupKey for worktree directory returns parent repo path")
    func groupKeyWorktree() {
        let result = groupKey(forDirectory: "/home/dev/myproject-falcon")
        #expect(result == "/home/dev/myproject")
    }

    @Test("groupKey for hyphenated repo worktree returns correct parent")
    func groupKeyHyphenatedRepo() {
        let result = groupKey(forDirectory: "/home/dev/my-cool-project-otter")
        #expect(result == "/home/dev/my-cool-project")
    }

    @Test("groupKey for unknown suffix returns unchanged")
    func groupKeyUnknownSuffix() {
        let result = groupKey(forDirectory: "/home/dev/myproject-notaword")
        #expect(result == "/home/dev/myproject-notaword")
    }

    @Test("groupKey for home directory returns unchanged")
    func groupKeyHomeDir() {
        let result = groupKey(forDirectory: "/home/dev")
        #expect(result == "/home/dev")
    }

    @Test("Worktree and parent repo produce same groupKey")
    func groupKeyMatchesParent() {
        let parent = groupKey(forDirectory: "/home/dev/agentpulse_swift")
        let worktree = groupKey(forDirectory: "/home/dev/agentpulse_swift-falcon")
        #expect(parent == worktree)
    }

    @Test("Multiple worktrees of same repo produce same groupKey")
    func groupKeyMultipleWorktrees() {
        let wt1 = groupKey(forDirectory: "/home/dev/myproject-falcon")
        let wt2 = groupKey(forDirectory: "/home/dev/myproject-otter")
        let wt3 = groupKey(forDirectory: "/home/dev/myproject-raven")
        #expect(wt1 == wt2)
        #expect(wt2 == wt3)
        #expect(wt1 == "/home/dev/myproject")
    }

    // MARK: - Integration tests (real git repos in temp dirs)

    @Test("Create worktree as sibling directory")
    func integrationCreateWorktree() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repoDir = tmp.appendingPathComponent("myrepo")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Init repo with a commit
        try runGit(at: repoDir, "init")
        try runGit(at: repoDir, "commit", "--allow-empty", "-m", "initial")

        // Create worktree as sibling
        let worktreePath = tmp.appendingPathComponent("myrepo-falcon").path
        try runGit(at: repoDir, "worktree", "add", worktreePath, "-b", "main-falcon")

        #expect(FileManager.default.fileExists(atPath: worktreePath))
    }

    @Test("git worktree list output is parseable")
    func integrationWorktreeListParseable() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repoDir = tmp.appendingPathComponent("myrepo")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try runGit(at: repoDir, "init")
        try runGit(at: repoDir, "commit", "--allow-empty", "-m", "initial")

        let worktreePath = tmp.appendingPathComponent("myrepo-otter").path
        try runGit(at: repoDir, "worktree", "add", worktreePath, "-b", "main-otter")

        let output = try runGitOutput(at: repoDir, "worktree", "list", "--porcelain")
        let paths = output.components(separatedBy: "\n")
            .filter { $0.hasPrefix("worktree ") }
            .map { String($0.dropFirst("worktree ".count)) }

        #expect(paths.count == 2) // main repo + one worktree
        #expect(paths.contains(where: { $0.hasSuffix("myrepo-otter") }))
    }

    @Test("Branch from dirty repo after commit checkpoint")
    func integrationBranchFromDirty() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repoDir = tmp.appendingPathComponent("myrepo")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try runGit(at: repoDir, "init")
        try runGit(at: repoDir, "commit", "--allow-empty", "-m", "initial")

        // Create a dirty file
        try "hello".write(to: repoDir.appendingPathComponent("test.txt"), atomically: true, encoding: .utf8)
        try runGit(at: repoDir, "add", "-A")
        try runGit(at: repoDir, "commit", "-m", "WIP: checkpoint before branch cobra")

        // Now create worktree
        let worktreePath = tmp.appendingPathComponent("myrepo-cobra").path
        try runGit(at: repoDir, "worktree", "add", worktreePath, "-b", "main-cobra")

        // Verify commit exists in worktree
        let log = try runGitOutput(at: URL(fileURLWithPath: worktreePath), "log", "--oneline", "-1")
        #expect(log.contains("checkpoint"))
    }

    @Test("Branch from existing worktree (worktree-of-worktree)")
    func integrationBranchFromWorktree() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repoDir = tmp.appendingPathComponent("myrepo")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try runGit(at: repoDir, "init")
        try runGit(at: repoDir, "commit", "--allow-empty", "-m", "initial")

        // Create first worktree
        let wt1Path = tmp.appendingPathComponent("myrepo-falcon").path
        try runGit(at: repoDir, "worktree", "add", wt1Path, "-b", "main-falcon")

        // Create second worktree FROM the first worktree
        let wt2Path = tmp.appendingPathComponent("myrepo-otter").path
        try runGit(at: URL(fileURLWithPath: wt1Path), "worktree", "add", wt2Path, "-b", "main-falcon-otter")

        #expect(FileManager.default.fileExists(atPath: wt2Path))
    }

    // MARK: - Test Helpers

    private func runGit(at dir: URL, _ args: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = dir
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errData = (process.standardError as! Pipe).fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8) ?? ""
            throw GitError.failed(errStr)
        }
    }

    private func runGitOutput(at dir: URL, _ args: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = dir
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errData = (process.standardError as! Pipe).fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8) ?? ""
            throw GitError.failed(errStr)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private enum GitError: Error {
        case failed(String)
    }
}
