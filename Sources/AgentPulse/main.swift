import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate: AppDelegate = MainActor.assumeIsolated {
    AppDelegate()
}
app.delegate = delegate

app.run()
