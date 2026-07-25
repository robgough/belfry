import Foundation
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
    /// Dedicated connection for file operations, opened lazily on first use.
    /// Owned by the transport (host lifetime), so transfers survive control
    /// reconnects and background suspensions of the tmux plane.
    private lazy var fileSession = SSHFileSession { [saved] in
        Self.fileSessionConfiguration(saved: saved)
    }

    init(saved: SavedHost) {
        self.saved = saved
    }

    var isLocal: Bool { false }
    var savedHost: SavedHost? { saved }
    /// Hooks management shells out over ssh on macOS; not wired up on iOS yet.
    var hooksManager: (any HooksManaging)? { nil }

    func makeFileBrowser() -> (any FileBrowsing)? {
        RemoteFileBrowser(runner: fileSession)
    }

    /// SSH local forward for localhost previews (rides the file connection).
    func openLocalForward(targetHost: String, targetPort: Int) async throws -> TerminiSSHLocalForward {
        try await fileSession.openLocalForward(targetHost: targetHost, targetPort: targetPort)
    }

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

    func cleanUpOnRemoval() {
        fileSession.shutdown()
        KeychainStore.deleteSecret(for: saved.alias)
    }

    /// Connection-only session (no shell channel): every file operation is an
    /// exec child channel on it. Secret comes from the Keychain at connect
    /// time, and TOFU state is shared with the control connection, so this
    /// opens silently once the host has connected at all.
    private static func fileSessionConfiguration(saved: SavedHost) -> TerminiSSHConfiguration {
        let secret = KeychainStore.secret(for: saved.alias) ?? ""
        let usesKey = saved.authMethod == SavedHost.authMethodKey
        return TerminiSSHConfiguration(
            host: saved.hostname ?? saved.alias,
            port: saved.port ?? 22,
            username: saved.username ?? "",
            password: usesKey ? "" : secret,
            privateKeyPEM: usesKey ? secret : nil,
            opensPrimaryChannel: false,
            hostKeyPolicy: .trustOnFirstUse)
    }

    /// PATH/locale handling for the non-interactive exec shell lives in the
    /// shared RemoteTmux builder. `-u`: without it tmux decides this client
    /// can't take UTF-8 and rewrites every non-ASCII cell as `_`.
    static func tmuxCommand(_ args: String) -> String {
        RemoteTmux.command(args: "-u \(args)")
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
/// libghostty — the same engine as the Mac app. (SwiftTerm's CoreText
/// renderer was retired once GhosttyKit's iOS Metal surface-attach fixes
/// landed in the vendored 0.1.6 build; the surface view carries a
/// renderer-health rebuild path in case the GPU side ever degrades.)
///
/// The ghostty view is created once and owned here, so terminal state
/// survives SwiftUI remounts. Remote bytes flow session → controller → view
/// (Termini feeds libghostty off-main); typed text flows the other way via
/// `controller.onInputText`, which Belfry intercepts for the sticky-Ctrl
/// modifier before handing bytes to the SSH channel.

@MainActor
final class BelfrySSHWorkspace: NSObject, TerminalWorkspace {
    private let session: TerminiSSHSession
    private let configuration: TerminiSSHConfiguration
    private let controller = TerminiTerminalController()
    let terminalView = BelfryGhosttySurfaceView()
    private(set) var terminalSize: TerminiTerminalSize?

    init(configuration: TerminiSSHConfiguration) {
        self.configuration = configuration
        self.session = TerminiSSHSession(controller: controller)
        super.init()
        terminalView.terminalAppearance = Self.appearance(fontSize: nil)
        terminalView.bind(controller: controller)
        // The session wires `onInputText` to itself in its init; re-route it
        // through Belfry so the sticky-Ctrl modifier can transform typed text
        // before it hits the wire.
        controller.onInputText = { [weak self] text in
            self?.sendTyped(text)
        }
        #if DEBUG
        // Harness probe: BELFRY_TEST_TAPWRITES=1 logs ghostty-originated host
        // writes (mouse reports etc.) so headless runs can see whether wheel
        // events actually left the renderer.
        if ProcessInfo.processInfo.environment["BELFRY_TEST_TAPWRITES"] == "1" {
            controller.onTransportWrite = { [weak self] data in
                let hex = data.map { String(format: "%02x", $0) }.joined()
                NSLog("BELFRY-TAPWRITE %@", hex)
                self?.session.send(data)
            }
        }
        #endif
        controller.onSizeChange = { [weak self] size in
            guard let self else { return }
            terminalSize = size
            session.updateTerminalSize(size)
        }
        terminalView.onRendererRebuild = { [weak self] in
            // The rebuilt surface starts blank; a winsize nudge makes tmux
            // repaint the whole client.
            self?.redrawNudge()
        }
        terminalView.installTrackpad { [weak self] point in
            // Long-press without steering: token preview (link/file path).
            self?.onTokenLongPress?(point)
        }
        // Routed hardware-key bytes (ctrl chords, alt-meta) go straight to
        // the channel — same path the sticky-Ctrl modifier uses.
        terminalView.onHardwareKeyBytes = { [weak self] data in
            self?.session.send(data)
        }
    }

    /// Long-press on a token in terminal output (set by the preview layer).
    var onTokenLongPress: ((CGPoint) -> Void)?

    /// One-shot Ctrl modifier armed from the keyboard dock; consumed by the
    /// next typed character.
    let stickyModifiers = StickyModifierState()

    private func sendTyped(_ text: String) {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\r")
            .replacingOccurrences(of: "\n", with: "\r")
        session.send(stickyModifiers.apply(to: normalized))
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

    /// Clean up a blank/torn surface with a one-shot winsize nudge (rows-1,
    /// then back) — tmux redraws the whole client on each change.
    private func redrawNudge() {
        guard let size = terminalSize else { return }
        resize(columns: size.columns, rows: max(1, size.rows - 1))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            self?.resize(columns: size.columns, rows: size.rows)
        }
    }

    func focus() {
        // Selecting a window must not summon the keyboard — screen space is
        // precious on touch. But if the keyboard is already up (some terminal
        // holds it), take it over so keystrokes follow the visible session.
        guard BelfryGhosttySurfaceView.keyboardOwner != nil else { return }
        if !terminalView.becomeFirstResponder() {
            // A just-activated surface isn't in the window yet (SwiftUI mounts
            // it on the next update), so the takeover fails. Retry a tick
            // later — re-checking, in case the keyboard went away meanwhile.
            DispatchQueue.main.async { [terminalView] in
                guard BelfryGhosttySurfaceView.keyboardOwner != nil else { return }
                _ = terminalView.becomeFirstResponder()
            }
        }
    }

    func sendInput(_ data: Data) {
        session.send(data)
    }

    func sendKey(_ key: TerminalKey) {
        terminalView.sendKey(key.terminiKey)
    }

    /// Toolbar keyboard toggle. Hiding drops first-responder status, which
    /// dismisses the system keyboard and gives the terminal the whole screen.
    func toggleKeyboard() {
        if terminalView.isFirstResponder {
            _ = terminalView.resignFirstResponder()
        } else {
            _ = terminalView.becomeFirstResponder()
        }
    }

    func makeSurfaceView(fontSize: Double?, isVisible: Bool) -> AnyView {
        AnyView(GhosttySurfaceContainer(
            terminalView: terminalView,
            appearance: Self.appearance(fontSize: fontSize),
            isVisible: isVisible))
    }

    /// Shared resolved theme (Catppuccin fallback on iOS — no Ghostty config
    /// to read here) + bundled Maple Mono NF, both applied through the same
    /// libghostty config path the Mac app uses.
    private static func appearance(fontSize: Double?) -> TerminiTerminalAppearance {
        TerminiTerminalAppearance(
            theme: SurfaceTheme.theme,
            fontSize: fontSize ?? AppModel.platformDefaultFontSize ?? 11,
            fontFamily: .init(name: "Maple Mono NF"),
            extraConfigFilePaths: SurfaceTheme.configFilePaths)
    }
}
