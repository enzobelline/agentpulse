import Foundation

enum Constants {
    static let statusFile: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.claude/session-status.json"
    }()

    static let claudeDir: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.claude"
    }()

    static let spinnerFrames: [String] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    static let iconWaiting  = "⏸"
    static let iconDone     = "✓"
    static let iconSleeping = "○"

    static let maxVisibleRange = 1...7
    static let autoClearOptions = [0, 5, 15, 30, 60, 180, 1440]
}
