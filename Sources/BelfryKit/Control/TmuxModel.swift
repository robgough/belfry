import Foundation

/// Identifies a window within a specific host (window ids are only unique per
/// tmux server, so selection must carry the host too).
struct WindowSelection: Hashable {
    let hostID: String
    let windowID: String
}

/// Connection state of a host's control-mode link.
enum ConnectionStatus: Hashable {
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case disconnected(String)   // unexpected drop / error (auto-reconnect pending)
    case offline                // user asked to disconnect; stays down until reconnected

    var isLive: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// What Claude Code is doing in a tmux window, surfaced as a sidebar badge.
/// Resolved from a `@claude_state` tmux window option (set precisely by Claude
/// Code hooks — see docs/claude-status-hooks.md) when present, otherwise a
/// best-effort guess from the window's foreground command.
enum ClaudeState: Hashable {
    case none        // no Claude here
    case running     // Claude present, sub-state unknown (no hooks configured)
    case working     // Claude is busy working (from a hook)
    case background  // turn ended but background tasks/agents still running; auto-resumes
    case idle        // Claude finished its turn — nothing pending (from a hook)
    case waiting     // Claude is actively waiting for your input, e.g. a permission prompt (from a hook)

    /// `command` is the window's active-pane foreground command; `hookState` is
    /// the `@claude_state` window option ("" when unset).
    init(command: String, hookState: String) {
        let cmd = command.lowercased()
        // If the active pane is plainly a shell, any leftover hook state is stale
        // (Claude exited) — don't show a badge.
        let shell = ["zsh", "-zsh", "bash", "-bash", "fish", "-fish", "sh", "-sh"].contains(cmd)
        switch hookState.lowercased() {
        case "working", "busy", "thinking":
            self = shell ? .none : .working
        case "background", "bg", "agents":
            self = shell ? .none : .background
        case "idle", "done", "stop":
            self = shell ? .none : .idle
        case "waiting", "attention", "needs-input":
            self = shell ? .none : .waiting
        default:
            // No hook signal: best-effort presence from the command name. ("node"
            // is deliberately not matched — too ambiguous; configure hooks for
            // reliable detection.)
            self = (cmd == "claude" || cmd.hasPrefix("claude")) ? .running : .none
        }
    }

    /// Only a genuine waiting-for-input state pulls for attention (drives the
    /// Dock badge). `.background` deliberately does *not* — Claude will resume
    /// on its own — and neither does `.idle` (the turn is over; nothing pending).
    var needsAttention: Bool { self == .waiting }
}

/// A tmux window within a session. `id` is tmux's stable window id (e.g. "@10").
struct TmuxWindow: Identifiable, Hashable {
    let id: String
    let sessionID: String
    let index: Int
    var name: String
    var isActive: Bool
    var hasActivity: Bool
    /// tmux's `window_bell_flag` — a terminal bell (BEL) rang here and hasn't been
    /// viewed. Set by any program (a finished build, a notification, …), not just
    /// Claude. Cleared by tmux when the window is selected (i.e. when you click it).
    var hasBell: Bool = false
    var claudeState: ClaudeState = .none
}

/// A tmux session. `id` is tmux's stable session id (e.g. "$5").
struct TmuxSession: Identifiable, Hashable {
    let id: String
    var name: String
    /// tmux's `session_attached` — the number of clients attached (Belfry's
    /// own warm surface counts as one; counts also drive drift detection when
    /// a surface's client follows the tmux session selector elsewhere).
    var attachedClients: Int
    var windows: [TmuxWindow]

    var isAttached: Bool { attachedClients > 0 }
}

/// Observable store of the tmux session/window tree, fed by `ControlModeClient`.
///
/// Sessions and windows arrive from two separate `list-*` queries, so we keep
/// the raw halves and recombine them on every update. Sessions whose name is
/// internal (the hidden control-plane session) are filtered out of `sessions`.
@MainActor
@Observable
final class TmuxStore {
    private(set) var sessions: [TmuxSession] = []
    var status: ConnectionStatus = .connecting

    /// session id -> (name, attached client count)
    private var rawSessions: [String: (name: String, attached: Int)] = [:]
    /// session id -> its windows
    private var rawWindows: [String: [TmuxWindow]] = [:]
    private var rebuildScheduled = false

    static let internalSessionPrefix = "__belfry"

    func applySessionList(_ list: [(id: String, name: String, attached: Int)]) {
        rawSessions = Dictionary(uniqueKeysWithValues: list.map { ($0.id, ($0.name, $0.attached)) })
        // Drop windows whose session no longer exists.
        rawWindows = rawWindows.filter { rawSessions[$0.key] != nil }
        scheduleRebuild()
    }

    func applyWindowList(_ windows: [TmuxWindow]) {
        rawWindows = Dictionary(grouping: windows, by: { $0.sessionID })
        scheduleRebuild()
    }

    /// Update the connection status without churning observers when unchanged.
    func setStatus(_ newStatus: ConnectionStatus) {
        if status != newStatus { status = newStatus }
    }

    /// Drop all session/window state (used when a host disconnects).
    func clear() {
        rawSessions.removeAll()
        rawWindows.removeAll()
        if !sessions.isEmpty { sessions = [] }
    }

    /// A session-list and a window-list query arrive as two separate control-mode
    /// blocks (two runloop turns). Rebuilding on each would assign `sessions` twice
    /// in quick succession — and a second assignment landing while SwiftUI's List
    /// is still applying the first re-enters the NSTableView delegate (a documented
    /// crash). Coalesce both into a single rebuild on the next tick instead.
    private func scheduleRebuild() {
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.rebuildScheduled = false
                self.rebuild()
            }
        }
    }

    private func rebuild() {
        var built: [TmuxSession] = []
        for (id, info) in rawSessions {
            guard !info.name.hasPrefix(Self.internalSessionPrefix) else { continue }
            let windows = (rawWindows[id] ?? []).sorted { $0.index < $1.index }
            built.append(TmuxSession(id: id, name: info.name, attachedClients: info.attached, windows: windows))
        }
        built.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        // Only publish when something actually changed — a no-op assignment still
        // forces a full List/table reload (and another chance to re-enter).
        if built != sessions { sessions = built }
    }
}
