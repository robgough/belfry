import SwiftUI

/// A coding agent joined with where it lives, for the sidebar's Agents section.
struct AgentEntry: Identifiable {
    let host: HostModel
    let session: TmuxSession
    let window: TmuxWindow
    let agent: AgentPane

    /// Pane ids are only unique per tmux server, so qualify with the host.
    var id: String { "\(host.id)|\(agent.id)" }
    var selection: WindowSelection { WindowSelection(hostID: host.id, windowID: window.id) }

    /// Every agent on every connected host, most in need of you first: waiting
    /// or errored, then finished-but-unseen, working, background, idle, and
    /// finally agents we can only see (no hooks). Within a group, the most
    /// recently changed first.
    @MainActor
    static func collect(from hosts: [HostModel]) -> [AgentEntry] {
        var entries: [AgentEntry] = []
        for host in hosts where host.store.status.isLive {
            for session in host.store.sessions {
                for window in session.windows {
                    for agent in window.agents {
                        entries.append(AgentEntry(host: host, session: session, window: window, agent: agent))
                    }
                }
            }
        }
        return entries.sorted { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            let aSince = a.agent.since ?? .distantPast, bSince = b.agent.since ?? .distantPast
            if aSince != bSince { return aSince > bSince }
            return a.id < b.id
        }
    }

    private var rank: Int {
        switch agent.state {
        case .waiting, .error: 0
        case .idle where agent.finishedUnseen: 1
        case .working: 2
        case .background: 3
        case .idle: 4
        case .running, .none: 5
        }
    }
}

/// Header band for the Agents section — the Pinned header's treatment, plus a
/// one-glance summary ("2 need you", "3 working") and a collapse toggle.
struct AgentsSectionHeader: View {
    let entries: [AgentEntry]
    @Binding var isExpanded: Bool

    var body: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(AppTheme.accent.opacity(0.16))
                .frame(width: 18, height: 18)
                .overlay(
                    Image(systemName: "sparkles")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
                )
            Text("Agents")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .textCase(nil)
            Spacer(minLength: 0)
            summary
                .font(.system(size: 10.5, weight: .medium))
                .textCase(nil)
                // Leave room for the sidebar section's hover disclosure chevron.
                .padding(.trailing, 16)
        }
        .padding(.vertical, 6)
        .background(AppTheme.sidebarPanel.padding(.horizontal, -48))
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { isExpanded.toggle() }
    }

    @ViewBuilder private var summary: some View {
        let attention = entries.filter { $0.agent.state.needsAttention }.count
        let busy = entries.filter { $0.agent.state.isBusy }.count
        let done = entries.filter { $0.agent.finishedUnseen }.count
        if attention > 0 {
            Text("\(attention) need\(attention == 1 ? "s" : "") you").foregroundStyle(.orange)
        } else if done > 0 {
            Text("\(done) finished").foregroundStyle(AppTheme.statusGood)
        } else if busy > 0 {
            Text("\(busy) working").foregroundStyle(.secondary)
        } else {
            Text("\(entries.count)").foregroundStyle(.secondary)
        }
    }
}

/// One agent: what it's on (task summary), which harness and where it runs,
/// what it's doing this moment, how much it has changed, and for how long it
/// has been in its current state.
struct AgentRow: View {
    let entry: AgentEntry

    private var agent: AgentPane { entry.agent }

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            AgentBadge(state: agent.state, kind: agent.kind, title: agent.name, unseen: agent.finishedUnseen)
                .frame(width: 16, height: 17)
            VStack(alignment: .leading, spacing: 1.5) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 13, weight: agent.finishedUnseen || agent.state.needsAttention
                                      ? .semibold : .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .hoverHint(title)
                    Spacer(minLength: 0)
                    if let diff = agent.diff, !diff.isEmpty {
                        DiffStatText(diff: diff)
                    }
                }
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    contextText
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .hoverHint(contextHint)
                    Spacer(minLength: 0)
                    if let since = agent.since {
                        ElapsedText(since: since)
                    }
                }
                if let line = activityLine {
                    Text(line.text)
                        .foregroundStyle(line.color)
                        .font(.system(size: 10.5))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .hoverHint(line.text)
                }
                if let meta = metaText {
                    meta
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if agent.state.isBusy || agent.state == .waiting {
                    ForEach(Array(agent.tasks.prefix(Self.maxTasks).enumerated()), id: \.offset) { _, task in
                        SubagentLine(task: task)
                    }
                    if agent.tasks.count > Self.maxTasks {
                        Text("+\(agent.tasks.count - Self.maxTasks) more")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 12)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// The task, in order of preference: its summary, the agent's session
    /// name, the window's name, the working directory's last component.
    private var title: String {
        if !agent.summary.isEmpty { return agent.summary }
        if !agent.name.isEmpty { return agent.name }
        if !entry.window.name.isEmpty { return entry.window.name }
        let dir = (agent.currentPath as NSString).lastPathComponent
        return dir.isEmpty ? agent.kind.displayName : dir
    }

    /// Where the agent is: its working directory's folder (the part that tells
    /// agents apart, so it leads, in the primary colour), then the tmux session
    /// it lives in — plus the branch, the machine when it's remote, and the
    /// harness when it isn't Claude. "belfry-agent-status ⎇ main · belfry".
    private var contextText: Text {
        var text = Text(folder).fontWeight(.semibold).foregroundStyle(.primary)
        if !agent.branch.isEmpty, agent.branch != "HEAD" {
            text = text + Text(" \(Image(systemName: "arrow.triangle.branch")) \(agent.branch)")
        }
        text = text + Text(" · \(entry.session.name)")
        if !entry.host.transport.isLocal {
            text = text + Text(" · ")
                + Text(entry.host.displayName).foregroundStyle(AppTheme.hostTint(isLocal: false))
        }
        if agent.kind != .claude {
            text = text + Text(" · \(agent.kind.displayName)")
        }
        return text
    }

    /// The working directory's last component ("~" for home, "/" for root).
    private var folder: String {
        let path = agent.currentPath.isEmpty ? entry.window.currentPath : agent.currentPath
        guard !path.isEmpty else { return "?" }
        let abbreviated = abbreviateHomePath(path)
        if abbreviated == "~" || abbreviated == "/" { return abbreviated }
        return (path as NSString).lastPathComponent
    }

    /// Full detail on hover: agent + session name, host, path, tmux location.
    private var contextHint: String {
        var lines = [agent.kind.displayName + (agent.name.isEmpty ? "" : " session “\(agent.name)”")]
        lines.append("\(entry.host.displayName) · tmux \(entry.session.name):\(entry.window.index)")
        let path = agent.currentPath.isEmpty ? entry.window.currentPath : agent.currentPath
        if !path.isEmpty { lines.append(path) }
        return lines.joined(separator: "\n")
    }

    private static let maxTasks = 3

    /// Claude Code's status-line facts, compactly: permission mode (tinted as
    /// Claude tints it), context in use, and — while busy — sub-agents running
    /// and tool steps this turn. "▸▸ auto · 88k context · 2 agents · 14 steps".
    private var metaText: Text? {
        var parts: [Text] = []
        if let mode = ModeStyle(agent.mode) {
            parts.append(Text(mode.label).foregroundStyle(mode.color))
        }
        if let tokens = agent.contextTokens, tokens > 0 {
            parts.append(Text("\(Self.compact(tokens)) context"))
        }
        if agent.state.isBusy || agent.state == .waiting {
            if agent.subagents > 0 {
                parts.append(Text("\(agent.subagents) agent\(agent.subagents == 1 ? "" : "s")"))
            }
            if agent.steps > 0 {
                parts.append(Text("\(agent.steps) step\(agent.steps == 1 ? "" : "s")"))
            }
        }
        guard var text = parts.first else { return nil }
        for part in parts.dropFirst() { text = text + Text(" · ") + part }
        return text.foregroundStyle(.tertiary)
    }

    /// 88012 → "88k", 1_200_000 → "1.2M".
    static func compact(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return "\(n / 1_000)k" }
        return "\(n)"
    }

    /// The live line under the row — only when there's something to say.
    private var activityLine: (text: String, color: Color)? {
        switch agent.state {
        case .waiting:
            return (agent.activity.isEmpty ? "Waiting for you" : agent.activity, Color.orange)
        case .error:
            return (agent.activity.isEmpty ? "Stopped on an error" : agent.activity, AppTheme.statusBad)
        case .working, .background:
            if agent.activity.isEmpty && agent.steps == 0 && agent.subagents == 0 { return nil }
            return (agent.activity.isEmpty ? "Working" : agent.activity, Color.secondary)
        case .idle where agent.finishedUnseen:
            return ("Finished", AppTheme.statusGood)
        case .idle, .running, .none:
            return nil
        }
    }
}

/// "+84 −12" — uncommitted insertions/deletions in the agent's working tree.
private struct DiffStatText: View {
    let diff: DiffStat
    var body: some View {
        (Text("+\(diff.added)").foregroundStyle(AppTheme.statusGood)
         + Text(" −\(diff.removed)").foregroundStyle(AppTheme.statusBad))
            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
            .hoverHint("Uncommitted: \(diff.added) added, \(diff.removed) removed across "
                       + "\(diff.files) file\(diff.files == 1 ? "" : "s")")
    }
}

/// How long the agent has been in its current state ("now", "4m", "2h", "3d"),
/// refreshed on a slow timeline — a per-second tick across a dozen rows would
/// cost far more than it tells you.
private struct ElapsedText: View {
    let since: Date
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(Self.format(context.date.timeIntervalSince(since)))
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .hoverHint("In this state since \(since.formatted(date: .omitted, time: .shortened))")
    }

    static func format(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86_400: return "\(seconds / 3600)h"
        default: return "\(seconds / 86_400)d"
        }
    }
}

/// How a permission mode reads in the meta line (default mode shows nothing).
private struct ModeStyle {
    let label: String
    let color: Color

    init?(_ mode: String) {
        switch mode {
        case "auto": label = "▸▸ auto"; color = .yellow
        case "acceptEdits": label = "▸▸ accept edits"; color = .purple
        case "plan": label = "⏸ plan"; color = .teal
        case "bypassPermissions": label = "▸▸ bypass"; color = AppTheme.statusBad
        case "", "default": return nil
        default: label = mode; color = .secondary
        }
    }
}

/// One running sub-agent under its parent's row: "○ general-purpose  Verifying
/// final release build state", as Claude Code lists them.
private struct SubagentLine: View {
    let task: String

    var body: some View {
        let parts = task.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        let type = parts.count == 2 ? parts[0] : ""
        let description = parts.count == 2 ? parts[1] : task
        (Text("○ ").foregroundStyle(.tertiary)
         + Text(type.isEmpty ? "" : type + "  ").foregroundStyle(.secondary)
         + Text(description).foregroundStyle(.primary.opacity(0.8)))
            .font(.system(size: 10.5))
            .lineLimit(1)
            .truncationMode(.tail)
            .hoverHint(task)
    }
}
