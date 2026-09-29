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
