import SwiftUI
import AgentPulseLib

struct SettingsView: View {
    var store: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Notifications row
            HStack(spacing: 12) {
                Toggle("Notifications", isOn: notificationsBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Spacer()
                Toggle("Sound", isOn: soundBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            if store.settings.soundEnabled {
                HStack(spacing: 12) {
                    SoundPicker(label: "Waiting:", selection: waitingSoundBinding)
                    SoundPicker(label: "Done:", selection: doneSoundBinding)
                    Spacer()
                }
            }

            Divider()

            // Display row
            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Text("Visible:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("", selection: visibleBinding) {
                        ForEach(Constants.maxVisibleRange, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 50)
                }
                HStack(spacing: 4) {
                    Text("Auto-clear:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("", selection: autoClearBinding) {
                        ForEach(Constants.autoClearOptions, id: \.self) {
                            Text(AgentPulseLib.autoClearLabel($0)).tag($0)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 60)
                }
                Spacer()
            }

            Divider()

            // Keyboard shortcuts (inline)
            VStack(alignment: .leading, spacing: 4) {
                Text("Shortcuts")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    shortcutRow("⌃⌥A", "Toggle dropdown")
                    shortcutRow("Click", "Go to Terminal")
                    shortcutRow("Right-click", "Session actions")
                }
            }

            Divider()

            // Help
            HStack(spacing: 12) {
                Button("Report a Bug") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/enzobelline/agentpulse/issues")!)
                }
                .controlSize(.small)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .onHover { h in if h { NSCursor.pointingHand.push() } else { NSCursor.pop() } }

                Spacer()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func shortcutRow(_ key: String, _ desc: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, design: .monospaced))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.08))
                .cornerRadius(3)
            Text(desc)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Bindings

    private var notificationsBinding: Binding<Bool> {
        Binding(get: { store.settings.notificationsEnabled }, set: { store.settings.notificationsEnabled = $0; store.saveSettings() })
    }
    private var soundBinding: Binding<Bool> {
        Binding(get: { store.settings.soundEnabled }, set: { store.settings.soundEnabled = $0; store.saveSettings() })
    }
    private var waitingSoundBinding: Binding<String> {
        Binding(get: { store.settings.waitingSound }, set: { store.settings.waitingSound = $0; store.saveSettings() })
    }
    private var doneSoundBinding: Binding<String> {
        Binding(get: { store.settings.doneSound }, set: { store.settings.doneSound = $0; store.saveSettings() })
    }
    private var visibleBinding: Binding<Int> {
        Binding(get: { store.settings.maxVisibleSessions }, set: { store.settings.maxVisibleSessions = $0; store.saveSettings() })
    }
    private var autoClearBinding: Binding<Int> {
        Binding(get: { store.settings.autoClearAfterMinutes }, set: { store.settings.autoClearAfterMinutes = $0; store.saveSettings() })
    }
}

// MARK: - Sound Picker

struct SoundPicker: View {
    let label: String
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("", selection: $selection) {
                ForEach(Settings.availableSounds, id: \.self) { sound in
                    Text(sound).tag(sound)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 80)
            .onChange(of: selection) { _, newValue in
                NSSound(named: NSSound.Name(newValue))?.play()
            }
        }
    }
}
