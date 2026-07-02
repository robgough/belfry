import SwiftUI

/// Add an SSH host, with suggestions drawn from ~/.ssh/config. (macOS — the
/// alias is handed to the system ssh binary, which resolves config/keys/agent.)
struct AddHostForm: View {
    let model: AppModel

    @State private var alias: String = ""
    @State private var configHosts: [SSHConfigHost] = []
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    private var trimmed: String { alias.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var suggestions: [SSHConfigHost] {
        let existing = Set(model.hosts.compactMap { ($0.transport as? TmuxTransport)?.sshAlias })
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
