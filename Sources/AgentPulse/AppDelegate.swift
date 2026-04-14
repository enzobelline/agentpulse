import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var sessionStore: SessionStore!
    private var statusBar: StatusBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single-instance guard: if another AgentPulse is already running, quit silently
        let runningInstances = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        if runningInstances.count > 1 {
            NSApplication.shared.terminate(nil)
            return
        }
        // Fallback for bare binary (no bundle ID): check by process name
        let myPid = ProcessInfo.processInfo.processIdentifier
        let others = NSWorkspace.shared.runningApplications.filter {
            $0.localizedName == "AgentPulse" && $0.processIdentifier != myPid
        }
        if !others.isEmpty {
            NSApplication.shared.terminate(nil)
            return
        }

        NotificationManager.shared.setup()

        sessionStore = SessionStore()
        statusBar = StatusBarController(store: sessionStore)
        sessionStore.delegate = statusBar

        sessionStore.loadStatus()
        statusBar.checkFirstRun()
        statusBar.refresh()
        sessionStore.startWatching()
    }
}
