import SwiftUI

/// The window title: what the selected window is *doing*, not just where it
/// is. With a coding agent: its braille badge, its task as the title, and what
/// it's doing right now (plus how long, how many steps, how many sub-agents)
/// underneath. Without one: the running command — or, at a shell prompt, the
/// folder — over the tinted host and path. It stays on the session while a
/// web tab is showing: the tab strip names the page, and the header is what
/// tells you which project you're in. Facts that aren't about the task
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
    /// The window's primary agent (nil when there's none to speak of).
    let agent: AgentPane?
    let folderURL: URL?
    /// The room the toolbar has left for it (see `RootView.titleMaxWidth`).
    var maxWidth: CGFloat = 520

    var body: some View {
        HStack(spacing: 9) {
            leading
            VStack(alignment: .leading, spacing: HeaderMetrics.lineGap) {
                title
                    .font(HeaderMetrics.titleFont)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(height: HeaderMetrics.firstLine)
                subtitle
                    .font(HeaderMetrics.secondFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    // Activities and paths keep their ends: the file being
                    // edited, the folder you're in.
                    .truncationMode(.middle)
                    .frame(height: HeaderMetrics.secondLine)
            }
        }
        .modifier(WidthCap(max: min(520, maxWidth)))
        .fixedSize(horizontal: false, vertical: true)
        // The toolbar sets the item hard against the sidebar's edge; this
        // lines the badge up with the tab track below it.
        .padding(.leading, HeaderMetrics.leadingInset)
        .hoverHint((readout ?? staleReadout)?.hint ?? "")
        .accessibilityElement(children: .combine)
    }

    // MARK: Leading glyph

    @ViewBuilder private var leading: some View {
        if let agent {
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
        if let agent {
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
    /// nothing — the folder you're in. A bare "~" or "/" names nothing (the
    /// subtitle already shows the path), so those fall back to the window's
    /// own name.
    static func plainTitle(window: TmuxWindow, fallback: String) -> String {
        let command = window.command
        if !command.isEmpty, !AgentPane.shells.contains(command) { return command }
        let folder = window.folder
        return folder.isEmpty || folder == "~" || folder == "/" ? fallback : folder
    }

    // MARK: Subtitle

    @ViewBuilder private var subtitle: some View {
        if let agent {
            // The activity has first claim on the line; the progress after it
            // sheds its parts (steps and agents, then the clock) as room runs
            // out, rather than shoving the activity off the line.
            HStack(spacing: 0) {
                SettledText(value: Self.activity(agent), mode: .throttle(.milliseconds(1500)))
                    .foregroundStyle(Self.activityStyle(agent))
                    .id(window?.id)
                    .layoutPriority(1)
                ViewThatFits(in: .horizontal) {
                    AgentProgressText(agent: agent, detail: .full)
                    AgentProgressText(agent: agent, detail: .elapsed)
                    Color.clear.frame(width: 0, height: 0)
                }
            }
        } else if let readout {
            readout.secondaryText
        } else if let staleReadout {
            staleReadout.secondaryText + Text(" — \(staleWord)")
        }
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
    enum Detail { case full, elapsed }

    let agent: AgentPane
    let detail: Detail

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
        if detail == .full, agent.state.isBusy {
            if agent.steps > 0 { parts.append("\(agent.steps) step\(agent.steps == 1 ? "" : "s")") }
            if agent.subagents > 0, agent.state == .working {
                parts.append("\(agent.subagents) agent\(agent.subagents == 1 ? "" : "s")")
            }
        }
        return Text(parts.map { " · \($0)" }.joined()).monospacedDigit()
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

/// One vertical rhythm for everything in the header: the title and the facts
/// beside it are separate toolbar items, each centred on its own, so their two
/// lines only share baselines if every first line and every second line is
/// the same height in both.
enum HeaderMetrics {
    static let titleFont = Font.system(size: 13, weight: .semibold)
    static let secondFont = Font.system(size: 11)
    static let firstLine: CGFloat = 16
    static let secondLine: CGFloat = 14
    static let lineGap: CGFloat = 2
    /// Added to the toolbar's own few points so the leading glyph starts
    /// where the tab track does (it's inset 10pt from the column's edge).
    static let leadingInset: CGFloat = 6
}

/// The facts that aren't the task, set apart from the title as two small
/// two-line columns whose lines sit level with its two: where the code is
/// (branch, then what's changed and how it sits against upstream) and, with
/// an agent, what it's running on (model and effort, then context in use and
/// permission mode). The window decides how much fits — see `HeaderLayout` —
/// and the branch is the one thing that stays at every width.
struct HeaderFacts: View {
    let git: GitOverview?
    let agent: AgentPane?
    let layout: HeaderLayout

    /// The repo's branch, else the one the agent's hooks reported.
    static func branch(git: GitOverview?, agent: AgentPane?) -> String? {
        if let branch = git?.branch, !branch.isEmpty { return branch }
        if let branch = agent?.branch, !branch.isEmpty, branch != "HEAD" { return branch }
        return nil
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let branch = Self.branch(git: git, agent: agent) {
                gitColumn(branch)
            }
            if layout.showsAgentColumn, let agent, Self.hasAgentFacts(agent) {
                Rectangle()
                    .fill(.separator)
                    .frame(width: 1, height: HeaderMetrics.firstLine + HeaderMetrics.secondLine)
                agentColumn(agent)
            }
        }
        .padding(.horizontal, 4)
    }

    static func hasAgentFacts(_ agent: AgentPane) -> Bool {
        !agent.model.isEmpty || (agent.contextTokens ?? 0) > 0 || ModeStyle(agent.mode) != nil
    }

    private func gitColumn(_ branch: String) -> some View {
        VStack(alignment: .leading, spacing: HeaderMetrics.lineGap) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                // Middle truncation keeps both a prefix like "rob/" and the
                // distinguishing tail of a long branch name.
                Text(branch)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .modifier(WidthCap(max: layout.branchMaxWidth))
            }
            .frame(height: HeaderMetrics.firstLine)
            changesLine
                .frame(height: HeaderMetrics.secondLine)
        }
        .hoverHint(branchHint(branch))
    }

    private func agentColumn(_ agent: AgentPane) -> some View {
        VStack(alignment: .leading, spacing: HeaderMetrics.lineGap) {
            Text(ModelName.short(agent.model) + (agent.effort.isEmpty ? "" : " · \(agent.effort)"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize()
                .frame(height: HeaderMetrics.firstLine)
            HStack(spacing: 7) {
                if let tokens = agent.contextTokens, tokens > 0 {
                    ContextMeter(tokens: tokens, model: agent.model)
                }
                if let mode = ModeStyle(agent.mode) {
                    Text(mode.label)
                        .foregroundStyle(mode.color)
                        .fixedSize()
                }
            }
            .font(HeaderMetrics.secondFont)
            .frame(height: HeaderMetrics.secondLine)
        }
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
        .font(HeaderMetrics.secondFont.monospacedDigit())
        .foregroundStyle(.secondary)
        .fixedSize()
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
                .frame(width: 28, height: 4)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(fraction > 0.8 ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                        .frame(width: max(3, 28 * fraction), height: 4)
                }
            // Fixed: a toolbar item can be offered less than its ideal width,
            // and "84k" squeezed to "…" says nothing at all.
            Text(AgentRow.compact(tokens))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .fixedSize()
        .hoverHint("\(tokens.formatted()) tokens of context in use (of \(AgentRow.compact(capacity)))")
    }
}

/// Offers its content at most `max` points, even under an ideal-size
/// proposal (which a toolbar item gets) — so a long branch truncates at the
/// cap instead of pushing everything else out of the toolbar.
private struct WidthCap: ViewModifier {
    let max: CGFloat
    func body(content: Content) -> some View {
        CapLayout(max: max) { content }
    }

    private struct CapLayout: Layout {
        let max: CGFloat
        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            guard let child = subviews.first else { return .zero }
            let width = Swift.min(proposal.width ?? max, max)
            return child.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
        }
        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        }
    }
}

/// How much of the header fits the detail column: the facts need room beside
/// the title and the toolbar buttons, so the agent's column drops out first,
/// then the branch's cap tightens. The branch itself never goes.
enum HeaderLayout: Equatable {
    case full, git, compact

    init(width: CGFloat) {
        switch width {
        case 900...: self = .full
        case 700...: self = .git
        default: self = .compact
        }
    }

    var showsAgentColumn: Bool { self == .full }
    var branchMaxWidth: CGFloat { self == .compact ? 120 : 200 }
}

/// Belfry's mark for toolbar use: the full braille cell ⣿ every agent badge
/// is drawn from, as a template image sized like an SF Symbol, so the toolbar
/// tints and spaces it like the buttons around it.
enum BrailleMark {
    static let toolbarImage: NSImage = {
        let size = NSSize(width: 16, height: 18)
        let image = NSImage(size: size, flipped: true) { _ in
            let dot: CGFloat = 3.2, pitch: CGFloat = 4.4
            let originX = (size.width - (dot + pitch)) / 2
            let originY = (size.height - (dot + 3 * pitch)) / 2
            NSColor.black.setFill()
            for column in 0..<2 {
                for row in 0..<4 {
                    NSBezierPath(ovalIn: NSRect(x: originX + CGFloat(column) * pitch,
                                                y: originY + CGFloat(row) * pitch,
                                                width: dot, height: dot)).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Agents"
        return image
    }()
}
