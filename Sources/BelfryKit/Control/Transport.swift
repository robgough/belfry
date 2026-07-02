import Foundation
import Termini

/// A bidirectional byte channel carrying a `tmux -C` control-mode stream.
/// macOS backs this with a forkpty'd local `tmux`/`ssh` process; iOS with an
/// SSH exec channel (no process spawning exists there). The channel is
/// one-shot: once it exits it is discarded and a fresh one is built for the
/// next connect.
@MainActor
protocol ControlChannel: AnyObject {
    /// Raw bytes from the remote (control-mode protocol + any diagnostics).
    var onOutput: ((Data) -> Void)? { get set }
    /// The channel is up and writable — safe to send the initial commands.
    /// (For SSH this is *after* auth + exec; sends before it are dropped.)
    var onReady: (() -> Void)? { get set }
    /// The channel died (process exit / connection failure), with a code.
    var onExit: ((Int32) -> Void)? { get set }

    func start()
    func send(_ data: Data)
    func stop()
}

/// A live terminal surface workspace (one attached tmux session). macOS uses
/// Termini's local-PTY workspace; iOS an SSH-backed one.
@MainActor
protocol TerminalWorkspace: AnyObject {
    var controller: TerminiTerminalController { get }
    var terminalSize: TerminiTerminalSize? { get }
    func start()
    func stop()
    func resize(columns: Int, rows: Int)
}

/// Outcome of a Claude-hooks management operation (mirrors ClaudeHooks.Outcome,
/// which is macOS-only).
enum HooksOutcome {
    case status(installed: Bool)
    case failure(String)
}

/// Manages the Claude status hooks on a host. Blocking calls — run off-main.
/// nil `hooksManager` on a transport hides the hooks UI entirely (iOS, for now).
protocol HooksManaging: Sendable {
    func check() -> HooksOutcome
    func install() -> HooksOutcome
    func remove() -> HooksOutcome
}

/// How to reach one tmux server. Everything platform-specific about talking
/// to a host lives behind this: the control channel, the per-session terminal
/// surfaces, cached-auth invalidation, and (where supported) hooks management.
@MainActor
protocol HostTransport {
    var isLocal: Bool { get }
    /// Persisted form of this host (nil for hosts that shouldn't be saved,
    /// i.e. Local). `displayName` is filled in by the owner before saving.
    var savedHost: SavedHost? { get }
    var hooksManager: (any HooksManaging)? { get }

    func makeControlChannel(controlSessionName: String) -> any ControlChannel
    func makeSurfaceWorkspace(sessionName: String) -> any TerminalWorkspace
    /// Drop any cached authentication so the next connect re-prompts
    /// (macOS: close the shared SSH master; iOS: no-op).
    func invalidateAuthentication(completion: @escaping @MainActor () -> Void)
}
