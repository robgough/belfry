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
    /// Coding agents running in this window's panes (see `AgentPane.detect`).
    var agents: [AgentPane] = []
    /// tmux's `pane_current_path` for the window's active pane ("" when unknown).
    /// Shown on pinned rows, where a window appears outside its host grouping.
    var currentPath: String = ""

    /// The agent that speaks for the window in its badge: the most urgent one,
    /// preferring the active pane on ties. Per-pane state means two agents in
    /// one window no longer overwrite each other; the window shows whichever
    /// needs you most.
    var primaryAgent: AgentPane? {
        agents.max { a, b in
            (a.state.urgency, a.isActivePane ? 1 : 0) < (b.state.urgency, b.isActivePane ? 1 : 0)
        }
    }

    var agentState: AgentState { primaryAgent?.state ?? .none }

    /// The primary agent's session name ("" when unknown).
    var agentName: String { primaryAgent?.name ?? "" }
}

/// Collapse the common macOS/Linux home prefixes to "~" — we can't know a
/// remote host's real home, but keeping the interesting tail of the path
/// visible matters more than prefix fidelity in a narrow display. Shared by
/// the sidebar's pinned rows and the toolbar's now-playing readout.
func abbreviateHomePath(_ path: String) -> String {
    for prefix in ["/Users/", "/home/"] where path.hasPrefix(prefix) {
        let rest = path.dropFirst(prefix.count)
        guard let slash = rest.firstIndex(of: "/") else { return "~" }
        return "~" + rest[slash...]
    }
    return path
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

    /// pane id → its agent's state at the last rebuild, to spot turns ending.
    @ObservationIgnored private var lastAgentStates: [String: AgentState] = [:]
    /// Panes whose agent finished (busy → idle) while their window wasn't the
    /// one on screen — the "done, not yet seen" marker. Cleared by viewing the
    /// window or by the agent getting busy again.
    @ObservationIgnored private var unseenFinished: Set<String> = []

    /// The window this host is currently showing (nil when the selection is on
    /// another host). Set by the sidebar; viewing a window marks its agents seen.
    var viewedWindowID: String? {
        didSet {
            guard viewedWindowID != oldValue, let viewedWindowID else { return }
            let seen = rawWindows.values.joined()
                .filter { $0.id == viewedWindowID }
                .flatMap { $0.agents.map(\.id) }
            if !unseenFinished.isDisjoint(with: seen) {
                unseenFinished.subtract(seen)
                scheduleRebuild()
            }
        }
    }

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
        lastAgentStates.removeAll()
        unseenFinished.removeAll()
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
        trackFinishedAgents()
        var built: [TmuxSession] = []
        for (id, info) in rawSessions {
            guard !info.name.hasPrefix(Self.internalSessionPrefix) else { continue }
            let windows = (rawWindows[id] ?? [])
                .sorted { $0.index < $1.index }
                .map { window in
                    var window = window
                    window.agents = window.agents.map { agent in
                        var agent = agent
                        agent.finishedUnseen = unseenFinished.contains(agent.id)
                        return agent
                    }
                    return window
                }
            built.append(TmuxSession(id: id, name: info.name, attachedClients: info.attached, windows: windows))
        }
        built.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        // Only publish when something actually changed — a no-op assignment still
        // forces a full List/table reload (and another chance to re-enter).
        if built != sessions { sessions = built }
    }

    /// Fold the latest agent states into `unseenFinished`: a pane whose agent
    /// went from busy to idle off-screen is marked; one that's busy (or asking
    /// for you) again, or gone, is cleared.
    private func trackFinishedAgents() {
        var states: [String: AgentState] = [:]
        for window in rawWindows.values.joined() {
            for agent in window.agents {
                states[agent.id] = agent.state
                if agent.state == .idle {
                    if lastAgentStates[agent.id]?.isBusy == true, window.id != viewedWindowID {
                        unseenFinished.insert(agent.id)
                    }
                } else {
                    unseenFinished.remove(agent.id)
                }
            }
        }
        unseenFinished = unseenFinished.filter { states[$0] != nil }
        lastAgentStates = states
    }
}
