import Foundation
import Testing
@testable import Belfry

/// The window title's choices: what it names, what it says the agent is
/// doing, which branch it shows, and how much fits at a given width.
struct HeaderTitleTests {
    private func agent(state: String, activity: String = "", branch: String = "",
                       subagents: String = "") throws -> AgentPane {
        try #require(AgentPane.detect(AgentPane.Raw(
            paneID: "%1", windowID: "@1", sessionID: "$1", isActivePane: true,
            command: "2.1.284", currentPath: "/src", title: "hailmary",
            kind: "claude", state: state, timestamp: "1790636829", activity: activity,
            summary: "fix the build", name: "", diff: "",
            subagents: subagents, branch: branch,
            legacyClaudeState: "", legacyClaudeTitle: "")))
    }

    private func window(command: String, path: String) -> TmuxWindow {
        var w = TmuxWindow(id: "@1", sessionID: "$1", index: 1, name: "zsh", isActive: true, hasActivity: false)
        w.command = command
        w.currentPath = path
        return w
    }

    @Test func plainTitleIsTheCommandOrTheFolderAtAPrompt() {
        #expect(HeaderTitle.plainTitle(window: window(command: "nvim", path: "/src/belfry"), fallback: "x") == "nvim")
        #expect(HeaderTitle.plainTitle(window: window(command: "zsh", path: "/src/belfry"), fallback: "x") == "belfry")
        #expect(HeaderTitle.plainTitle(window: window(command: "-bash", path: ""), fallback: "main · zsh") == "main · zsh")
    }

    @Test func activityFallsBackToTheStateInWords() throws {
        #expect(HeaderTitle.activity(try agent(state: "working", activity: "Edit Foo.swift")) == "Edit Foo.swift")
        #expect(HeaderTitle.activity(try agent(state: "working")) == "Working")
        #expect(HeaderTitle.activity(try agent(state: "waiting")) == "Waiting for you")
        #expect(HeaderTitle.activity(try agent(state: "background", subagents: "2")) == "2 sub-agents still running")
    }

    @Test func branchPrefersGitThenTheAgentsReport() throws {
        let git = GitOverview(root: "/src", branch: "main", ahead: 0, behind: 0, entries: [])
        let claude = try agent(state: "working", branch: "feature")
        #expect(HeaderFacts.branch(git: git, agent: claude) == "main")
        #expect(HeaderFacts.branch(git: nil, agent: claude) == "feature")
        #expect(HeaderFacts.branch(git: nil, agent: try agent(state: "working", branch: "HEAD")) == nil)
    }

    @Test func factsDropOutAsTheWindowNarrows() {
        #expect(HeaderLayout(width: 1200) == .full)
        #expect(HeaderLayout(width: 800) == .gitOnly)
        #expect(HeaderLayout(width: 600) == .compact)
        #expect(!HeaderLayout.compact.showsFacts)
        #expect(HeaderLayout.gitOnly.showsFacts && !HeaderLayout.gitOnly.showsAgentColumn)
    }
}
