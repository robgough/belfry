import Foundation
import Termini
import TerminiSSH

// iOS side of the transport seam: no process spawning exists here, so both the
// control plane and every terminal surface ride library SSH (TerminiSSH /
// SwiftNIO SSH) straight to the host, with tmux run as an *exec* request.

/// Reaches a tmux server over library SSH. Endpoint + auth method come from
/// the persisted `SavedHost`; the secret (password or private-key PEM) is read
/// from the Keychain at connect time, so it's never held or persisted here.
@MainActor
final class SSHHostTransport: HostTransport {
    let saved: SavedHost

    init(saved: SavedHost) {
        self.saved = saved
    }

    var isLocal: Bool { false }
    var savedHost: SavedHost? { saved }
    /// Hooks management shells out over ssh on macOS; not wired up on iOS yet.
    var hooksManager: (any HooksManaging)? { nil }

    func makeControlChannel(controlSessionName: String) -> any ControlChannel {
        SSHControlChannel(configuration: sshConfiguration(
            startupCommand: Self.tmuxCommand("-C new-session -A -s '\(controlSessionName)'")))
    }

    func makeSurfaceWorkspace(sessionName: String) -> any TerminalWorkspace {
        BelfrySSHWorkspace(configuration: sshConfiguration(
            startupCommand: Self.tmuxCommand("new-session -A -s '\(sessionName)'")))
    }

    func invalidateAuthentication(completion: @escaping @MainActor () -> Void) {
        // Credentials are re-read from the Keychain on every connect and there
        // is no cached master connection — nothing to drop.
        completion()
    }

    /// The exec request runs via the remote user's shell non-interactively, so
    /// login-profile PATH additions (Homebrew tmux on a Mac host!) are absent.
    /// Resolve tmux in-shell with the common fallback.
    static func tmuxCommand(_ args: String) -> String {
        "TB=$(command -v tmux || echo /opt/homebrew/bin/tmux); exec \"$TB\" \(args)"
    }

    private func sshConfiguration(startupCommand: String) -> TerminiSSHConfiguration {
        let secret = KeychainStore.secret(for: saved.alias) ?? ""
        let usesKey = saved.authMethod == SavedHost.authMethodKey
        return TerminiSSHConfiguration(
            host: saved.hostname ?? saved.alias,
            port: saved.port ?? 22,
            username: saved.username ?? "",
            password: usesKey ? "" : secret,
            privateKeyPEM: usesKey ? secret : nil,
            term: "xterm-256color",
            startupCommand: startupCommand,
            useExecRequest: true,
            hostKeyPolicy: .trustOnFirstUse)
    }
}

extension SavedHost {
    static let authMethodPassword = "password"
    static let authMethodKey = "key"
}

/// `tmux -C` control stream over an SSH exec channel. One-shot, like its PTY
/// counterpart: connection failure or remote exit reports once via `onExit`
/// and the owner builds a fresh channel to reconnect.
@MainActor
final class SSHControlChannel: ControlChannel {
    var onOutput: ((Data) -> Void)?
    var onReady: (() -> Void)?
    var onExit: ((Int32) -> Void)?

    private let configuration: TerminiSSHConfiguration
    private let session: TerminiSSHSession
    private var everConnected = false
    private var exitReported = false

    init(configuration: TerminiSSHConfiguration) {
        self.configuration = configuration
        // The controller is a required-but-unused mailbox here; raw output
        // bypasses it entirely (Termini's `onRawOutput` patch).
        self.session = TerminiSSHSession(controller: TerminiTerminalController())
        session.onRawOutput = { [weak self] data in
            self?.onOutput?(data)
        }
        session.onStatusChange = { [weak self] status in
            guard let self else { return }
            switch status {
            case .connected:
                self.everConnected = true
                self.onReady?()
            case .failed(let message):
                // Feed the reason through the output path so the owner's
                // diagnostic sniffing (auth failures etc.) sees it.
                self.onOutput?(Data("\(message)\n".utf8))
                self.reportExit(255)
            case .disconnected:
                if self.everConnected { self.reportExit(0) }
            case .connecting:
                break
            }
        }
    }

    func start() {
        let configuration = configuration
        Task { await session.connect(configuration: configuration) }
    }

    func send(_ data: Data) {
        session.send(data)
    }

    func stop() {
        exitReported = true   // deliberate stop must not read as a connection loss
        Task { await session.disconnect() }
    }

    private func reportExit(_ code: Int32) {
        guard !exitReported else { return }
        exitReported = true
        onExit?(code)
    }
}

/// A terminal surface attached to one tmux session over SSH. Unlike Termini's
/// stock SSH workspace this forwards view size changes to the remote PTY
/// (window-change requests), so tmux always matches the rendered grid.
@MainActor
final class BelfrySSHWorkspace: TerminalWorkspace {
    let controller = TerminiTerminalController()
    private let session: TerminiSSHSession
    private let configuration: TerminiSSHConfiguration
    private(set) var terminalSize: TerminiTerminalSize?

    init(configuration: TerminiSSHConfiguration) {
        self.configuration = configuration
        self.session = TerminiSSHSession(controller: controller)
        controller.onSizeChange = { [weak self] size in
            self?.terminalSize = size
            self?.session.updateTerminalSize(size)
        }
        #if DEBUG
        controller.onDiagnosticsChange = { diagnostics in
            NSLog("[BelfrySSH] surface diagnostics: %@", diagnostics.summary)
        }
        #endif
    }

    func start() {
        let configuration = configuration
        Task { await session.connect(configuration: configuration) }
    }

    func stop() {
        Task { await session.disconnect() }
    }

    func resize(columns: Int, rows: Int) {
        session.updateTerminalSize(TerminiTerminalSize(
            columns: columns,
            rows: rows,
            cellWidthPixels: terminalSize?.cellWidthPixels ?? 0,
            cellHeightPixels: terminalSize?.cellHeightPixels ?? 0))
    }
}
