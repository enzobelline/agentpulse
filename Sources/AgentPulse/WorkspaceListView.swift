import SwiftUI
import AgentPulseLib

struct WorkspaceListView: View {
    let actions: SessionActions
    var dismiss: (() -> Void)?
    @State private var workspaces: [WorkspaceSnapshot] = []
    @State private var searchText = ""
    @State private var expandedId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                TextField("Search workspaces...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                Spacer(minLength: 8)
                Text("\(workspaces.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            if filtered.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Text(workspaces.isEmpty ? "No saved workspaces" : "No matches")
                        .foregroundStyle(.secondary)
                    Text(workspaces.isEmpty ? "Save your current sessions to restore them later" : "")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filtered) { workspace in
                            WorkspaceRowView(
                                workspace: workspace,
                                isExpanded: expandedId == workspace.id,
                                actions: actions,
                                dismiss: dismiss,
                                onToggle: {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        expandedId = expandedId == workspace.id ? nil : workspace.id
                                    }
                                },
                                onRename: { newName in
                                    WorkspaceManager.shared.rename(id: workspace.id, newName: newName)
                                    workspaces = WorkspaceManager.shared.loadAll()
                                },
                                onDelete: {
                                    WorkspaceManager.shared.delete(id: workspace.id)
                                    workspaces = WorkspaceManager.shared.loadAll()
                                }
                            )
                            Divider().padding(.horizontal, 16).opacity(0.5)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { workspaces = WorkspaceManager.shared.loadAll() }
    }

    private var filtered: [WorkspaceSnapshot] {
        guard !searchText.isEmpty else { return workspaces }
        let query = searchText.lowercased()
        return workspaces.filter { ws in
            ws.name.lowercased().contains(query) ||
            ws.sessions.contains(where: {
                $0.directory.lowercased().contains(query) ||
                ($0.displayName?.lowercased().contains(query) ?? false)
            })
        }
    }
}

// MARK: - Workspace Row

struct WorkspaceRowView: View {
    let workspace: WorkspaceSnapshot
    let isExpanded: Bool
    let actions: SessionActions
    var dismiss: (() -> Void)?
    let onToggle: () -> Void
    let onRename: (String) -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main row
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(workspace.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text("\(workspace.sessions.count) sessions")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.quaternary)
                        Text(WorkspaceManager.relativeTime(workspace.createdAt))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(isHovered ? Color.primary.opacity(0.06) : Color.clear)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .onTapGesture { onToggle() }

            // Expanded: session details
            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(workspace.sessions, id: \.sessionId) { session in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color.secondary.opacity(0.3))
                                .frame(width: 6, height: 6)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(session.displayName ?? dirName(session.directory))
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                Text(session.directory)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Text(shortId(session.sessionId))
                                .font(.caption2)
                                .foregroundStyle(.quaternary)
                                .monospacedDigit()
                        }
                    }

                    // Restore button
                    HStack {
                        Spacer()
                        Button("Restore All") {
                            dismiss?()
                            WorkspaceManager.shared.restore(workspace, using: actions)
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .contextMenu {
            Button("Restore All Sessions") {
                dismiss?()
                WorkspaceManager.shared.restore(workspace, using: actions)
            }
            Divider()
            Button("Rename") {
                showRenameDialog()
            }
            Divider()
            Button("Delete") { onDelete() }
        }
    }

    private func dirName(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    private func shortId(_ id: String) -> String {
        String(id.prefix(4))
    }

    private func showRenameDialog() {
        let alert = NSAlert()
        alert.messageText = "Rename Workspace"
        alert.informativeText = "Enter a name for this workspace:"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        input.stringValue = workspace.name
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        if alert.runModal() == .alertFirstButtonReturn {
            let name = input.stringValue.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                onRename(name)
            }
        }
    }
}
