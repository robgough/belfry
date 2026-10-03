import Foundation
import Testing
@testable import Belfry

/// Agent detection from the control-mode pane listing: hook-reported pane
/// options, the legacy window option, and the no-hooks fallbacks.
struct AgentDetectionTests {
    private func raw(_ command: String, title: String = "hailmary", kind: String = "", state: String = "",
                     legacy: String = "", activity: String = "", diff: String = "") -> AgentPane.Raw {
        AgentPane.Raw(paneID: "%1", windowID: "@1", sessionID: "$1", isActivePane: true,
                      command: command, currentPath: "/src", title: title,
                      kind: kind, state: state, timestamp: "1790636829", activity: activity,
                      summary: "fix the build", name: "", diff: diff,
                      legacyClaudeState: legacy, legacyClaudeTitle: "belfry-60")
    }

    @Test func claudeIsRecognisedByItsVersionNumberProcessName() {
        #expect(AgentKind(command: "2.1.284") == .claude)
        #expect(AgentKind(command: "claude") == .claude)
        #expect(AgentKind(command: "1.2") == nil)
        #expect(AgentKind(command: "node") == nil)
    }

    @Test func hookOptionsWin() throws {
        let agent = try #require(AgentPane.detect(raw("2.1.284", title: "✳ Agent status", kind: "claude",
                                                      state: "waiting", activity: "Approve Bash: rm",
                                                      diff: "84 12 3")))
        #expect(agent.kind == .claude)
        #expect(agent.state == .waiting)
        #expect(agent.summary == "Agent status")      // Claude's title beats the prompt
        #expect(agent.activity == "Approve Bash: rm")
        #expect(agent.diff == DiffStat(added: 84, removed: 12, files: 3))
        #expect(agent.since == Date(timeIntervalSince1970: 1790636829))
    }

    @Test func legacyWindowStateStillCountsForClaude() throws {
        let agent = try #require(AgentPane.detect(raw("2.1.284", legacy: "background")))
        #expect(agent.state == .background)
        #expect(agent.name == "belfry-60")
    }

    @Test func noHooksFallsBackToTitleAndCommand() throws {
        #expect(AgentPane.detect(raw("2.1.284", title: "⠋ Thinking"))?.state == .working)
        #expect(AgentPane.detect(raw("2.1.284", title: "✳ Done"))?.state == .running)
        #expect(AgentPane.detect(raw("codex"))?.kind == .codex)
        #expect(AgentPane.detect(raw("vim")) == nil)
    }

    @Test func staleOptionsAreIgnored() {
        // Agent exited without SessionEnd: a shell (or another program) is back.
        #expect(AgentPane.detect(raw("zsh", kind: "claude", state: "working")) == nil)
        #expect(AgentPane.detect(raw("nvim", kind: "claude", state: "working")) == nil)
        // A different agent now runs where Codex's options linger.
        let agent = AgentPane.detect(raw("2.1.284", kind: "codex", state: "working"))
        #expect(agent?.kind == .claude)
        #expect(agent?.activity == "")
    }

    @Test func pluginAgentsReportThroughNode() {
        // pi/omp may show as `node`/`bun`; their options are trusted.
        #expect(AgentPane.detect(raw("node", kind: "pi", state: "idle"))?.kind == .pi)
    }
}

struct PaneListingTests {
    private func line(window: String, index: Int, pane: String, active: Bool, command: String,
                      kind: String = "", state: String = "", title: String = "host", name: String = "w") -> String {
        ["PANE", "$1", window, "\(index)", "1", "0", "0", pane, active ? "1" : "0", command, "/src/\(pane)",
         kind, state, "", "", "", "", "", "", "", "", "", "", "", "", "", title, name].joined(separator: "\t")
    }

    @Test func foldsPanesIntoWindowsKeepingEveryAgent() throws {
        let windows = PaneListing.windows(fromLines: [
            line(window: "@1", index: 0, pane: "%1", active: false, command: "2.1.284", kind: "claude", state: "working"),
            line(window: "@1", index: 0, pane: "%2", active: true, command: "codex", kind: "codex", state: "waiting"),
            line(window: "@2", index: 1, pane: "%3", active: true, command: "zsh", name: "shell\twith tab"),
        ])
        #expect(windows.map(\.id) == ["@1", "@2"])
        let first = try #require(windows.first)
        #expect(first.agents.map(\.id) == ["%1", "%2"])
        #expect(first.agentState == .waiting)           // most urgent pane speaks for the window
        #expect(first.primaryAgent?.kind == .codex)
        #expect(first.currentPath == "/src/%2")         // the active pane's directory
        #expect(windows[1].agents.isEmpty)
        #expect(windows[1].name == "shell\twith tab")   // greedy last field
    }

    @Test func skipsMalformedLines() {
        #expect(PaneListing.windows(fromLines: ["PANE\t$1\t@1", "WIN\tjunk"]).isEmpty)
    }
}

struct AgentHooksMergeTests {
    @Test func mergePreservesForeignHooksAndIsIdempotent() throws {
        let existing = """
        {"model": "opus", "hooks": {"SubagentStart": [{"matcher": "x", "hooks": [{"type": "command", "command": "node inject.mjs"}]}],
         "Stop": [{"hooks": [{"type": "command", "command": "old # belfry-status-v3"}]}]}}
        """
        let once = try #require(AgentHooks.merged(into: existing, target: AgentHooks.claude))
        let twice = try #require(AgentHooks.merged(into: once, target: AgentHooks.claude))
        #expect(once == twice)
        #expect(once.contains("node inject.mjs"))
        #expect(once.contains("\"model\" : \"opus\""))
        #expect(!once.contains("belfry-status-v3"))
        for event in ["PermissionRequest", "PostToolUse", "StopFailure", "SessionEnd"] {
            #expect(once.contains("claude \(event)"))
        }
        let stripped = try #require(AgentHooks.stripped(from: once))
        #expect(!stripped.contains("belfry-status"))
        #expect(stripped.contains("node inject.mjs"))
    }

    @Test func codexCommandsDontChangeAcrossVersions() throws {
        // Codex re-asks for trust when a hook's command text changes.
        let merged = try #require(AgentHooks.merged(into: nil, target: AgentHooks.codex))
        #expect(merged.contains("codex Interrupt"))
        #expect(!merged.contains(AgentHooks.versionedMarker))
    }

    @Test func refusesToClobberInvalidJSON() {
        #expect(AgentHooks.merged(into: "{ not json", target: AgentHooks.claude) == nil)
        #expect(AgentHooks.merged(into: "{\"hooks\": []}", target: AgentHooks.claude) == nil)
    }
}

struct WindowTitleTests {
    private func window(name: String, command: String, path: String = "/Users/rob/code/belfry") -> TmuxWindow {
        var w = TmuxWindow(id: "@1", sessionID: "$1", index: 2, name: name, isActive: true, hasActivity: false)
        w.command = command
        w.currentPath = path
        return w
    }

    @Test func automaticShellNamesBecomeTheFolder() {
        #expect(window(name: "zsh", command: "zsh").title == "belfry")
        #expect(window(name: "zsh", command: "zsh", path: "/Users/rob").title == "~")
        #expect(window(name: "zsh", command: "zsh").titleDetail == "")
        #expect(window(name: "zsh", command: "zsh").symbol == "terminal")
    }

    @Test func programsKeepTheirNameWithTheFolderBeside() {
        let vim = window(name: "nvim", command: "nvim")
        #expect(vim.title == "nvim")
        #expect(vim.titleDetail == "belfry")
        #expect(vim.symbol == "square.and.pencil")
        #expect(window(name: "cargo", command: "cargo").symbol == "hammer")
    }

    @Test func userChosenNamesWin() {
        #expect(window(name: "api server", command: "node").title == "api server")
    }

    @Test func agentsShowTheirTask() throws {
        var w = window(name: "2.1.284", command: "2.1.284")
        let raw = AgentPane.Raw(paneID: "%1", windowID: "@1", sessionID: "$1", isActivePane: true,
                                command: "2.1.284", currentPath: "/x", title: "✳ Fix the login flow",
                                kind: "", state: "", timestamp: "", activity: "", summary: "",
                                name: "", diff: "", legacyClaudeState: "", legacyClaudeTitle: "")
        w.agents = [try #require(AgentPane.detect(raw))]
        #expect(w.title == "belfry")                    // the project leads
        #expect(w.titleDetail == "Fix the login flow")  // the task beside it
        #expect(w.symbol == "sparkle")
    }
}

struct HookVersionTests {
    @Test func readsMarkerVersions() {
        #expect(AgentHooks.markerVersions(in: "a # belfry-status-v3 b # belfry-status-v6 c # belfry-status") == [3, 6, 0])
    }

    @Test func mixedOrOlderHooksNeedReinstallButNewerAreLeftAlone() {
        let v = AgentHooks.version
        let script = "# belfry-status-v\(v)"
        #expect(AgentHooks.isCurrent(claude: "# belfry-status-v\(v)", script: script, claudeInstalled: true))
        #expect(!AgentHooks.isCurrent(claude: "# belfry-status-v3 # belfry-status-v\(v)", script: script, claudeInstalled: true))
        #expect(!AgentHooks.isCurrent(claude: "# belfry-status-v3", script: "# belfry-status-v3", claudeInstalled: true))
        #expect(AgentHooks.isCurrent(claude: "# belfry-status-v\(v + 1)", script: "# belfry-status-v\(v + 1)", claudeInstalled: true))
    }
}

struct LegacyMismatchTests {
    @Test func finishedLegacyStateBeatsStuckWorking() throws {
        let raw = AgentPane.Raw(paneID: "%1", windowID: "@1", sessionID: "$1", isActivePane: true,
                                command: "2.1.286", currentPath: "/x", title: "✳ Task",
                                kind: "claude", state: "working", timestamp: "", activity: "", summary: "",
                                name: "", diff: "", legacyClaudeState: "idle", legacyClaudeTitle: "")
        #expect(AgentPane.detect(raw)?.state == .idle)
    }
}
