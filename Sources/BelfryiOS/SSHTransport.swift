import Foundation
import SwiftTerm
import SwiftUI
import Termini
import TerminiSSH
import UIKit

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

/// A terminal surface attached to one tmux session over SSH, rendered by
/// SwiftTerm. (libghostty's iOS glyph pipeline draws empty atlases — verified
/// on device and simulator — so iOS uses SwiftTerm's CoreText renderer behind
/// the same TerminalWorkspace seam; macOS keeps libghostty.)
///
/// The SwiftTerm view is created once and owned here, so terminal state
/// survives SwiftUI remounts; remote bytes bypass the Termini controller via
/// the session's raw-output sink and feed SwiftTerm directly.
@MainActor
final class BelfrySSHWorkspace: NSObject, TerminalWorkspace {
    private let session: TerminiSSHSession
    private let configuration: TerminiSSHConfiguration
    let terminalView = SwiftTerm.TerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    private(set) var terminalSize: TerminiTerminalSize?

    init(configuration: TerminiSSHConfiguration) {
        self.configuration = configuration
        // The controller is a required-but-unused mailbox (raw sink bypasses it).
        self.session = TerminiSSHSession(controller: TerminiTerminalController())
        super.init()
        terminalView.terminalDelegate = self
        applyTheme()
        session.onRawOutput = { [weak self] data in
            self?.terminalView.feed(byteArray: ArraySlice([UInt8](data)))
        }
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
            cellWidthPixels: 0,
            cellHeightPixels: 0))
    }

    func focus() {
        _ = terminalView.becomeFirstResponder()
    }

    func makeSurfaceView(fontSize: Double?, isVisible: Bool) -> AnyView {
        AnyView(SwiftTermSurface(terminalView: terminalView, fontSize: fontSize))
    }

    /// Match the shared resolved theme (Catppuccin fallback on iOS, since
    /// there's no Ghostty config to read here).
    private func applyTheme() {
        let theme = GhosttyThemeReader.resolved
        terminalView.installColors(theme.palette.map(Self.termColor))
        terminalView.nativeBackgroundColor = Self.uiColor(theme.background)
        terminalView.nativeForegroundColor = Self.uiColor(theme.foreground)
        terminalView.caretColor = Self.uiColor(theme.cursor)
        terminalView.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    }

    private static func termColor(_ hex: UInt32) -> SwiftTerm.Color {
        SwiftTerm.Color(
            red: UInt16((hex >> 16) & 0xFF) * 257,
            green: UInt16((hex >> 8) & 0xFF) * 257,
            blue: UInt16(hex & 0xFF) * 257)
    }

    private static func uiColor(_ hex: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }
}

extension BelfrySSHWorkspace: TerminalViewDelegate {
    nonisolated func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Data(data)
        Task { @MainActor [weak self] in
            self?.session.send(bytes)
        }
    }

    nonisolated func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
        guard newCols > 0, newRows > 0 else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let size = TerminiTerminalSize(
                columns: newCols, rows: newRows, cellWidthPixels: 0, cellHeightPixels: 0)
            self.terminalSize = size
            self.session.updateTerminalSize(size)
        }
    }

    nonisolated func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
    nonisolated func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
    nonisolated func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {}
    nonisolated func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {}
    nonisolated func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    nonisolated func bell(source: SwiftTerm.TerminalView) {}
}

/// Mounts the workspace's persistent SwiftTerm view into SwiftUI.
private struct SwiftTermSurface: UIViewRepresentable {
    let terminalView: SwiftTerm.TerminalView
    let fontSize: Double?

    func makeUIView(context: Context) -> SwiftTerm.TerminalView { terminalView }

    func updateUIView(_ uiView: SwiftTerm.TerminalView, context: Context) {
        let size = CGFloat(fontSize ?? 13)
        if uiView.font.pointSize != size {
            uiView.font = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }
}
