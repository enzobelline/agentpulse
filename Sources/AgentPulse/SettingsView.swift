import SwiftUI
import AgentPulseLib

struct SettingsView: View {
    var store: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Notifications
                    GroupBox("Notifications") {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Notifications", isOn: notificationsBinding)
                            Toggle("Sound", isOn: soundBinding)

                            if store.settings.soundEnabled {
                                HStack {
                                    Text("Waiting:")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Picker("", selection: waitingSoundBinding) {
                                        ForEach(Settings.availableSounds, id: \.self) { sound in
                                            Text(sound).tag(sound)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(width: 100)
                                }

                                HStack {
                                    Text("Done:")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Picker("", selection: doneSoundBinding) {
                                        ForEach(Settings.availableSounds, id: \.self) { sound in
                                            Text(sound).tag(sound)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(width: 100)
                                }
                            }
                        }
                        .padding(4)
                    }

                    // Display
                    GroupBox("Display") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Visible in menubar:")
                                    .font(.caption)
                                Picker("", selection: visibleBinding) {
                                    ForEach(Constants.maxVisibleRange, id: \.self) { n in
                                        Text("\(n)").tag(n)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 60)
                            }

                            HStack {
                                Text("Auto-clear done after:")
                                    .font(.caption)
                                Picker("", selection: autoClearBinding) {
                                    ForEach(Constants.autoClearOptions, id: \.self) { mins in
                                        Text(AgentPulseLib.autoClearLabel(mins)).tag(mins)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 80)
                            }
                        }
                        .padding(4)
                    }

                    // Clear
                    GroupBox("Sessions") {
                        VStack(alignment: .leading, spacing: 8) {
                            let doneCount = store.sessions.values.filter { $0.status == "done" }.count
                            Button("Clear Done Sessions (\(doneCount))") {
                                let keys = store.sessions.filter { $0.value.status == "done" }.map(\.key)
                                store.removeSessions(keys)
                            }
                            .disabled(doneCount == 0)

                            Button("Clear All Sessions") {
                                store.removeSessions(Array(store.sessions.keys))
                            }
                            .foregroundStyle(.red.opacity(0.8))
                            .disabled(store.sessions.isEmpty)
                        }
                        .padding(4)
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 420, height: 400)
    }

    // MARK: - Bindings

    private var notificationsBinding: Binding<Bool> {
        Binding(
            get: { store.settings.notificationsEnabled },
            set: { store.settings.notificationsEnabled = $0; store.saveSettings() }
        )
    }

    private var soundBinding: Binding<Bool> {
        Binding(
            get: { store.settings.soundEnabled },
            set: { store.settings.soundEnabled = $0; store.saveSettings() }
        )
    }

    private var waitingSoundBinding: Binding<String> {
        Binding(
            get: { store.settings.waitingSound },
            set: { store.settings.waitingSound = $0; store.saveSettings() }
        )
    }

    private var doneSoundBinding: Binding<String> {
        Binding(
            get: { store.settings.doneSound },
            set: { store.settings.doneSound = $0; store.saveSettings() }
        )
    }

    private var visibleBinding: Binding<Int> {
        Binding(
            get: { store.settings.maxVisibleSessions },
            set: { store.settings.maxVisibleSessions = $0; store.saveSettings() }
        )
    }

    private var autoClearBinding: Binding<Int> {
        Binding(
            get: { store.settings.autoClearAfterMinutes },
            set: { store.settings.autoClearAfterMinutes = $0; store.saveSettings() }
        )
    }
}
