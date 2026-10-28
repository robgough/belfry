#if DEBUG
import Foundation

/// Staged header states for screenshots and design review, so every agent
/// state can be seen without a real agent running (and without touching tmux).
///   BELFRY_DEMO_AGENT=working|waiting|background|idle|error
///   BELFRY_DEMO_GIT=1   a sample repo overview (branch, changes, divergence)
enum HeaderDemo {
    static var agent: AgentPane? {
        guard let state = ProcessInfo.processInfo.environment["BELFRY_DEMO_AGENT"] else { return nil }
        let since = Int(Date().timeIntervalSince1970) - 134
        let activity: String
        switch state {
        case "waiting": activity = "Approve Bash: swift test"
        case "error": activity = "API error: overloaded"
        default: activity = "Edit Sources/Belfry/BelfryApp.swift"
        }
        var pane = AgentPane.detect(AgentPane.Raw(
            paneID: "%demo", windowID: "@demo", sessionID: "$demo", isActivePane: true,
            command: "2.1.312", currentPath: NSHomeDirectory() + "/code/belfry", title: "✳ Rebuild the window header toolbar",
            kind: "claude", state: state, timestamp: "\(since)", activity: activity,
            summary: "Rebuild the window header toolbar", name: "belfry-header",
            diff: "14 22 3", steps: "23", subagents: state == "background" ? "3" : "2",
            mode: "auto", branch: "header-redesign", context: "84000",
            model: "claude-opus-5-5", effort: "high",
            legacyClaudeState: "", legacyClaudeTitle: ""))
        if state == "idle" { pane?.finishedUnseen = true }
        return pane
    }

    static var git: GitOverview? {
        guard ProcessInfo.processInfo.environment["BELFRY_DEMO_GIT"] != nil else { return nil }
        return GitOverview(
            root: NSHomeDirectory() + "/code/belfry", branch: "header-redesign", ahead: 2, behind: 0,
            entries: [GitStatusEntry(code: " M", path: "Sources/Belfry/BelfryApp.swift", renamedFrom: nil),
                      GitStatusEntry(code: " M", path: "Sources/Belfry/HeaderTitle.swift", renamedFrom: nil),
                      GitStatusEntry(code: "??", path: "Sources/Belfry/HeaderDemo.swift", renamedFrom: nil)])
    }
}
#endif
