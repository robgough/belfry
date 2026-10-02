import SwiftUI

/// One agent as a table row: everything about it, flattened to sortable
/// values. Rebuilt from the live stores on every render, so the table follows
/// the agents as they work.
struct AgentTableRow: Identifiable {
    let id: String
    let entry: AgentEntry
    var agent: AgentPane { entry.agent }

    /// Lane order: needs you, just finished, working, quiet.
    let rank: Int
    let task: String
    let place: String
    let activity: String
    let subagents: Int
    let context: Int
    let steps: Int
    let changes: Int
    let since: Date

    @MainActor
    init(_ entry: AgentEntry) {
        id = entry.id
        self.entry = entry
        let agent = entry.agent
        rank = AgentLane.allCases.firstIndex(of: AgentLane.of(agent)) ?? 0
        task = !agent.summary.isEmpty ? agent.summary : (!agent.name.isEmpty ? agent.name : entry.window.title)
        let folder = entry.window.folder
        place = folder + (agent.branch.isEmpty || agent.branch == "HEAD" ? "" : " ⎇ \(agent.branch)")
        activity = agent.activity
        subagents = agent.subagents
        context = agent.contextTokens ?? 0
        steps = agent.steps
        changes = (agent.diff?.added ?? 0) + (agent.diff?.removed ?? 0)
        since = agent.since ?? .distantPast
    }
}

/// The Agents window: every agent on every host in a native, sortable table —
/// status, task, where it lives, what it's doing, its sub-agents, context,
/// steps, uncommitted changes and time in state. Double-click (or Return) a
/// row to jump the main window to that agent.
struct AgentsTableView: View {
    let model: AppModel
    @State private var sortOrder = [KeyPathComparator(\AgentTableRow.rank), KeyPathComparator(\AgentTableRow.since, order: .reverse)]
    @State private var selection: Set<AgentTableRow.ID> = []
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let rows = AgentEntry.collect(from: model.hosts).map(AgentTableRow.init).sorted(using: sortOrder)
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            primaryColumns
            detailColumns
        }
        .contextMenu(forSelectionType: AgentTableRow.ID.self) { ids in
            if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                Button("Show in Main Window") { jump(to: row) }
            }
        } primaryAction: { ids in
            if let id = ids.first, let row = rows.first(where: { $0.id == id }) { jump(to: row) }
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

    /// Status, task, agent, where, and what it's doing now.
    @TableColumnBuilder<AgentTableRow, Comparator>
    private var primaryColumns: some TableColumnContent<AgentTableRow, Comparator> {
            TableColumn("Status", value: \.rank) { row in
                HStack(spacing: 6) {
                    AgentBadge(state: row.agent.state, kind: row.agent.kind, title: row.agent.name,
                               unseen: row.agent.finishedUnseen)
                    Text(stateWord(row.agent))
                        .foregroundStyle(stateColor(row.agent))
                }
            }
            .width(min: 90, ideal: 110, max: 140)

            TableColumn("Task", value: \.task) { row in
                Text(row.task)
                    .fontWeight(row.agent.state.needsAttention || row.agent.finishedUnseen ? .semibold : .regular)
                    .help(row.task)
            }
            .width(min: 160, ideal: 260)

            TableColumn("Agent") { row in
                Text(row.agent.kind.displayName + (row.agent.name.isEmpty ? "" : " · \(row.agent.name)"))
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 140)

            TableColumn("Where", value: \.place) { row in
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.place).lineLimit(1)
                    Text("\(row.entry.host.displayName) · \(row.entry.session.name):\(row.entry.window.index)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .width(min: 120, ideal: 190)

            TableColumn("Now", value: \.activity) { row in
                Text(row.activity.isEmpty ? "—" : row.activity)
                    .foregroundStyle(row.agent.state == .waiting ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                    .help(row.activity)
            }
            .width(min: 140, ideal: 230)

    }

    /// Sub-agents, mode, context, steps, changes and time in state.
    @TableColumnBuilder<AgentTableRow, Comparator>
    private var detailColumns: some TableColumnContent<AgentTableRow, Comparator> {
            TableColumn("Sub-agents", value: \.subagents) { row in
                Text(row.subagents == 0 ? "—" : "\(row.subagents)")
                    .monospacedDigit()
                    .help(row.agent.tasks.joined(separator: "\n"))
            }
            .width(min: 60, ideal: 75, max: 90)

            TableColumn("Mode") { row in
                Text(modeLabel(row.agent.mode))
                    .foregroundStyle(row.agent.mode == "auto" ? AnyShapeStyle(.yellow) : AnyShapeStyle(.secondary))
            }
            .width(min: 50, ideal: 80, max: 110)

            TableColumn("Context", value: \.context) { row in
                Text(row.context == 0 ? "—" : compact(row.context))
                    .monospacedDigit()
            }
            .width(min: 55, ideal: 65, max: 80)

            TableColumn("Steps", value: \.steps) { row in
                Text(row.steps == 0 ? "—" : "\(row.steps)")
                    .monospacedDigit()
            }
            .width(min: 45, ideal: 55, max: 70)

            TableColumn("Changes", value: \.changes) { row in
                if let diff = row.agent.diff, diff.added + diff.removed > 0 {
                    DiffStatText(diff: diff)
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }
            .width(min: 70, ideal: 90, max: 120)

            TableColumn("Time", value: \.since) { row in
                if row.agent.since != nil {
                    ElapsedText(since: row.since)
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }
            .width(min: 45, ideal: 55, max: 70)
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
        case "", "default": "—"
        default: mode
        }
    }

    private func compact(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return "\(n / 1_000)k" }
        return "\(n)"
    }
}
