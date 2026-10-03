import Foundation

/// Identifies a window within a specific host (window ids are only unique per
/// tmux server, so selection must carry the host too).
struct WindowSelection: Hashable {
    let hostID: String
    let windowID: String
    /// Set when the selection came from an agent row: that agent's pane, to
    /// focus within the window. Lets the Mac's native list selection carry
    /// "this agent" (keyboard selection included) rather than just a window,
    /// and keeps an agent row's highlight separate from its window's row.
    var paneID: String? = nil

    /// Same host and window, whatever the pane.
    func sameWindow(as other: WindowSelection?) -> Bool {
        guard let other else { return false }
        return hostID == other.hostID && windowID == other.windowID
    }
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
    /// The active pane's foreground command (e.g. "zsh", "nvim", "2.1.284").
    var command: String = ""
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

    /// The working directory's last component ("~" for home), "" when unknown.
    var folder: String {
        guard !currentPath.isEmpty else { return "" }
        let abbreviated = abbreviateHomePath(currentPath)
        if abbreviated == "~" || abbreviated == "/" { return abbreviated }
        return (currentPath as NSString).lastPathComponent
    }

    /// What the window *is*, for the sidebar. tmux's automatic names are just
    /// the foreground command — "zsh", or Claude Code's "2.1.284" — which
    /// says nothing, so: a shell's or agent's folder (the project — the task
    /// goes beside it, since a list of tasks alone doesn't say which project
    /// is which); another program's name. A name the user chose always wins.
    var title: String {
        guard hasAutomaticName else { return name }
        let cmd = command.lowercased()
        if primaryAgent != nil || cmd.isEmpty || AgentPane.shells.contains(cmd) || AgentKind(command: cmd) != nil {
            if !folder.isEmpty { return folder }
            if let agent = primaryAgent, !agent.task.isEmpty { return agent.task }
            return name.isEmpty ? "window \(index)" : name
        }
        return command
    }

    /// Shown dimmed beside the title: an agent's task, else the folder when
    /// the title isn't already it.
    var titleDetail: String {
        let t = title
        if let agent = primaryAgent, !agent.task.isEmpty, agent.task != t { return agent.task }
        return (folder.isEmpty || t == folder) ? "" : folder
    }

    /// Whether `name` is tmux's automatic one (the command, a shell, a
    /// version number) rather than something the user set.
    private var hasAutomaticName: Bool {
        let n = name.lowercased()
        return n.isEmpty || n == command.lowercased() || AgentPane.shells.contains(n)
            || AgentKind(command: n) != nil
    }

    /// An SF Symbol for what's running: agents, shells, editors, builds…
    var symbol: String {
        if primaryAgent != nil { return "sparkle" }
        let cmd = command.lowercased()
        switch cmd {
        case "", _ where AgentPane.shells.contains(cmd): return "terminal"
        case "vim", "nvim", "vi", "hx", "helix", "emacs", "nano", "micro", "kak": return "square.and.pencil"
        case "ssh", "mosh", "mosh-client", "et": return "network"
        case "make", "cargo", "swift", "swift-build", "xcodebuild", "npm", "pnpm", "yarn", "bun",
             "go", "gradle", "mvn", "just", "bazel", "cmake", "ninja", "mix", "rake": return "hammer"
        case "node", "python", "python3", "ruby", "deno", "elixir", "iex", "irb", "beam.smp",
             "rails", "php", "java": return "chevron.left.forwardslash.chevron.right"
        case "docker", "lazydocker", "docker-compose", "kubectl", "k9s": return "shippingbox"
        case "htop", "btop", "top", "glances", "bottom", "btm": return "gauge.with.dots.needle.33percent"
        case "git", "lazygit", "tig", "gitui": return "arrow.triangle.branch"
        case "psql", "mysql", "redis-cli", "sqlite3", "pgcli", "mongosh": return "cylinder"
        case "less", "man", "tail", "more", "bat": return "doc.text"
        default: return "terminal"
        }
    }
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
    /// another host). Set by the sidebar. A finished agent is marked seen when
    /// you *leave* its window, not when you arrive — so clicking a "just
    /// finished" agent doesn't yank it into another lane under your pointer.
    var viewedWindowID: String? {
        didSet {
            guard viewedWindowID != oldValue, let left = oldValue else { return }
            let seen = rawWindows.values.joined()
                .filter { $0.id == left }
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
