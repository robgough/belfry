import Foundation

/// Which coding agent runs in a pane.
enum AgentKind: String, Hashable, CaseIterable {
    case claude, codex, opencode, pi, omp, gemini, amp, cursor, aider

    var displayName: String {
        switch self {
        case .claude:   "Claude"
        case .codex:    "Codex"
        case .opencode: "OpenCode"
        case .pi:       "pi"
        case .omp:      "omp"
        case .gemini:   "Gemini"
        case .amp:      "Amp"
        case .cursor:   "Cursor"
        case .aider:    "Aider"
        }
    }

    /// Best-effort identification from a pane's foreground command, for panes
    /// whose agent hasn't reported via hooks. Claude Code renames its process to
    /// its bare version number ("2.1.284"), so that shape counts as Claude —
    /// matching only "claude" meant the no-hooks fallback never fired. A bare
    /// `node`/`bun` stays unmatched: too ambiguous.
    init?(command: String) {
        let cmd = command.lowercased()
        if cmd == "claude" || cmd.hasPrefix("claude") || Self.isVersionNumber(cmd) {
            self = .claude
            return
        }
        switch cmd {
        case "codex", "codex-tui": self = .codex
        case "opencode", ".opencode": self = .opencode
        case "pi": self = .pi
        case "omp": self = .omp
        case "gemini": self = .gemini
        case "amp": self = .amp
        case "cursor-agent": self = .cursor
        case "aider": self = .aider
        default: return nil
        }
    }

    private static func isVersionNumber(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 3 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }
}

/// What an agent in a pane (or, aggregated, a window) is doing — surfaced as a
/// sidebar badge and in the Agents section. Set precisely by the agent status
/// hooks (see docs/agent-status.md) via tmux pane options; otherwise a
/// best-effort guess from the pane's foreground command and title.
enum AgentState: Hashable {
    case none        // no agent here
    case running     // agent present, sub-state unknown (no hooks reporting)
    case working     // busy
    case background  // turn ended but background tasks/agents still running; resumes on its own
    case idle        // finished its turn — nothing pending
    case waiting     // actively waiting for you, e.g. a permission prompt
    case error       // the turn ended on an error (rate limit, API failure…)

    /// Parse a hook-written state value ("" / unknown → nil).
    init?(hookValue: String) {
        switch hookValue.lowercased() {
        case "working", "busy", "thinking": self = .working
        case "background", "bg", "agents": self = .background
        case "idle", "done", "stop": self = .idle
        case "waiting", "attention", "needs-input", "blocked": self = .waiting
        case "error", "failed": self = .error
        default: return nil
        }
    }

    /// Only states where something is blocked on you pull for attention (Dock
    /// badge, top of the Agents list). `.background` deliberately doesn't —
    /// the agent resumes on its own — and neither does `.idle`.
    var needsAttention: Bool { self == .waiting || self == .error }

    /// Ordering for "which agent speaks for this window" and the Agents list.
    var urgency: Int {
        switch self {
        case .waiting: 6
        case .error: 5
        case .working: 4
        case .background: 3
        case .idle: 2
        case .running: 1
        case .none: 0
        }
    }

    var isBusy: Bool { self == .working || self == .background }
}

/// Uncommitted change size in an agent's working tree (vs HEAD, untracked
/// files included), from the `@agent_diff` pane option ("<ins> <del> <files>").
struct DiffStat: Hashable {
    let added: Int
    let removed: Int
    let files: Int

    init(added: Int, removed: Int, files: Int) {
        self.added = added
        self.removed = removed
        self.files = files
    }

    init?(option: String) {
        let parts = option.split(separator: " ").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        added = parts[0]; removed = parts[1]; files = parts[2]
    }

    var isEmpty: Bool { added == 0 && removed == 0 && files == 0 }
}

/// A coding agent running in one tmux pane.
struct AgentPane: Identifiable, Hashable {
    /// tmux pane id (e.g. "%5") — unique per tmux server.
    let id: String
    let windowID: String
    let sessionID: String
    var kind: AgentKind
    var state: AgentState
    /// When the current state began (hook-reported), nil when unknown.
    var since: Date?
    /// The agent's own session name (e.g. Claude Code's "belfry-a2"), "" if none.
    var name: String
    /// What the agent is working on: Claude Code's terminal-title summary when
    /// it has one, else the start of the latest prompt. "" when unknown.
    var summary: String
    /// What it's doing right now ("Edit Foo.swift", "Approve Bash: npm test").
    var activity: String
    var diff: DiffStat?
    /// Tool calls so far this turn, and sub-agents currently running (0 when
    /// unknown) — a sense of the job's size alongside what it's doing now.
    var steps: Int = 0
    var subagents: Int = 0
    /// Running sub-agents as "type: description" (e.g. "general-purpose:
    /// Verifying the release build").
    var tasks: [String] = []
    /// Permission mode as the agent reports it ("default", "acceptEdits",
    /// "plan", "auto", "bypassPermissions"); "" when unknown.
    var mode: String = ""
    /// Git branch of the agent's working directory ("" outside a repo).
    var branch: String = ""
    /// Tokens of context in use (Claude Code), nil when unknown.
    var contextTokens: Int?
    var currentPath: String
    var isActivePane: Bool
    /// Finished (turned idle) since you last looked at its window. Maintained
    /// by `TmuxStore`, not parsed.
    var finishedUnseen: Bool = false

    /// Shells: when one is the pane's foreground process, any agent options
    /// left on the pane are stale (the agent exited without SessionEnd).
    static let shells: Set<String> = ["zsh", "-zsh", "bash", "-bash", "fish", "-fish", "sh", "-sh", "nu", "dash"]

    /// Raw per-pane fields from the control-mode pane listing.
    struct Raw {
        var paneID: String
        var windowID: String
        var sessionID: String
        var isActivePane: Bool
        var command: String
        var currentPath: String
        var title: String
        var kind: String           // @agent_kind
        var state: String          // @agent_state
        var timestamp: String      // @agent_ts
        var activity: String       // @agent_activity
        var summary: String        // @agent_summary
        var name: String           // @agent_name
        var diff: String           // @agent_diff
        var steps: String = ""     // @agent_steps
        var subagents: String = "" // @agent_subagents
        var mode: String = ""      // @agent_mode
        var branch: String = ""    // @agent_branch
        var context: String = ""   // @agent_context
        var tasks: String = ""     // @agent_tasks
        var legacyClaudeState: String  // @claude_state (window option, pre-v4 hooks)
        var legacyClaudeTitle: String  // @claude_title (window option)
    }

    /// Resolve a pane's agent, if any. Precedence: hook-reported pane options
    /// (v4 hooks, any harness) → the legacy window-level `@claude_state` from
    /// pre-v4 Claude hooks (still running in sessions started before the
    /// upgrade) → the terminal title / foreground command (no hooks at all).
    static func detect(_ raw: Raw) -> AgentPane? {
        let command = raw.command.lowercased()
        // A shell in the foreground means the agent has exited: anything its
        // hooks left behind is stale.
        if shells.contains(command) { return nil }

        let titleSummary = claudeTitleSummary(raw.title)
        let commandKind = AgentKind(command: command)
            ?? (titleSummary != nil ? .claude : nil)

        var kind = AgentKind(rawValue: raw.kind)
        var state = AgentState(hookValue: raw.state)
        var name = raw.name
        var optionsTrusted = true
        // Hook options outlive an agent that died without SessionEnd. Distrust
        // them when the foreground process is plainly something else: a
        // different recognisable agent, or — for Claude, whose process shape we
        // know — anything that isn't Claude (or an older Claude's `node`).
        if let optionKind = kind,
           (commandKind != nil && commandKind != optionKind)
            || (optionKind == .claude && commandKind == nil && command != "node") {
            kind = nil
            state = nil
            name = ""
            optionsTrusted = false
        }
        if kind != nil, state == nil { state = .running }
        if kind == nil, commandKind == .claude, let legacy = AgentState(hookValue: raw.legacyClaudeState) {
            kind = .claude
            state = legacy
            if name.isEmpty { name = raw.legacyClaudeTitle }
        }
        if kind == nil, let commandKind {
            kind = commandKind
            // Claude Code's title leads with a braille spinner while it streams.
            state = raw.title.first.map(isBrailleSpinner) == true ? .working : .running
        }
        guard let kind, let state else { return nil }

        let since = optionsTrusted ? TimeInterval(raw.timestamp).map { Date(timeIntervalSince1970: $0) } : nil
        return AgentPane(
            id: raw.paneID, windowID: raw.windowID, sessionID: raw.sessionID,
            kind: kind, state: state, since: since,
            name: name,
            summary: titleSummary ?? (optionsTrusted ? raw.summary : ""),
            activity: optionsTrusted ? raw.activity : "",
            diff: optionsTrusted ? DiffStat(option: raw.diff) : nil,
            steps: optionsTrusted ? Int(raw.steps) ?? 0 : 0,
            subagents: optionsTrusted ? Int(raw.subagents) ?? 0 : 0,
            tasks: optionsTrusted ? raw.tasks.split(separator: "|").map(String.init) : [],
            mode: optionsTrusted ? raw.mode : "",
            branch: optionsTrusted ? raw.branch : "",
            contextTokens: optionsTrusted ? Int(raw.context) : nil,
            currentPath: raw.currentPath,
            isActivePane: raw.isActivePane)
    }

    /// Claude Code titles its terminal "<glyph> <summary>" — "✳" when idle, a
    /// braille spinner frame while streaming — with an AI-written summary of the
    /// task. Returns the summary, or nil when the title isn't in that shape
    /// (e.g. tmux's default, the host name).
    static func claudeTitleSummary(_ title: String) -> String? {
        guard let first = title.first, first == "✳" || isBrailleSpinner(first) else { return nil }
        let rest = title.dropFirst().trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }

    private static func isBrailleSpinner(_ c: Character) -> Bool {
        guard let scalar = c.unicodeScalars.first else { return false }
        return (0x2800...0x28FF).contains(scalar.value)
    }
}

/// The control-mode pane listing (`list-panes -a -F …`) and its parser.
enum PaneListing {
    // One line per *pane* (not per window): agents are tracked per pane, so a
    // window with two agents shows both. Window rows are rebuilt from these
    // lines (window fields repeat on each of its panes), which keeps the refresh
    // at two query blocks — sessions + panes — like the old window listing, so
    // TmuxStore's coalesced rebuild still publishes once per refresh.
    //
    // `@agent_*` are pane options stamped by the agent status hooks (see
    // docs/agent-status.md); `@claude_state`/`@claude_title` are the window
    // options pre-v4 Claude hooks set (still honoured for Claude sessions
    // started before the hooks were upgraded). `pane_title` carries Claude
    // Code's task summary; `pane_current_path` gives rows their directory.
    //
    // Fields are TAB-separated: paths and titles contain spaces. The hooks strip
    // tabs/newlines from everything they write. `pane_title` and `window_name`
    // come last (the name greedy, as before) since only programs/users set them.
    static let format =
        "PANE\t#{session_id}\t#{window_id}\t#{window_index}\t#{window_active}\t#{window_activity_flag}"
        + "\t#{window_bell_flag}\t#{pane_id}\t#{pane_active}\t#{pane_current_command}\t#{pane_current_path}"
        + "\t#{@agent_kind}\t#{@agent_state}\t#{@agent_ts}\t#{@agent_diff}\t#{@claude_state}\t#{@claude_title}"
        + "\t#{@agent_name}\t#{@agent_activity}\t#{@agent_summary}\t#{@agent_steps}\t#{@agent_subagents}"
        + "\t#{@agent_mode}\t#{@agent_branch}\t#{@agent_context}\t#{@agent_tasks}"
        + "\t#{pane_title}\t#{window_name}"
    static let fieldCount = 28

    /// Fold `PANE` lines (see `format`) into windows: window fields from any
    /// of its panes, the active pane's command/path as the window's, and an
    /// `AgentPane` for each pane running an agent. Window order follows tmux's.
    static func windows(fromLines lines: [String]) -> [TmuxWindow] {
        var order: [String] = []
        var byID: [String: TmuxWindow] = [:]
        for line in lines where line.hasPrefix("PANE\t") {
            let f = line.split(separator: "\t", maxSplits: fieldCount - 1, omittingEmptySubsequences: false)
                .map(String.init)
            guard f.count == fieldCount else { continue }
            let windowID = f[2]
            let paneActive = f[8] == "1"
            if byID[windowID] == nil {
                order.append(windowID)
                byID[windowID] = TmuxWindow(
                    id: windowID, sessionID: f[1], index: Int(f[3]) ?? 0, name: f[27],
                    isActive: f[4] == "1", hasActivity: f[5] == "1", hasBell: f[6] == "1")
            }
            if paneActive || byID[windowID]?.currentPath.isEmpty == true {
                byID[windowID]?.currentPath = f[10]
                byID[windowID]?.command = f[9]
            }
            let raw = AgentPane.Raw(
                paneID: f[7], windowID: windowID, sessionID: f[1], isActivePane: paneActive,
                command: f[9], currentPath: f[10], title: f[26],
                kind: f[11], state: f[12], timestamp: f[13], activity: f[18], summary: f[19],
                name: f[17], diff: f[14], steps: f[20], subagents: f[21],
                mode: f[22], branch: f[23], context: f[24], tasks: f[25],
                legacyClaudeState: f[15], legacyClaudeTitle: f[16])
            if let agent = AgentPane.detect(raw) {
                byID[windowID]?.agents.append(agent)
            }
        }
        return order.compactMap { byID[$0] }
    }
}
