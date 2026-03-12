import AppKit

@MainActor
final class NotificationManager: NSObject {
    static let shared = NotificationManager()

    private let terminalNotifierPath: String? = {
        let paths = [
            "/opt/homebrew/bin/terminal-notifier",
            "/usr/local/bin/terminal-notifier",
        ]
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    private override init() {
        super.init()
    }

    func setup() {}

    func postNotification(title: String, body: String, directory: String?, tty: String? = nil, soundEnabled: Bool, soundName: String = "Glass") {
        if let tn = terminalNotifierPath {
            postViaTerminalNotifier(tn, title: title, body: body, directory: directory, tty: tty, soundEnabled: soundEnabled, soundName: soundName)
        } else {
            postViaOsascript(title: title, body: body, soundEnabled: soundEnabled, soundName: soundName)
        }
    }

    /// Play a named system sound without showing a notification banner.
    func playSoundOnly(_ soundName: String = "Glass") {
        NSSound(named: NSSound.Name(soundName))?.play()
    }

    // MARK: - terminal-notifier (preferred)

    private func postViaTerminalNotifier(_ path: String, title: String, body: String, directory: String?, tty: String?, soundEnabled: Bool, soundName: String) {
        var args = [
            "-title", title,
            "-message", body,
        ]

        if soundEnabled {
            args += ["-sound", soundName]
        }

        // Group by directory so notifications from the same project replace each other
        if let dir = directory {
            args += ["-group", dir]
        }

        // Click notification → attach to session's Terminal tab (or open new if no TTY)
        if let tty = tty, !tty.isEmpty {
            // Use a shell script that calls osascript to find the TTY tab
            let fallbackDir = (directory ?? "~").replacingOccurrences(of: "'", with: "'\\''")
            let cmd = "/usr/bin/osascript -e 'tell application \"Terminal\"' "
                + "-e 'set found to false' "
                + "-e 'repeat with w in windows' "
                + "-e 'repeat with t in tabs of w' "
                + "-e 'if tty of t is \"\(tty)\" then' "
                + "-e 'set selected tab of w to t' "
                + "-e 'set index of w to 1' "
                + "-e 'set found to true' "
                + "-e 'exit repeat' "
                + "-e 'end if' "
                + "-e 'end repeat' "
                + "-e 'if found then exit repeat' "
                + "-e 'end repeat' "
                + "-e 'activate' "
                + "-e 'if not found then do script \"cd \\'\(fallbackDir)\\'\"' "
                + "-e 'end if' "
                + "-e 'end tell'"
            args += ["-execute", cmd]
        } else if let dir = directory {
            let escaped = dir.replacingOccurrences(of: "\"", with: "\\\"")
            let script = "tell application \\\"Terminal\\\" to do script \\\"cd \\\\\\\"\(escaped)\\\\\\\"\\\""
            args += ["-execute", "/usr/bin/osascript -e \"\(script)\""]
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        try? process.run()
    }

    // MARK: - osascript fallback

    private func postViaOsascript(title: String, body: String, soundEnabled: Bool, soundName: String) {
        let escapedTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedBody = body.replacingOccurrences(of: "\"", with: "\\\"")

        var script = "display notification \"\(escapedBody)\" with title \"\(escapedTitle)\""
        if soundEnabled {
            script += " sound name \"\(soundName)\""
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }
}
