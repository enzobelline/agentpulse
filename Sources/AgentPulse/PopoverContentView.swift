import SwiftUI
import AgentPulseLib

struct PopoverContentView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AgentPulse")
                .font(.headline)
            Text("SwiftUI scaffold — sessions will appear here")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 400, height: 300)
    }
}
