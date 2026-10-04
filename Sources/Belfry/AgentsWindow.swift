import SwiftUI

/// One row of the Agents table: an agent, or one of its running sub-agents
/// (a child row under it). Everything is flattened to sortable values and
/// rebuilt from the live stores on every render, so the table follows the
/// agents as they work.
struct AgentTableRow: Identifiable {
    let id: String
    let entry: AgentEntry
    var agent: AgentPane { entry.agent }
    /// Set on a sub-agent row.
    let subagent: Subagent?
    let children: [AgentTableRow]

    /// Lane order: needs you, just finished, working, quiet.
    let rank: Int
    let task: String
    let activity: String
    let since: Date

    @MainActor
    init(_ entry: AgentEntry) {
        id = entry.id
        self.entry = entry
        subagent = nil
        let agent = entry.agent
        rank = AgentLane.allCases.firstIndex(of: AgentLane.of(agent)) ?? 0
        task = !agent.summary.isEmpty ? agent.summary : (!agent.name.isEmpty ? agent.name : entry.window.title)
        activity = agent.activity
        since = agent.since ?? .distantPast
        // A finished agent's leftover list is stale, so only a live one has children.
        let live = agent.state.isBusy || agent.state == .waiting
        children = live ? agent.tasks.enumerated().map { AgentTableRow(subagent: $1, index: $0, of: entry) } : []
    }

    /// A sub-agent row, sharing its parent's sort keys so it stays under it.
    @MainActor
    private init(subagent: Subagent, index: Int, of entry: AgentEntry) {
        id = "\(entry.id)#\(index)"
        self.entry = entry
        self.subagent = subagent
        children = []
        rank = AgentLane.allCases.firstIndex(of: AgentLane.of(entry.agent)) ?? 0
        task = subagent.title
        activity = ""
        since = entry.agent.since ?? .distantPast
    }
}

/// The Agents window: every agent on every host in a native, sortable table,
/// with each agent's running sub-agents folded underneath it. Five columns —
/// who and where, what it's doing, model, its numbers, time in state — so it fits
/// without scrolling sideways. Double-click (or Return) a row to jump the
/// main window to that agent.
struct AgentsTableView: View {
    let model: AppModel
    @State private var sortOrder = [KeyPathComparator(\AgentTableRow.rank), KeyPathComparator(\AgentTableRow.since, order: .reverse)]
    @State private var selection: Set<AgentTableRow.ID> = []
    /// Agents whose sub-agents the user folded away; everything else is open.
    @State private var collapsed: Set<AgentTableRow.ID> = []
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let rows = AgentEntry.collect(from: model.hosts).map(AgentTableRow.init).sorted(using: sortOrder)
        Table(of: AgentTableRow.self, selection: $selection, sortOrder: $sortOrder) {
            columns
        } rows: {
            ForEach(rows) { row in
                if row.children.isEmpty {
                    TableRow(row)
                } else {
                    DisclosureTableRow(row, isExpanded: expanded(row.id)) {
                        ForEach(row.children) { TableRow($0) }
                    }
                }
            }
        }
        .contextMenu(forSelectionType: AgentTableRow.ID.self) { ids in
            if let row = find(ids.first, in: rows) {
                Button("Show in Main Window") { jump(to: row) }
            }
        } primaryAction: { ids in
            if let row = find(ids.first, in: rows) { jump(to: row) }
        }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView("No Agents Running", systemImage: "sparkles",
                                       description: Text("Coding agents in your tmux panes show up here."))
            }
        }
        // If state restoration brought back only this window, the hosts
        // still need connecting (start() is a no-op for a running host).
        .task {
            #if DEBUG
            if SidebarLab.isOn { return }
            #endif
            model.startAll()
        }
        .preferredColorScheme(AppTheme.colorScheme)
        .navigationTitle("Agents")
        .navigationSubtitle(subtitle(rows))
    }

    typealias Comparator = KeyPathComparator<AgentTableRow>

    @TableColumnBuilder<AgentTableRow, Comparator>
    private var columns: some TableColumnContent<AgentTableRow, Comparator> {
        // Status badge, the task, and where it lives — or, for a sub-agent,
        // its description and type.
        TableColumn("Agent", value: \.rank) { row in
            if let sub = row.subagent {
                HStack(spacing: 6) {
                    Image(systemName: "circle").font(.system(size: 9)).foregroundStyle(.tertiary)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(sub.title).lineLimit(1).help(sub.title)
                        if !sub.description.isEmpty {
                            Text(sub.type).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            } else {
                HStack(spacing: 8) {
                    AgentBadge(state: row.agent.state, kind: row.agent.kind, title: row.agent.name,
                               unseen: row.agent.finishedUnseen)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(row.task)
                            .fontWeight(row.agent.state.needsAttention || row.agent.finishedUnseen ? .semibold : .regular)
                            .lineLimit(1)
                            .help(row.task)
                        Text(whereText(row))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(whereText(row))
                    }
                }
            }
        }
        .width(min: 220, ideal: 380)

        // Its state, and what it's doing right now.
        TableColumn("Now", value: \.activity) { row in
            if row.subagent == nil {
                VStack(alignment: .leading, spacing: 0) {
                    Text(stateWord(row.agent))
                        .foregroundStyle(stateColor(row.agent))
                        .lineLimit(1)
                    if !row.activity.isEmpty {
                        Text(row.activity)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(row.activity)
                    }
                }
            }
        }
        .width(min: 140, ideal: 260)

        // Model, then thinking effort — the sub-agents' own, on their rows.
        TableColumn("Model") { row in
            let model = row.subagent?.model ?? row.agent.model
            let effort = row.subagent?.effort ?? row.agent.effort
            if !model.isEmpty || !effort.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.isEmpty ? "—" : ModelName.short(model))
                        .foregroundStyle(row.subagent == nil ? .primary : .secondary)
                        .lineLimit(1)
                        .help(model)
                    if !effort.isEmpty {
                        Text(effort).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .width(min: 70, ideal: 95, max: 130)

        // Mode, context, steps and sub-agents; uncommitted changes below.
        TableColumn("Details") { row in
            if row.subagent == nil {
                VStack(alignment: .leading, spacing: 0) {
                    detailText(row.agent)
                        .font(.system(size: 11).monospacedDigit())
                        .lineLimit(1)
                    if let diff = row.agent.diff, diff.added + diff.removed > 0 {
                        DiffStatText(diff: diff).font(.system(size: 11))
                    }
                }
            }
        }
        .width(min: 110, ideal: 190)

        TableColumn("Time", value: \.since) { row in
            if row.subagent == nil, row.agent.since != nil {
                ElapsedText(since: row.since)
            }
        }
        .width(min: 45, ideal: 55, max: 70)
    }

    private func expanded(_ id: AgentTableRow.ID) -> Binding<Bool> {
        Binding(get: { !collapsed.contains(id) },
                set: { if $0 { collapsed.remove(id) } else { collapsed.insert(id) } })
    }

    /// A row by id, looking inside the sub-agent rows too.
    private func find(_ id: AgentTableRow.ID?, in rows: [AgentTableRow]) -> AgentTableRow? {
        guard let id else { return nil }
        for row in rows {
            if row.id == id { return row }
            if let child = row.children.first(where: { $0.id == id }) { return child }
        }
        return nil
    }

    /// "hummingbird ⎇ main · Local · hummingbird:1 · Claude"
    private func whereText(_ row: AgentTableRow) -> String {
        let agent = row.agent
        var parts = [row.entry.window.folder
            + (agent.branch.isEmpty || agent.branch == "HEAD" ? "" : " ⎇ \(agent.branch)")]
        parts.append(row.entry.host.displayName)
        parts.append("\(row.entry.session.name):\(row.entry.window.index)")
        parts.append(agent.kind.displayName + (agent.name.isEmpty ? "" : " · \(agent.name)"))
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// "▸▸ auto · 84k ctx · 23 steps · 2 agents", only the parts it has.
    private func detailText(_ agent: AgentPane) -> Text {
        var parts: [Text] = []
        let mode = modeLabel(agent.mode)
        if !mode.isEmpty {
            parts.append(Text(mode).foregroundStyle(agent.mode == "auto" ? AnyShapeStyle(.yellow) : AnyShapeStyle(.secondary)))
        }
        if let ctx = agent.contextTokens, ctx > 0 { parts.append(Text("\(compact(ctx)) ctx").foregroundStyle(.secondary)) }
        if agent.steps > 0 { parts.append(Text("\(agent.steps) steps").foregroundStyle(.secondary)) }
        if agent.subagents > 0 {
            parts.append(Text("\(agent.subagents) agent\(agent.subagents == 1 ? "" : "s")").foregroundStyle(.secondary))
        }
        guard var text = parts.first else { return Text("—").foregroundStyle(.tertiary) }
        for part in parts.dropFirst() { text = text + Text(" · ").foregroundStyle(.tertiary) + part }
        return text
    }

    private func jump(to row: AgentTableRow) {
        model.jumpRequest = AppModel.JumpRequest(selection: row.entry.selection, paneID: row.agent.id)
        // Reopen the main window if it was closed; it applies the request on appear.
        openWindow(id: "main")
    }

    private func subtitle(_ rows: [AgentTableRow]) -> String {
        let needs = rows.filter { $0.agent.state.needsAttention }.count
        let busy = rows.filter { $0.agent.state.isBusy }.count
        var parts = ["\(rows.count) agent\(rows.count == 1 ? "" : "s")"]
        if needs > 0 { parts.append("\(needs) need\(needs == 1 ? "s" : "") you") }
        if busy > 0 { parts.append("\(busy) working") }
        return parts.joined(separator: " · ")
    }

    private func stateWord(_ agent: AgentPane) -> String {
        switch agent.state {
        case .waiting: "Needs you"
        case .error: "Error"
        case .working: "Working"
        case .background: "Background"
        case .idle: agent.finishedUnseen ? "Finished" : "Idle"
        case .running, .none: "Running"
        }
    }

    private func stateColor(_ agent: AgentPane) -> Color {
        switch agent.state {
        case .waiting: .orange
        case .error: AppTheme.statusBad
        case .idle where agent.finishedUnseen: AppTheme.statusGood
        default: .secondary
        }
    }

    private func modeLabel(_ mode: String) -> String {
        switch mode {
        case "auto": "▸▸ auto"
        case "acceptEdits": "accept edits"
        case "plan": "plan"
        case "bypassPermissions": "bypass"
        case "", "default": ""
        default: mode
        }
    }

    private func compact(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return "\(n / 1_000)k" }
        return "\(n)"
    }
}
