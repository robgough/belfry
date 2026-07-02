import SwiftUI

/// Add an SSH host (iOS). No system ssh binary or ~/.ssh/config here, so the
/// endpoint and credentials are entered explicitly; the secret goes to the
/// Keychain and everything else to hosts.json.
struct AddHostForm: View {
    let model: AppModel

    @State private var name = ""
    @State private var hostname = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var authMethod = SavedHost.authMethodPassword
    @State private var password = ""
    @State private var privateKeyPEM = ""
    @Environment(\.dismiss) private var dismiss

    private var trimmedHost: String { hostname.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedUser: String { username.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var usesKey: Bool { authMethod == SavedHost.authMethodKey }
    private var secret: String {
        usesKey ? privateKeyPEM.trimmingCharacters(in: .whitespacesAndNewlines) : password
    }
    private var canSubmit: Bool {
        AppModel.isValidSSHAlias(trimmedHost) && !trimmedUser.isEmpty
            && Int(port) != nil && !secret.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Host") {
                    TextField("Name (optional)", text: $name)
                    TextField("Hostname", text: $hostname)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Authentication") {
                    Picker("Method", selection: $authMethod) {
                        Text("Password").tag(SavedHost.authMethodPassword)
                        Text("Private Key").tag(SavedHost.authMethodKey)
                    }
                    .pickerStyle(.segmented)
                    if usesKey {
                        TextField("Private key (PEM)", text: $privateKeyPEM, axis: .vertical)
                            .lineLimit(4...10)
                            .font(.system(size: 11, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Text("Unencrypted OpenSSH ed25519 or PEM EC keys. Paste the whole file, BEGIN/END lines included.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        SecureField("Password", text: $password)
                    }
                }
            }
            .navigationTitle("Add SSH Host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: submit).disabled(!canSubmit)
                }
            }
        }
    }

    private func submit() {
        guard canSubmit else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = trimmedName.isEmpty ? "\(trimmedUser)@\(trimmedHost)" : trimmedName
        let saved = SavedHost(
            alias: id,
            displayName: trimmedName.isEmpty ? trimmedHost.split(separator: ".").first.map(String.init) : trimmedName,
            hostname: trimmedHost,
            port: Int(port),
            username: trimmedUser,
            authMethod: authMethod)
        KeychainStore.setSecret(secret, for: id)
        model.adopt(HostModel(saved: saved))
        dismiss()
    }
}
