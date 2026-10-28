import SwiftUI

/// The window title: what the selected window is *doing*, not just where it
/// is. With a coding agent: its braille badge, its task as the title, and what
/// it's doing right now (plus how long, how many steps, how many sub-agents)
/// underneath. Without one: the running command — or, at a shell prompt, the
/// folder — over the tinted host and path. Facts that aren't about the task
/// (branch, diff, model, context) sit apart in `HeaderFacts`.
///
/// The task and activity texts are hook-reported and can change many times a
/// second mid-turn, so both go through `SettledText`: the task only once it's
/// held still, the activity at most every so often — a title that flickers
/// reads as broken, not live.
struct HeaderTitle: View {
    let readout: WindowReadout?
    /// Shown while the selected window's host reconnects.
    let staleReadout: WindowReadout?
    let staleWord: String
    let window: TmuxWindow?
    let webTab: BrowserTab?
    let folderURL: URL?
    /// The branch, when the window is too narrow for `HeaderFacts` — it's the
    /// one fact worth keeping at any width.
    let inlineBranch: String?

    private var agent: AgentPane? {
        guard let agent = window?.primaryAgent, agent.state != .none else { return nil }
        return agent
    }

    var body: some View {
        HStack(spacing: 9) {
            leading
            VStack(alignment: .leading, spacing: 1) {
                title
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                subtitle
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .hoverHint((readout ?? staleReadout)?.hint ?? "")
        .accessibilityElement(children: .combine)
    }

    // MARK: Leading glyph

    @ViewBuilder private var leading: some View {
        if webTab != nil {
            Image(systemName: "globe")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        } else if let agent {
            AgentBadge(state: agent.state, kind: agent.kind, title: agent.name,
                       unseen: agent.finishedUnseen, glyphPointSize: 19)
        } else if let folderURL {
            Image(nsImage: NSWorkspace.shared.icon(forFile: folderURL.path))
                .resizable()
                .frame(width: 18, height: 18)
                .onDrag { NSItemProvider(object: folderURL as NSURL) }
                .hoverHint("Working directory — drag to copy the folder")
        } else if readout != nil || staleReadout != nil {
            Image(systemName: "apple.terminal")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Title

    @ViewBuilder private var title: some View {
        if let webTab {
            Text(webTab.displayTitle)
        } else if let agent {
            SettledText(value: agent.task.isEmpty ? agent.kind.displayName : agent.task,
                        mode: .settle(.seconds(2)))
                .id(window?.id)
        } else if let window, readout != nil {
            Text(Self.plainTitle(window: window, fallback: readout?.primary ?? ""))
        } else {
            Text(staleReadout?.primary ?? "Belfry")
        }
    }

    /// The foreground command, or — at a shell prompt, where the command says
    /// nothing — the folder you're in.
    static func plainTitle(window: TmuxWindow, fallback: String) -> String {
        let command = window.command
        if !command.isEmpty, !AgentPane.shells.contains(command) { return command }
        return window.folder.isEmpty ? fallback : window.folder
    }

    // MARK: Subtitle

    @ViewBuilder private var subtitle: some View {
        if let webTab {
            if let url = webTab.url { Text(url.absoluteString) }
        } else if let agent {
            HStack(spacing: 0) {
                SettledText(value: Self.activity(agent), mode: .throttle(.milliseconds(1500)))
                    .foregroundStyle(Self.activityStyle(agent))
                    .id(window?.id)
                AgentProgressText(agent: agent, branch: inlineBranch)
            }
        } else if let readout {
            readout.secondaryText + branchSuffix
        } else if let staleReadout {
            staleReadout.secondaryText + Text(" — \(staleWord)")
        }
    }

    private var branchSuffix: Text {
        guard let inlineBranch else { return Text("") }
        return Text(" · \(Image(systemName: "arrow.triangle.branch")) \(inlineBranch)")
    }

    /// What it's doing now, in the words the hooks reported — or the state,
    /// when they reported nothing more specific.
    static func activity(_ agent: AgentPane) -> String {
        switch agent.state {
        case .waiting: return agent.activity.isEmpty ? "Waiting for you" : agent.activity
        case .error: return agent.activity.isEmpty ? "Stopped on an error" : agent.activity
        case .working: return agent.activity.isEmpty ? "Working" : agent.activity
        case .background:
            return agent.subagents > 0
                ? "\(agent.subagents) sub-agent\(agent.subagents == 1 ? "" : "s") still running"
                : "Background tasks running"
        case .idle: return agent.finishedUnseen ? "Finished" : "Idle"
        case .running, .none: return "\(agent.kind.displayName) is running"
        }
    }

    private static func activityStyle(_ agent: AgentPane) -> AnyShapeStyle {
        switch agent.state {
        case .waiting: return AnyShapeStyle(Color.orange)
        case .error: return AnyShapeStyle(AppTheme.statusBad)
        case .idle where agent.finishedUnseen: return AnyShapeStyle(AppTheme.statusGood)
        case .working, .background: return AnyShapeStyle(.primary.opacity(0.85))
        default: return AnyShapeStyle(.secondary)
        }
    }
}

/// "· 2m 14s · 23 steps · 2 agents" after the activity: how long it's been in
/// this state and the size of the job. Ticks once a second only while there's
/// a clock worth watching (busy or waiting); otherwise it's static.
private struct AgentProgressText: View {
    let agent: AgentPane
    let branch: String?

    var body: some View {
        if let since = agent.since, agent.state.isBusy || agent.state.needsAttention {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                line(elapsed: context.date.timeIntervalSince(since))
            }
        } else {
            line(elapsed: nil)
        }
    }

    private func line(elapsed: TimeInterval?) -> Text {
        var parts: [String] = []
        if let elapsed { parts.append(Self.format(elapsed)) }
        if agent.state.isBusy {
            if agent.steps > 0 { parts.append("\(agent.steps) step\(agent.steps == 1 ? "" : "s")") }
            if agent.subagents > 0, agent.state == .working {
                parts.append("\(agent.subagents) agent\(agent.subagents == 1 ? "" : "s")")
            }
        }
        var text = Text(parts.map { " · \($0)" }.joined()).monospacedDigit()
        if let branch {
            text = text + Text(" · \(Image(systemName: "arrow.triangle.branch")) \(branch)")
        }
        return text
    }

    /// 14 → "14s", 134 → "2m 14s", 3780 → "1h 3m".
    static func format(_ interval: TimeInterval) -> String {
        let s = max(0, Int(interval))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }
}

/// Text that doesn't flicker. `.settle` shows a new value only once it has
/// held still that long (for the task, which churns while a turn starts up);
/// `.throttle` shows the latest value at most once per interval (for the
/// activity, which can change faster than anyone can read it). Either way the
/// first value shows at once, and changes crossfade.
struct SettledText: View {
    enum Mode: Equatable {
        case settle(Duration)
        case throttle(Duration)
    }

    let value: String
    let mode: Mode
    @State private var shown: String?
    @State private var lastSwap = ContinuousClock.now
    @State private var pending: Task<Void, Never>?

    var body: some View {
        Text(shown ?? value)
            .contentTransition(.opacity)
            .onChange(of: value) { _, new in schedule(new) }
            .onDisappear { pending?.cancel() }
    }

    private func schedule(_ new: String) {
        pending?.cancel()
        let delay: Duration
        switch mode {
        case .settle(let quiet):
            delay = quiet
        case .throttle(let interval):
            let since = ContinuousClock.now - lastSwap
            delay = since >= interval ? .zero : interval - since
        }
        pending = Task { @MainActor in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            withAnimation(.easeInOut(duration: 0.2)) { shown = new }
            lastSwap = .now
        }
    }
}

/// The facts that aren't the task, set apart from the title as two small
/// two-line columns that line up with it: where the code is (branch, then
/// what's changed and how it sits against upstream) and, with an agent, what
/// it's running on (model and effort, then context in use and permission
/// mode). The window decides how many columns fit — see `HeaderLayout`.
struct HeaderFacts: View {
    let git: GitOverview?
    let agent: AgentPane?
    let showsAgentColumn: Bool

    /// The repo's branch, else the one the agent's hooks reported.
    static func branch(git: GitOverview?, agent: AgentPane?) -> String? {
        if let branch = git?.branch, !branch.isEmpty { return branch }
        if let branch = agent?.branch, !branch.isEmpty, branch != "HEAD" { return branch }
        return nil
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let branch = Self.branch(git: git, agent: agent) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(branch)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    changesLine
                }
                .frame(maxWidth: 220, alignment: .leading)
                .hoverHint(branchHint(branch))
            }
            if showsAgentColumn, let agent, Self.hasAgentFacts(agent) {
                Divider().frame(height: 26)
                VStack(alignment: .leading, spacing: 2) {
                    if !agent.model.isEmpty {
                        Text(ModelName.short(agent.model)
                             + (agent.effort.isEmpty ? "" : " · \(agent.effort)"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        if let tokens = agent.contextTokens, tokens > 0 {
                            ContextMeter(tokens: tokens, model: agent.model)
                        }
                        if let mode = ModeStyle(agent.mode) {
                            Text(mode.label)
                                .font(.system(size: 10.5))
                                .foregroundStyle(mode.color)
                        }
                    }
                }
            }
        }
        .fixedSize()
    }

    static func hasAgentFacts(_ agent: AgentPane) -> Bool {
        !agent.model.isEmpty || (agent.contextTokens ?? 0) > 0 || ModeStyle(agent.mode) != nil
    }

    /// "+14 −22 · ↑2 ↓1" — the agent's diff when it reported one, else how many
    /// files git sees changed; then divergence from upstream.
    @ViewBuilder private var changesLine: some View {
        let ahead = git?.ahead ?? 0, behind = git?.behind ?? 0
        let changed = git?.entries.count ?? 0
        HStack(spacing: 6) {
            if let diff = agent?.diff, !diff.isEmpty {
                DiffStatText(diff: diff)
            } else if changed > 0 {
                Text("\(changed) changed")
            } else if git != nil {
                Text("clean")
            }
            if ahead > 0 || behind > 0 {
                Text([ahead > 0 ? "↑\(ahead)" : nil, behind > 0 ? "↓\(behind)" : nil]
                    .compactMap { $0 }.joined(separator: " "))
            }
        }
        .font(.system(size: 10.5).monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private func branchHint(_ branch: String) -> String {
        var lines = ["Branch \(branch)"]
        if let git {
            if git.ahead > 0 { lines.append("\(git.ahead) commit\(git.ahead == 1 ? "" : "s") ahead of upstream") }
            if git.behind > 0 { lines.append("\(git.behind) commit\(git.behind == 1 ? "" : "s") behind upstream") }
            lines.append(git.entries.isEmpty ? "Working tree clean"
                         : "\(git.entries.count) file\(git.entries.count == 1 ? "" : "s") changed")
        }
        return lines.joined(separator: "\n")
    }
}

/// Context in use as a short bar plus "84k", tinted orange past 80% of the
/// model's window (1M for the long-context variants, else 200k).
private struct ContextMeter: View {
    let tokens: Int
    let model: String

    private var capacity: Int { model.lowercased().hasSuffix("1m") ? 1_000_000 : 200_000 }
    private var fraction: Double { min(1, Double(tokens) / Double(capacity)) }

    var body: some View {
        HStack(spacing: 5) {
            Capsule()
                .fill(.quaternary)
                .frame(width: 30, height: 4)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(fraction > 0.8 ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                        .frame(width: max(3, 30 * fraction), height: 4)
                }
            Text(AgentRow.compact(tokens))
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .hoverHint("\(tokens.formatted()) tokens of context in use (of \(AgentRow.compact(capacity)))")
    }
}

/// How much of the header fits the window: the facts need room beside the
/// title and the toolbar buttons, so they drop out column by column as the
/// window narrows, and the branch moves into the subtitle rather than vanish.
enum HeaderLayout: Equatable {
    case full, gitOnly, compact

    init(width: CGFloat) {
        switch width {
        case 1000...: self = .full
        case 760...: self = .gitOnly
        default: self = .compact
        }
    }

    var showsFacts: Bool { self != .compact }
    var showsAgentColumn: Bool { self == .full }
}
