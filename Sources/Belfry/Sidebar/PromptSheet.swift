import SwiftUI

/// A pending modal prompt raised from the sidebar or toolbar.
enum SidebarPrompt: Identifiable {
    case addHost
    case newSession(host: HostModel)
    case renameSession(host: HostModel, session: TmuxSession)
    case renameWindow(host: HostModel, window: TmuxWindow)

    var id: String {
        switch self {
        case .addHost: return "addHost"
        case .newSession(let h): return "newSession:\(h.id)"
        case .renameSession(_, let s): return "renameSession:\(s.id)"
        case .renameWindow(_, let w): return "renameWindow:\(w.id)"
        }
    }
}

/// A destructive action awaiting confirmation.
struct ConfirmAction: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let confirmLabel: String
    let perform: () -> Void
}

/// tmux names can't safely carry quotes/newlines through control mode; keep them
/// to a tidy single line.
func sanitizeName(_ raw: String) -> String {
    raw.replacingOccurrences(of: "'", with: "")
        .replacingOccurrences(of: "\"", with: "")
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Routes a `SidebarPrompt` to its form.
struct PromptSheet: View {
    let prompt: SidebarPrompt
    let model: AppModel

    var body: some View {
        switch prompt {
        case .addHost:
            AddHostForm(model: model)
        case .newSession(let host):
            TextPromptForm(title: "New Session", field: "Session name", initial: "", confirmLabel: "Create") { name in
                host.client.newSession(name: name)
            }
        case .renameSession(let host, let session):
            TextPromptForm(title: "Rename Session", field: "Name", initial: session.name, confirmLabel: "Rename") { name in
                host.client.renameSession(id: session.id, to: name)
            }
        case .renameWindow(let host, let window):
            TextPromptForm(title: "Rename Window", field: "Name", initial: window.name, confirmLabel: "Rename") { name in
                host.client.renameWindow(id: window.id, to: name)
            }
        }
    }
}

/// A small one-field text prompt (create/rename).
private struct TextPromptForm: View {
    let title: String
    let field: String
    let confirmLabel: String
    let onSubmit: (String) -> Void

    @State private var text: String
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    init(title: String, field: String, initial: String, confirmLabel: String, onSubmit: @escaping (String) -> Void) {
        self.title = title
        self.field = field
        self.confirmLabel = confirmLabel
        self.onSubmit = onSubmit
        _text = State(initialValue: initial)
    }

    private var cleaned: String { sanitizeName(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            TextField(field, text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(submit)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(confirmLabel, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(cleaned.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear { focused = true }
    }

    private func submit() {
        let name = cleaned
        guard !name.isEmpty else { return }
        onSubmit(name)
        dismiss()
    }
}

/// Add an SSH host, with suggestions drawn from ~/.ssh/config.
private struct AddHostForm: View {
    let model: AppModel

    @State private var alias: String = ""
    @State private var configHosts: [SSHConfigHost] = []
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    private var trimmed: String { alias.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var suggestions: [SSHConfigHost] {
        let existing = Set(model.hosts.compactMap { $0.transport.sshAlias })
        return configHosts.filter { host in
            !existing.contains(host.alias)
                && (trimmed.isEmpty || host.label.localizedCaseInsensitiveContains(trimmed))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add SSH Host").font(.headline)
            TextField("ssh alias or user@host", text: $alias)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(submit)

            if !suggestions.isEmpty {
                Text("From ~/.ssh/config").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(suggestions) { host in
                            Button {
                                alias = host.alias
                                submit()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "network").foregroundStyle(.secondary)
                                    Text(host.label)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 3)
                            .padding(.horizontal, 6)
                        }
                    }
                }
                // A ScrollView has no intrinsic height; pin a concrete one (sized
                // to content, capped) or it collapses to zero inside the fit-to-
                // content sheet.
                .frame(height: min(CGFloat(suggestions.count) * 30 + 8, 160))
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.secondary.opacity(0.25))
                )
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!AppModel.isValidSSHAlias(trimmed))
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear {
            focused = true
            configHosts = SSHConfig.hosts()
        }
    }

    private func submit() {
        let value = trimmed
        guard !value.isEmpty else { return }
        model.addHost(alias: value)
        dismiss()
    }
}
