import SwiftUI

// MARK: - Snapshot (plain values: what the sidebar shows)

/// Everything the Mac sidebar draws, as plain values. Built from the live
/// models by `MacSidebarContainer`, and directly by the render tests — so the
/// view can be checked off-screen with sample data.
struct SidebarSnapshot: Equatable {
    var pins: [Pin] = []
    var lanes: [Lane] = []
    var hosts: [Host] = []
    /// Collapsed section keys: "pinned", "agents", "host:<id>", "session:<host>|<id>".
    var collapsed: Set<String> = []

    struct Pin: Identifiable, Equatable {
        let id: String
        let title: String
        let detail: String
        let isWindow: Bool
        let isLive: Bool
        let target: WindowSelection?
        let agent: AgentPane?
        let hasBell: Bool
    }

    struct Lane: Identifiable, Equatable {
        let lane: AgentLane
        let agents: [Agent]
        var id: AgentLane { lane }
    }

    struct Agent: Identifiable, Equatable {
        let id: String
        let pane: AgentPane
        let selection: WindowSelection
        let sessionName: String
        let hostName: String
        let isLocal: Bool
        let folder: String
        let shortcut: Int?
        var isHighlighted = false
    }

    struct Host: Identifiable, Equatable {
        let id: String
        let name: String
        let isLocal: Bool
        let status: ConnectionStatus
        let sessions: [Session]
    }

    struct Session: Identifiable, Equatable {
        let id: String
        let hostID: String
        let name: String
        let windows: [TmuxWindow]
        let isPinned: Bool
        var pinnedWindowIDs: Set<String> = []
        var key: String { "session:\(hostID)|\(id)" }
    }

    /// Every selectable target, top to bottom (arrow-key order).
    var selectionOrder: [WindowSelection] {
        var order: [WindowSelection] = []
        if !collapsed.contains("pinned") { order += pins.compactMap(\.target) }
        if !collapsed.contains("agents") { order += lanes.flatMap { $0.agents.map(\.selection) } }
        for host in hosts where !collapsed.contains("host:\(host.id)") {
            for session in host.sessions {
                if session.windows.count == 1 || !collapsed.contains(session.key) {
                    order += session.windows.map { WindowSelection(hostID: host.id, windowID: $0.id) }
                }
            }
        }
        return order
    }
}

/// What a row's context menu is for (the container supplies the menu).
enum SidebarMenuTarget: Hashable {
    case host(String)
    case session(hostID: String, sessionID: String)
    case window(hostID: String, sessionID: String, windowID: String, standsForSession: Bool)
    case pin(String)
    case agent(String)
}

/// The quick actions rows offer on hover (everything else is in the context
/// menu). Supplied by the container; no-ops in renders.
struct SidebarRowActions {
    var togglePinSession: (_ hostID: String, _ sessionID: String) -> Void = { _, _ in }
    var togglePinWindow: (_ hostID: String, _ sessionID: String, _ windowID: String) -> Void = { _, _, _ in }
    var unpin: (_ pinID: String) -> Void = { _ in }
    var newWindow: (_ hostID: String, _ sessionID: String) -> Void = { _, _ in }
    var closeWindow: (_ hostID: String, _ sessionID: String, _ windowID: String) -> Void = { _, _, _ in }
    var closeSession: (_ hostID: String, _ sessionID: String) -> Void = { _, _ in }
}

/// One hover action: an SF Symbol button with a tooltip.
struct SidebarHoverAction: Identifiable {
    let symbol: String
    let help: String
    let action: () -> Void
    var id: String { symbol }
}

extension EnvironmentValues {
    /// Render every row in its hovered state (render tests only).
    @Entry var sidebarForceHover = false
    /// Called whenever a row is tapped (even one already selected) — the
    /// iPhone uses it to show the terminal column.
    @Entry var sidebarActivate: () -> Void = {}
}

// MARK: - Metrics (one grid for everything)

private enum SB {
    #if os(iOS)
    // Touch: 44pt rows and body-sized text.
    static let rowHeight: CGFloat = 44
    static let icon: CGFloat = 24
    static let primary: CGFloat = 16
    static let secondary: CGFloat = 13
    static let symbol: CGFloat = 16
    static let label: CGFloat = 13
    #else
    static let rowHeight: CGFloat = 28
    /// Icon column width; every row's icon sits in it.
    static let icon: CGFloat = 18
    /// Primary text, secondary text, row symbols, section labels.
    static let primary: CGFloat = 13
    static let secondary: CGFloat = 11
    static let symbol: CGFloat = 12
    static let label: CGFloat = 11
    #endif
    /// Row inset from the sidebar's edges.
    static let edge: CGFloat = 8
    /// Padding inside a row, before the icon column.
    static let pad: CGFloat = 8
    /// Icon → text.
    static let gap: CGFloat = 8
    /// Nested windows of a multi-window session.
    static let indent: CGFloat = 16
    static let radius: CGFloat = 6
    /// Where row text starts — section labels align to it.
    static var textLeading: CGFloat { edge + pad }
}

// MARK: - The view

/// The Mac sidebar: Pinned, then Agents grouped by status, then each host's
/// sessions and windows — drawn by us in a plain scroll view on one spacing
/// grid (no system row boxes, no clipping), with a soft accent selection,
/// hover states, arrow-key navigation and smooth reordering.
struct MacSidebarView: View {
    let snapshot: SidebarSnapshot
    @Binding var selection: WindowSelection?
    var toggle: (String) -> Void = { _ in }
    var menu: (SidebarMenuTarget) -> AnyView = { _ in AnyView(EmptyView()) }
    var newSession: (String) -> Void = { _ in }
    var actions = SidebarRowActions()
    @Environment(\.sidebarActivate) private var activate

    var body: some View {
        #if os(macOS)
        // The scroll view runs up under the (transparent) toolbar, and the
        // toolbar's height is added as padding SwiftUI knows about. Left to
        // AppKit, the scroll view got an automatic content inset SwiftUI
        // didn't see: rows were drawn a toolbar-height lower than they were
        // laid out — a doubled gap above the first section, and clicks
        // landing on the wrong row.
        GeometryReader { geo in
            ScrollView {
                content
                    .padding(.top, geo.safeAreaInsets.top)
                    #if DEBUG
                    .background(GeometryReader { inner in
                        Color.clear.preference(key: SidebarLayoutKey.self,
                                               value: "content minY=\(inner.frame(in: .global).minY) top=\(geo.safeAreaInsets.top)")
                    })
                    #endif
            }
            .scrollIndicators(.automatic)
            .ignoresSafeArea(.container, edges: .top)
        }
        #if DEBUG
        .onPreferenceChange(SidebarLayoutKey.self) { SidebarLayoutKey.last = $0 }
        #endif
        #else
        // iOS: the navigation bar's insets just work (and keep the large
        // title collapsing as the list scrolls).
        ScrollView { content }
        #endif
    }

    /// The rows, without the scroll view (which off-screen rendering can't draw).
    var content: some View {
            VStack(alignment: .leading, spacing: 0) {
                if !snapshot.pins.isEmpty {
                    SectionLabel(title: "Pinned", isCollapsed: snapshot.collapsed.contains("pinned"), isFirst: true) {
                        toggle("pinned")
                    }
                    if !snapshot.collapsed.contains("pinned") {
                        ForEach(snapshot.pins) { pin in
                            PinRow(pin: pin, isSelected: pin.target != nil && selection == pin.target,
                                   actions: [SidebarHoverAction(symbol: "pin.slash", help: "Unpin") {
                                       actions.unpin(pin.id)
                                   }])
                                .onTapGesture { if let target = pin.target { selection = target; activate() } }
                                .contextMenu { menu(.pin(pin.id)) }
                        }
                    }
                }
                if !snapshot.lanes.isEmpty {
                    SectionLabel(title: "Agents", isCollapsed: snapshot.collapsed.contains("agents"),
                                 isFirst: snapshot.pins.isEmpty) {
                        toggle("agents")
                    }
                    if !snapshot.collapsed.contains("agents") {
                        ForEach(snapshot.lanes) { lane in
                            LaneLabel(lane: lane.lane, isFirst: lane.id == snapshot.lanes.first?.id)
                            ForEach(lane.agents) { agent in
                                AgentRow2(agent: agent, isSelected: selection == agent.selection)
                                    .onTapGesture { selection = agent.selection; activate() }
                                    .contextMenu { menu(.agent(agent.id)) }
                            }
                        }
                    }
                }
                ForEach(snapshot.hosts) { host in
                    hostSection(host)
                }
                Spacer(minLength: 12)
            }
            .animation(.smooth(duration: 0.3), value: snapshot.lanes.map { $0.agents.map(\.id) })
    }

    @ViewBuilder private func hostSection(_ host: SidebarSnapshot.Host) -> some View {
        let key = "host:\(host.id)"
        SectionLabel(title: host.name,
                     tint: AppTheme.hostTint(isLocal: host.isLocal),
                     status: host.status.isLive ? nil : host.status,
                     isCollapsed: snapshot.collapsed.contains(key),
                     onAdd: { newSession(host.id) }) {
            toggle(key)
        }
        .contextMenu { menu(.host(host.id)) }
        if !snapshot.collapsed.contains(key) {
            if host.sessions.isEmpty {
                Text(host.status.isLive ? "No sessions" : "Not connected")
                    .font(.system(size: SB.secondary))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, SB.textLeading)
                    .frame(height: SB.rowHeight)
            }
            ForEach(host.sessions) { session in
                if session.windows.count == 1, let only = session.windows.first {
                    windowRow(host: host, session: session, window: only, standsForSession: true)
                } else {
                    let folded = snapshot.collapsed.contains(session.key)
                    SessionRow(session: session, isCollapsed: folded, actions: [
                        SidebarHoverAction(symbol: session.isPinned ? "pin.slash" : "pin",
                                           help: session.isPinned ? "Unpin session" : "Pin session") {
                            actions.togglePinSession(host.id, session.id)
                        },
                        SidebarHoverAction(symbol: "plus", help: "New window") {
                            actions.newWindow(host.id, session.id)
                        },
                        SidebarHoverAction(symbol: "xmark", help: "Close session…") {
                            actions.closeSession(host.id, session.id)
                        },
                    ])
                        .onTapGesture { toggle(session.key) }
                        .contextMenu { menu(.session(hostID: host.id, sessionID: session.id)) }
                    if !folded {
                        ForEach(session.windows) { window in
                            windowRow(host: host, session: session, window: window, standsForSession: false)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func windowRow(host: SidebarSnapshot.Host, session: SidebarSnapshot.Session,
                                        window: TmuxWindow, standsForSession: Bool) -> some View {
        let target = WindowSelection(hostID: host.id, windowID: window.id)
        let pinned = standsForSession ? session.isPinned : session.pinnedWindowIDs.contains(window.id)
        WindowRow2(window: window, sessionName: session.name, standsForSession: standsForSession,
                   isPinned: pinned,
                   isSelected: selection?.sameWindow(as: target) == true && selection?.paneID == nil,
                   actions: windowActions(host: host, session: session, window: window,
                                          standsForSession: standsForSession, pinned: pinned))
            .onTapGesture { selection = target; activate() }
            .contextMenu {
                menu(.window(hostID: host.id, sessionID: session.id, windowID: window.id,
                             standsForSession: standsForSession))
            }
    }
}

#if DEBUG
/// Debug-only: the sidebar's measured geometry, written next to window
/// snapshots (see DebugSnapshot) so layout gaps can be diagnosed.
struct SidebarLayoutKey: PreferenceKey {
    nonisolated(unsafe) static var last = ""
    static var defaultValue: String { "" }
    static func reduce(value: inout String, nextValue: () -> String) {
        let next = nextValue()
        if !next.isEmpty { value = value.isEmpty ? next : value + " | " + next }
    }
}
#endif

/// The sidebar column's surroundings: the theme's sidebar colour, running up
/// under the title bar.
struct MacSidebarChrome: ViewModifier {
    func body(content: Content) -> some View {
        content.background(AppTheme.sidebarBackground.ignoresSafeArea())
    }
}

extension MacSidebarView {
    fileprivate func windowActions(host: SidebarSnapshot.Host, session: SidebarSnapshot.Session,
                                   window: TmuxWindow, standsForSession: Bool,
                                   pinned: Bool) -> [SidebarHoverAction] {
        var list = [SidebarHoverAction(symbol: pinned ? "pin.slash" : "pin", help: pinned ? "Unpin" : "Pin") {
            if standsForSession { actions.togglePinSession(host.id, session.id) }
            else { actions.togglePinWindow(host.id, session.id, window.id) }
        }]
        if standsForSession {
            list.append(SidebarHoverAction(symbol: "plus", help: "New window") {
                actions.newWindow(host.id, session.id)
            })
        }
        list.append(SidebarHoverAction(symbol: "xmark", help: standsForSession ? "Close session…" : "Close window…") {
            if standsForSession { actions.closeSession(host.id, session.id) }
            else { actions.closeWindow(host.id, session.id, window.id) }
        })
        return list
    }
}

/// Hover actions: small borderless SF Symbol buttons.
private struct HoverActionButtons: View {
    let actions: [SidebarHoverAction]
    /// Off-screen renders can't draw AppKit buttons; show the bare icons.
    @Environment(\.staticAgentBadges) private var staticRender
    var body: some View {
        HStack(spacing: 0) {
            ForEach(actions) { item in
                if staticRender {
                    icon(item.symbol).foregroundStyle(.secondary)
                } else {
                    Button(action: item.action) { icon(item.symbol) }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help(item.help)
                }
            }
        }
    }

    private func icon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: SB.label, weight: .medium))
            .frame(width: 22, height: 20)
            .contentShape(Rectangle())
    }
}

// MARK: - Pieces

/// Row chrome shared by every row: inset from the edges, a rounded fill for
/// selection (accent), attention (a soft status tint) or hover.
private struct RowChrome: ViewModifier {
    let isSelected: Bool
    var attention: Color? = nil
    /// Tint strength (Working is fainter than statuses that want you).
    var strength: Double = 0.12
    var minHeight: CGFloat = SB.rowHeight
    var isHovered = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, SB.pad)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: SB.radius, style: .continuous)
                    .fill(fill)
            )
            .contentShape(Rectangle())
            .padding(.horizontal, SB.edge)
    }

    private var fill: Color {
        if isSelected { return AppTheme.accent.opacity(0.24) }
        if let attention { return attention.opacity(isHovered ? strength + 0.06 : strength) }
        return Color.primary.opacity(isHovered ? 0.06 : 0)
    }
}

/// A section label (Pinned, Agents, a host): small and semibold, aligned to
/// the rows' text. Clicking folds it; a chevron (and, for hosts, a + button)
/// appears on hover.
private struct SectionLabel: View {
    let title: String
    var tint: Color = .secondary
    var status: ConnectionStatus? = nil
    let isCollapsed: Bool
    var onAdd: (() -> Void)? = nil
    /// The sidebar's first section sits close under the toolbar.
    var isFirst = false
    let toggle: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: SB.label, weight: .semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
            if let status {
                HostStatusDot(status: status)
            }
            Spacer(minLength: 4)
            if let onAdd {
                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 18, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .opacity(isHovered ? 1 : 0)
                .help("New session on \(title)")
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                .opacity(isHovered || isCollapsed ? 1 : 0)
        }
        .padding(.leading, SB.textLeading)
        .padding(.trailing, SB.edge + SB.pad)
        .padding(.top, isFirst ? 6 : 18)
        .padding(.bottom, 6)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy(duration: 0.25)) { toggle() } }
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

/// A status group's label inside Agents, in the status's colour.
private struct LaneLabel: View {
    let lane: AgentLane
    var isFirst = false
    var body: some View {
        Text(lane.nativeTitle)
            .font(.system(size: SB.label, weight: .medium))
            .foregroundStyle(lane == .quiet ? AnyShapeStyle(.secondary) : AnyShapeStyle(lane.tint))
            .padding(.leading, SB.textLeading)
            .padding(.top, isFirst ? 0 : 10)
            .padding(.bottom, 3)
    }
}

/// An agent: its braille status glyph in the icon column, the task, and one
/// live line — what it's doing (orange when it needs you, green when it
/// finished while you were away), or where it lives when quiet — with
/// uncommitted +/− and time in state on the right. Agents that need you sit
/// on a soft tint of their status colour.
private struct AgentRow2: View {
    static let maxTasks = 4
    let agent: SidebarSnapshot.Agent
    let isSelected: Bool
    @State private var isHovered = false
    private var pane: AgentPane { agent.pane }

    var body: some View {
        HStack(alignment: .top, spacing: SB.gap) {
            AgentBadge(state: pane.state, kind: pane.kind, title: pane.name, unseen: pane.finishedUnseen)
                .frame(width: SB.icon, height: 17)
            VStack(alignment: .leading, spacing: 2) {
                // The task with the time beside it (short, so the task keeps the width).
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    titleText
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let since = pane.since {
                        ElapsedText(since: since)
                    }
                }
                // Where it is (project ⎇ branch …) with the uncommitted +/−
                // beside it, then — on its own line, so neither squeezes the
                // other — what it's doing.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(whereText)
                        .font(.system(size: SB.secondary))
                        .foregroundStyle(statusLine == nil ? .tertiary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    if let diff = pane.diff, diff.added + diff.removed > 0 {
                        DiffStatText(diff: diff)
                    }
                }
                if let statusLine {
                    statusLine
                        .font(.system(size: SB.secondary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                // Its running sub-agents, one line each, as Claude Code lists them.
                if pane.state.isBusy || pane.state == .waiting {
                    ForEach(Array(pane.tasks.prefix(Self.maxTasks).enumerated()), id: \.offset) { _, task in
                        SubagentLine(task: task, size: SB.secondary)
                    }
                    if pane.tasks.count > Self.maxTasks {
                        Text("+\(pane.tasks.count - Self.maxTasks) more")
                            .font(.system(size: SB.secondary))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .modifier(RowChrome(isSelected: isSelected, attention: attention,
                            strength: pane.state.isBusy ? 0.07 : 0.12, isHovered: isHovered))
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        // A hair of space between agents, so tinted rows read as separate.
        .padding(.vertical, 1.5)
        .background(
            RoundedRectangle(cornerRadius: SB.radius, style: .continuous)
                .strokeBorder(highlight.opacity(agent.isHighlighted ? 0.8 : 0), lineWidth: 1.5)
                .padding(.horizontal, SB.edge)
                .animation(.easeOut(duration: 0.8), value: agent.isHighlighted)
        )
    }

    private var emphasised: Bool { pane.state.needsAttention || pane.finishedUnseen }

    /// Each active status sits on a soft tint of its colour; Quiet stays plain.
    private var attention: Color? {
        switch pane.state {
        case .waiting: .orange
        case .error: AppTheme.statusBad
        case .idle where pane.finishedUnseen: AppTheme.statusGood
        case .working, .background: AppTheme.accent
        default: nil
        }
    }

    private var highlight: Color { attention ?? AppTheme.accent }

    /// The task (Claude Code's summary or the prompt), else the session name.
    private var titleText: Text {
        Text(pane.task.isEmpty ? project : pane.task).font(.system(size: SB.primary, weight: emphasised ? .semibold : .medium))
    }

    /// The folder, or the session when it's a bare home directory.
    private var project: String {
        agent.folder.isEmpty || agent.folder == "~" ? agent.sessionName : agent.folder
    }

    /// "belfry ⎇ main · session · host · Codex · Opus 5.5" — the project
    /// first, so it's the last thing to truncate.
    private var whereText: String {
        var s = project
        if !pane.branch.isEmpty, pane.branch != "HEAD" { s += " ⎇ \(pane.branch)" }
        if agent.sessionName != project { s += " · \(agent.sessionName)" }
        if !agent.isLocal { s += " · \(agent.hostName)" }
        if pane.kind != .claude { s += " · \(pane.kind.displayName)" }
        if !pane.model.isEmpty { s += " · \(ModelName.short(pane.model))" }
        return s
    }

    /// What it's doing, or nil for a quiet agent (its row is just where it is).
    private var statusLine: Text? {
        switch pane.state {
        // On the attention tint, the text stays in the normal colour for
        // contrast; the tint and glyph carry the status.
        case .waiting:
            return Text(pane.activity.isEmpty ? "Waiting for you" : pane.activity).foregroundStyle(.primary)
        case .error:
            return Text(pane.activity.isEmpty ? "Stopped on an error" : pane.activity).foregroundStyle(.primary)
        case .working, .background:
            var text = Text(pane.activity.isEmpty ? "Working" : pane.activity).foregroundStyle(.secondary)
            // The count only when there are no sub-agent lines to show it.
            if pane.subagents > 0, pane.tasks.isEmpty {
                text = text + Text(" · \(pane.subagents) agent\(pane.subagents == 1 ? "" : "s")")
                    .foregroundStyle(.tertiary)
            }
            return text
        case .idle where pane.finishedUnseen:
            return Text("Finished").foregroundStyle(.primary)
        case .idle, .running, .none:
            return nil
        }
    }
}

/// A multi-window session: its name, with a fold chevron on the right (so
/// the icon column stays straight) and, folded, its most urgent agent.
private struct SessionRow: View {
    let session: SidebarSnapshot.Session
    let isCollapsed: Bool
    var actions: [SidebarHoverAction] = []
    @State private var isHovered = false
    @Environment(\.sidebarForceHover) private var forceHover
    private var hovered: Bool { isHovered || forceHover }

    var body: some View {
        HStack(spacing: SB.gap) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: SB.symbol))
                .foregroundStyle(.secondary)
                .frame(width: SB.icon)
            Text(session.name)
                .font(.system(size: SB.primary, weight: .medium))
                .lineLimit(1)
            if session.isPinned {
                Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            ZStack(alignment: .trailing) {
                if isCollapsed, let agent = session.windows.compactMap(\.primaryAgent)
                    .max(by: { $0.state.urgency < $1.state.urgency }) {
                    AgentBadge(state: agent.state, kind: agent.kind, title: agent.name, unseen: agent.finishedUnseen)
                        .opacity(hovered ? 0 : 1)
                }
                HoverActionButtons(actions: actions)
                    .opacity(hovered ? 1 : 0)
                    .allowsHitTesting(hovered)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isCollapsed ? 0 : 90))
        }
        .modifier(RowChrome(isSelected: false, isHovered: hovered))
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

/// A window — or a whole one-window session — with an SF Symbol for what's
/// running, a title that says what it is, its folder dimmed beside it, and
/// status on the right. Nested windows indent under their session.
private struct WindowRow2: View {
    let window: TmuxWindow
    let sessionName: String
    let standsForSession: Bool
    let isPinned: Bool
    let isSelected: Bool
    var actions: [SidebarHoverAction] = []
    @State private var isHovered = false
    @Environment(\.sidebarForceHover) private var forceHover
    private var hovered: Bool { isHovered || forceHover }

    var body: some View {
        HStack(spacing: SB.gap) {
            Image(systemName: window.symbol)
                .font(.system(size: SB.symbol))
                .foregroundStyle(isSelected ? AnyShapeStyle(AppTheme.accent) : AnyShapeStyle(.secondary))
                .frame(width: SB.icon)
            titleText
                .lineLimit(1)
                .truncationMode(.tail)
            if isPinned {
                Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            // Hover swaps the status badges for the row's quick actions.
            ZStack(alignment: .trailing) {
                HStack(spacing: 6) {
                    if window.hasBell {
                        Image(systemName: "bell.fill").font(.system(size: 9)).foregroundStyle(AppTheme.statusWarn)
                    }
                    if let agent = window.primaryAgent {
                        AgentBadge(state: agent.state, kind: agent.kind, title: agent.name, unseen: agent.finishedUnseen)
                    } else if window.hasActivity {
                        Circle().fill(AppTheme.statusWarn).frame(width: 5, height: 5)
                    }
                }
                .opacity(hovered ? 0 : 1)
                HoverActionButtons(actions: actions)
                    .opacity(hovered ? 1 : 0)
                    .allowsHitTesting(hovered)
            }
        }
        .padding(.leading, standsForSession ? 0 : SB.indent)
        .modifier(RowChrome(isSelected: isSelected, isHovered: hovered))
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private var titleText: Text {
        let main: String
        let detail: String
        if standsForSession {
            main = sessionName
            detail = window.title == sessionName ? window.titleDetail : window.title
        } else if window.title == sessionName, window.primaryAgent == nil {
            let cmd = window.command.lowercased()
            main = (cmd.isEmpty || AgentPane.shells.contains(cmd)) ? "Shell" : window.command
            detail = ""
        } else {
            main = window.title
            detail = window.titleDetail
        }
        return Text(main).font(.system(size: SB.primary, weight: window.isActive || standsForSession ? .medium : .regular))
            .foregroundStyle(window.isActive || standsForSession || isSelected ? .primary : .secondary)
            + Text(detail.isEmpty ? "" : "  \(detail)").font(.system(size: SB.secondary)).foregroundStyle(.tertiary)
    }
}

/// A pinned session or window: one line, its title with "host · session"
/// dimmed beside it, and the live badge of what it shows.
private struct PinRow: View {
    let pin: SidebarSnapshot.Pin
    let isSelected: Bool
    var actions: [SidebarHoverAction] = []
    @State private var isHovered = false
    @Environment(\.sidebarForceHover) private var forceHover
    private var hovered: Bool { isHovered || forceHover }

    var body: some View {
        HStack(spacing: SB.gap) {
            Image(systemName: pin.isWindow ? "macwindow" : "rectangle.stack")
                .font(.system(size: SB.symbol))
                .foregroundStyle(isSelected ? AnyShapeStyle(AppTheme.accent) : AnyShapeStyle(.secondary))
                .frame(width: SB.icon)
            (Text(pin.title).font(.system(size: SB.primary, weight: .medium))
             + Text("  \(pin.detail)").font(.system(size: SB.secondary)).foregroundStyle(.tertiary))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            ZStack(alignment: .trailing) {
                HStack(spacing: 6) {
                    if pin.hasBell {
                        Image(systemName: "bell.fill").font(.system(size: 9)).foregroundStyle(AppTheme.statusWarn)
                    }
                    if let agent = pin.agent {
                        AgentBadge(state: agent.state, kind: agent.kind, title: agent.name, unseen: agent.finishedUnseen)
                    }
                }
                .opacity(hovered ? 0 : 1)
                HoverActionButtons(actions: actions)
                    .opacity(hovered ? 1 : 0)
                    .allowsHitTesting(hovered)
            }
        }
        .modifier(RowChrome(isSelected: isSelected, isHovered: hovered))
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .opacity(pin.isLive ? 1 : 0.5)
    }
}

#if DEBUG
/// Debug builds: sample sidebar data (render tests and the sidebar lab).
@MainActor
enum SidebarSamples {
    static func agent(_ pane: String, window: String, session: String, command: String = "2.1.286",
                       title: String, kind: String = "claude", state: String, activity: String = "",
                       branch: String = "main", diff: String = "", subagents: String = "",
                       tasks: String = "", model: String = "claude-opus-5-5", effort: String = "high",
                       ago: TimeInterval = 120, path: String) -> AgentPane {
        var raw = AgentPane.Raw(
            paneID: pane, windowID: window, sessionID: session, isActivePane: true,
            command: command, currentPath: path, title: "✳ \(title)",
            kind: kind, state: state, timestamp: "\(Int(Date().timeIntervalSince1970 - ago))",
            activity: activity, summary: title, name: "", diff: diff,
            legacyClaudeState: "", legacyClaudeTitle: "")
        raw.branch = branch
        raw.subagents = subagents
        raw.tasks = tasks
        raw.model = model
        raw.effort = effort
        return AgentPane.detect(raw)!
    }

    static func window(_ id: String, session: String, index: Int, name: String, command: String,
                        path: String, active: Bool = true, agents: [AgentPane] = []) -> TmuxWindow {
        var w = TmuxWindow(id: id, sessionID: session, index: index, name: name, isActive: active, hasActivity: false)
        w.command = command
        w.currentPath = path
        w.agents = agents
        return w
    }

    static func snapshot() -> SidebarSnapshot {
        let needs = agent("%1", window: "@1", session: "$1", title: "Agent status visibility multi-harness",
                          state: "waiting", activity: "Approve Bash: git push", diff: "84 12 3",
                          path: "/Users/rob/code/belfry")
        var finished = agent("%2", window: "@2", session: "$2", title: "Fly deployment with PlanetScale",
                             state: "idle", diff: "4203 74 31", ago: 60, path: "/Users/rob/code/hummingbird")
        finished.finishedUnseen = true
        let working = agent("%3", window: "@3", session: "$3", title: "Airship game with crew and dynamic systems",
                            state: "working", activity: "Editing display.rs", diff: "1990 159 12", subagents: "2",
                            tasks: "a1b2 claude-haiku-4-5-20251001,- Explore: Map the crew systems"
                                + "|c3d4 claude-opus-5-5,high general-purpose: Audit the save format",
                            ago: 900, path: "/Users/rob/code/airship2")
        let codex = agent("%4", window: "@4", session: "$4", command: "codex", title: "Codebase review",
                          kind: "codex", state: "working", activity: "Run the test suite", ago: 300,
                          path: "/Users/rob/code/ledgerly")
        let quiet = agent("%5", window: "@5", session: "$5", title: "Menubar improvements", state: "idle",
                          ago: 86_400, path: "/Users/rob/code/dictator")

        func entry(_ pane: AgentPane, host: String = "local", session: String, folder: String, n: Int) -> SidebarSnapshot.Agent {
            SidebarSnapshot.Agent(id: "local|\(pane.id)", pane: pane,
                                  selection: WindowSelection(hostID: host, windowID: pane.windowID, paneID: pane.id),
                                  sessionName: session, hostName: "Local", isLocal: true, folder: folder, shortcut: n)
        }

        var snap = SidebarSnapshot()
        snap.pins = [
            .init(id: "p1", title: "airship2", detail: "Local · airship2", isWindow: false, isLive: true,
                  target: WindowSelection(hostID: "local", windowID: "@3"), agent: working, hasBell: false),
        ]
        snap.lanes = [
            .init(lane: .needsYou, agents: [entry(needs, session: "belfry", folder: "belfry", n: 1)]),
            .init(lane: .finished, agents: [entry(finished, session: "hb", folder: "hummingbird", n: 2)]),
            .init(lane: .working, agents: [entry(working, session: "airship2", folder: "airship2", n: 3),
                                           entry(codex, session: "ledgerly", folder: "ledgerly", n: 4)]),
            .init(lane: .quiet, agents: [entry(quiet, session: "dictator", folder: "dictator", n: 5)]),
        ]
        snap.hosts = [
            .init(id: "local", name: "Local", isLocal: true, status: .connected, sessions: [
                .init(id: "$1", hostID: "local", name: "belfry", windows: [
                    window("@1", session: "$1", index: 1, name: "2.1.286", command: "2.1.286",
                           path: "/Users/rob/code/belfry", agents: [needs])], isPinned: false),
                .init(id: "$2", hostID: "local", name: "hummingbird", windows: [
                    window("@2", session: "$2", index: 1, name: "2.1.286", command: "2.1.286",
                           path: "/Users/rob/code/hummingbird", agents: [finished]),
                    window("@6", session: "$2", index: 2, name: "zsh", command: "zsh",
                           path: "/Users/rob/code/hummingbird", active: false),
                    window("@7", session: "$2", index: 3, name: "nvim", command: "nvim",
                           path: "/Users/rob/code/hummingbird", active: false)], isPinned: false),
                .init(id: "$8", hostID: "local", name: "main", windows: [
                    window("@8", session: "$8", index: 1, name: "zsh", command: "zsh", path: "/Users/rob")],
                      isPinned: false),
            ]),
            .init(id: "magrathea", name: "magrathea", isLocal: false, status: .connected, sessions: [
                .init(id: "$9", hostID: "magrathea", name: "scratchpad", windows: [
                    window("@9", session: "$9", index: 0, name: "zsh", command: "zsh", path: "/home/rob/scratch")],
                      isPinned: false),
            ]),
            .init(id: "kodiak", name: "kodiak-ts", isLocal: false, status: .reconnecting(attempt: 2), sessions: []),
        ]
        return snap
    }

}

/// Debug builds: launch with BELFRY_SIDEBAR_LAB=1 to show the sidebar with
/// sample data and connect to nothing (no tmux at all) — so a second copy can
/// run beside the real one for layout work.
enum SidebarLab {
    static let isOn = ProcessInfo.processInfo.environment["BELFRY_SIDEBAR_LAB"] != nil
}
#endif

// MARK: - Container (live data → snapshot, menus, keys)

/// Builds `SidebarSnapshot` from the live models and hosts `MacSidebarView`:
/// context menus, folding (remembered across launches), new-session, and
/// arrow-key navigation through every selectable row.
struct MacSidebarContainer: View {
    let hosts: [HostModel]
    let model: AppModel
    @Binding var selection: WindowSelection?
    @Binding var prompt: SidebarPrompt?
    @Binding var confirm: ConfirmAction?
    let justMoved: Set<String>
    /// Folded sections, comma-joined ("pinned,host:local,session:local|$3").
    @AppStorage("sidebarCollapsed") private var collapsedStorage = ""

    var body: some View {
        let snapshot = makeSnapshot()
        MacSidebarView(snapshot: snapshot, selection: $selection,
                       toggle: toggle, menu: menu,
                       newSession: { id in
                           if let host = hosts.first(where: { $0.id == id }) { prompt = .newSession(host: host) }
                       },
                       actions: rowActions)
            .modifier(MacSidebarChrome())
    }

    /// Hover quick actions, wired to the same operations as the context menus.
    private var rowActions: SidebarRowActions {
        func lookup(_ hostID: String, _ sessionID: String) -> (HostModel, TmuxSession)? {
            guard let host = hosts.first(where: { $0.id == hostID }),
                  let session = host.store.sessions.first(where: { $0.id == sessionID }) else { return nil }
            return (host, session)
        }
        return SidebarRowActions(
            togglePinSession: { hostID, sessionID in
                if let (host, session) = lookup(hostID, sessionID) { model.togglePin(host: host, session: session) }
            },
            togglePinWindow: { hostID, sessionID, windowID in
                if let (host, session) = lookup(hostID, sessionID),
                   let window = session.windows.first(where: { $0.id == windowID }) {
                    model.togglePin(host: host, session: session, window: window)
                }
            },
            unpin: { pinID in
                if let pin = model.pins.first(where: { $0.id == pinID }) { model.unpin(pin) }
            },
            newWindow: { hostID, sessionID in
                lookup(hostID, sessionID)?.0.client.newWindow(inSession: sessionID)
            },
            closeWindow: { hostID, sessionID, windowID in
                if let (host, session) = lookup(hostID, sessionID),
                   let window = session.windows.first(where: { $0.id == windowID }) {
                    confirm = WindowMenuItems.killConfirm(host: host, window: window)
                }
            },
            closeSession: { hostID, sessionID in
                if let (host, session) = lookup(hostID, sessionID) {
                    confirm = SessionMenuItems.killConfirm(host: host, session: session)
                }
            })
    }

    private var collapsed: Set<String> {
        Set(collapsedStorage.split(separator: ",").map(String.init))
    }

    private func toggle(_ key: String) {
        var set = collapsed
        if set.contains(key) { set.remove(key) } else { set.insert(key) }
        collapsedStorage = set.sorted().joined(separator: ",")
    }

    private func move(by step: Int, in snapshot: SidebarSnapshot) -> KeyPress.Result {
        let order = snapshot.selectionOrder
        guard !order.isEmpty else { return .ignored }
        let current = selection.flatMap { sel in order.firstIndex(of: sel) ?? order.firstIndex { $0.sameWindow(as: sel) } }
        let next = current.map { max(0, min(order.count - 1, $0 + step)) } ?? (step > 0 ? 0 : order.count - 1)
        selection = order[next]
        return .handled
    }

    // MARK: Snapshot

    private func makeSnapshot() -> SidebarSnapshot {
        var snap = SidebarSnapshot()
        snap.collapsed = collapsed
        snap.pins = model.pins.map(makePin)
        let agents = SessionTreeView.agentsInDisplayOrder(hosts)
        var number = 0
        for lane in AgentLane.allCases {
            let members = agents.filter { AgentLane.of($0.agent) == lane }
            guard !members.isEmpty else { continue }
            snap.lanes.append(.init(lane: lane, agents: members.map { entry in
                number += 1
                return SidebarSnapshot.Agent(
                    id: entry.id, pane: entry.agent, selection: entry.selection,
                    sessionName: entry.session.name, hostName: entry.host.displayName,
                    isLocal: entry.host.transport.isLocal, folder: entry.window.folder,
                    shortcut: number <= 9 ? number : nil, isHighlighted: justMoved.contains(entry.id))
            }))
        }
        snap.hosts = hosts.map { host in
            SidebarSnapshot.Host(
                id: host.id, name: host.displayName, isLocal: host.transport.isLocal,
                status: host.store.status,
                sessions: host.store.sessions.map { session in
                    SidebarSnapshot.Session(
                        id: session.id, hostID: host.id, name: session.name, windows: session.windows,
                        isPinned: model.isSessionPinned(hostID: host.id, sessionID: session.id),
                        pinnedWindowIDs: Set(session.windows.map(\.id).filter {
                            model.isWindowPinned(hostID: host.id, windowID: $0)
                        }))
                })
        }
        return snap
    }

    private func makePin(_ pin: PinnedItem) -> SidebarSnapshot.Pin {
        let host = hosts.first { $0.id == pin.hostID }
        let session = host?.store.sessions.first { $0.id == pin.sessionID }
            ?? host?.store.sessions.first { $0.name == pin.sessionName }
        let window = pin.windowID.flatMap { id in session?.windows.first { $0.id == id } }
        let resolved = ResolvedPin(pin: pin, host: host, session: session, window: window)
        let shown = window ?? session.flatMap { s in s.windows.first(where: { $0.isActive }) ?? s.windows.first }
        let title: String
        if pin.windowID != nil {
            title = window?.title ?? (pin.windowName?.isEmpty == false ? pin.windowName! : "window \(pin.windowIndex ?? 0)")
        } else {
            title = session?.name ?? pin.sessionName
        }
        var detail = [host?.displayName ?? pin.hostID]
        if pin.windowID != nil { detail.append(session?.name ?? pin.sessionName) }
        if host == nil { detail.append("host removed") }
        else if host?.store.status.isLive != true { detail.append("disconnected") }
        else if session == nil { detail.append("session ended") }
        else if pin.windowID != nil && window == nil { detail.append("window closed") }
        return SidebarSnapshot.Pin(
            id: pin.id, title: title, detail: detail.joined(separator: " · "),
            isWindow: pin.windowID != nil, isLive: resolved.isLive, target: resolved.target,
            agent: shown?.primaryAgent, hasBell: shown?.hasBell ?? false)
    }

    // MARK: Menus

    private func menu(_ target: SidebarMenuTarget) -> AnyView {
        switch target {
        case .host(let id):
            guard let host = hosts.first(where: { $0.id == id }) else { return AnyView(EmptyView()) }
            return AnyView(HostMenuItems(host: host, model: model, prompt: $prompt, confirm: $confirm))
        case .session(let hostID, let sessionID):
            guard let host = hosts.first(where: { $0.id == hostID }),
                  let session = host.store.sessions.first(where: { $0.id == sessionID })
            else { return AnyView(EmptyView()) }
            return AnyView(SessionMenuItems(host: host, model: model, session: session,
                                            prompt: $prompt, confirm: $confirm))
        case .window(let hostID, let sessionID, let windowID, let standsForSession):
            guard let host = hosts.first(where: { $0.id == hostID }),
                  let session = host.store.sessions.first(where: { $0.id == sessionID }),
                  let window = session.windows.first(where: { $0.id == windowID })
            else { return AnyView(EmptyView()) }
            return AnyView(Group {
                WindowMenuItems(host: host, model: model, session: session, window: window,
                                prompt: $prompt, confirm: $confirm)
                if standsForSession {
                    Divider()
                    SessionMenuItems(host: host, model: model, session: session,
                                     prompt: $prompt, confirm: $confirm)
                }
            })
        case .pin(let id):
            guard let index = model.pins.firstIndex(where: { $0.id == id }) else { return AnyView(EmptyView()) }
            let pin = model.pins[index]
            return AnyView(Group {
                Button("Move Up") {
                    model.movePins(fromOffsets: IndexSet(integer: index), toOffset: index - 1)
                }.disabled(index == 0)
                Button("Move Down") {
                    model.movePins(fromOffsets: IndexSet(integer: index), toOffset: index + 2)
                }.disabled(index == model.pins.count - 1)
                Divider()
                Button(pin.windowID == nil ? "Unpin Session" : "Unpin Window") { model.unpin(pin) }
            })
        case .agent(let id):
            guard let entry = AgentEntry.collect(from: hosts).first(where: { $0.id == id })
            else { return AnyView(EmptyView()) }
            return AnyView(Group {
                Button("Show \(entry.agent.kind.displayName)") { selection = entry.selection }
                Divider()
                WindowMenuItems(host: entry.host, model: model, session: entry.session, window: entry.window,
                                prompt: $prompt, confirm: $confirm)
            })
        }
    }
}
