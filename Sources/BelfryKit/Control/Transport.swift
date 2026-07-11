import Foundation
import SwiftUI
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

/// A live terminal surface workspace (one attached tmux session). Each
/// workspace supplies its own renderer view: macOS uses Termini/libghostty;
/// iOS uses a SwiftTerm-backed view over SSH (libghostty's iOS glyph pipeline
/// isn't usable yet — confirmed broken on device as well as simulator).
@MainActor
protocol TerminalWorkspace: AnyObject {
    var terminalSize: TerminiTerminalSize? { get }
    func start()
    func stop()
    func resize(columns: Int, rows: Int)
    /// Route keyboard focus to this surface (after selection). On iOS this
    /// must not summon the on-screen keyboard — it only transfers focus when
    /// the keyboard is already up.
    func focus()
    /// Write raw bytes into the session's input exactly as if typed — the
    /// attach / drag-and-drop path uses this to paste staged file paths.
    func sendInput(_ data: Data)
    /// The rendered terminal view for this workspace. Called on every SwiftUI
    /// update — must return a view over persistent state (the terminal engine
    /// lives in the workspace, not the returned value).
    func makeSurfaceView(fontSize: Double?, isVisible: Bool) -> AnyView
}

/// Builds the remote-shell command that locates tmux and execs it. Shared by
/// every transport that runs tmux on the far side of ssh (macOS spawned ssh,
/// iOS SSH exec requests, quit cleanup).
///
/// Remote commands run in a non-interactive, non-login shell, so login-profile
/// PATH additions are absent — notably Homebrew tmux on a Mac host, which is
/// invisible to sshd's default PATH. Resolve tmux in-shell with fallbacks to
/// the standard Homebrew paths, and fail with a distinct message (matched by
/// `ControlModeClient.noteDiagnostic`, so it becomes the host's disconnect
/// reason) when it's genuinely missing. The bare environment also has no
/// locale: LANG is exported so tmux takes UTF-8 (with `-u` belt-and-braces)
/// and shells *inside* new sessions inherit it.
enum RemoteTmux {
    static func command(args: String) -> String {
        "TB=$(command -v tmux || echo /opt/homebrew/bin/tmux); "
        + "[ -x \"$TB\" ] || TB=/usr/local/bin/tmux; "
        + "[ -x \"$TB\" ] || { echo 'tmux not found on this host' >&2; exit 127; }; "
        + "export LANG=\"${LANG:-en_US.UTF-8}\"; "
        + "exec \"$TB\" \(args)"
    }

    /// Argv-style variant: ssh joins remote-command words with spaces and the
    /// remote shell re-parses them, so each word is single-quoted (this also
    /// makes session names with spaces survive the trip).
    static func command(argv: [String]) -> String {
        command(args: argv.map(quoted).joined(separator: " "))
    }

    static func quoted(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Outcome of a Claude-hooks management operation (mirrors ClaudeHooks.Outcome,
/// which is macOS-only). `current` is false when hooks are installed but were
/// written by an older Belfry (stale commands) — the owner should reinstall.
enum HooksOutcome {
    case status(installed: Bool, current: Bool)
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
    /// The host is being removed from the app: delete any stored credentials
    /// (iOS: the Keychain entry; macOS: nothing — auth lives in ~/.ssh).
    func cleanUpOnRemoval()
}
