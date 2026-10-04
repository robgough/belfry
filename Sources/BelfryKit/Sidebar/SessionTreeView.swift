import SwiftUI
import CoreText

/// `.help()` tooltips exist on macOS only; elsewhere this is a no-op.
extension View {
    func hoverHint(_ text: String) -> some View {
        modifier(HoverHint(text: text))
    }
}

extension EnvironmentValues {
    /// Turns `hoverHint` tooltips off for a subtree. The Mac's native sidebar
    /// sets it: an AppKit tooltip inside a List row swallows the click, so
    /// clicking a row's text failed to select it.
    @Entry var suppressHoverHints = false
    /// Draw agent badges as plain text glyphs instead of the animated AppKit
    /// layer — for off-screen rendering (ImageRenderer can't draw AppKit views).
    @Entry var staticAgentBadges = false
}

private struct HoverHint: ViewModifier {
    let text: String
    @Environment(\.suppressHoverHints) private var suppressed
    func body(content: Content) -> some View {
        #if os(macOS)
        if suppressed || text.isEmpty { content } else { content.help(text) }
        #else
        content
        #endif
    }
}

/// A small inline text button (`.link` style on macOS, plain elsewhere).
private struct InlineLinkButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        #if os(macOS)
        Button(title, action: action).buttonStyle(.link).font(.caption)
        #else
        Button(title, action: action).font(.caption)
        #endif
    }
}

/// Left sidebar: a Host → Session → Window tree, topped by a Pinned section
/// when anything is pinned and an Agents section when coding agents are
/// running. Each host is a collapsible section; sessions list
/// their windows beneath. Window rows are the selectable leaves (tagged with
/// their host + window id). Right-click rows for actions; text-entry actions
/// raise a `SidebarPrompt`, destructive ones a `ConfirmAction`. Hovering a row
/// reveals its key actions inline (pin / new session / new window / split);
/// everything stays reachable from the context menus too.
struct SessionTreeView: View {
    let hosts: [HostModel]
    let model: AppModel
    @Binding var selection: WindowSelection?
    @Binding var prompt: SidebarPrompt?
    @Binding var confirm: ConfirmAction?
    /// Hosts whose section the user has collapsed (default: all expanded).
    @State private var collapsedHosts: Set<String> = []
    /// The session that owned the last selected window, so a window killed out
    /// from under the selection can hand it to the session's next active window.
    @State private var lastSelectedSession: SessionRef?
    /// The pin currently being dragged to a new spot (macOS custom reorder).
    @State private var draggedPinID: String?
    /// Agent ids at the last lane change — only a reorder of the *same*
    /// agents animates (see `agentReorderAnimation`).
    @State private var lastAgentIDs: Set<String> = []
    /// Agents that just changed lane or moved up, briefly glowing so you can
    /// see which one it was.
    @State private var justMoved: Set<String> = []
    /// Multi-window sessions the user has folded ("<host id>|<session id>").
    @State private var collapsedSessions: Set<String> = []
    /// Whether the Agents section is expanded (remembered across launches).
    @AppStorage("agentsSectionExpanded") private var agentsExpanded = true

    private struct SessionRef: Equatable {
        let hostID: String
        let sessionID: String
    }

    /// Row height: dense on macOS (pointer precision); comfortably tappable
    /// on iOS — 40pt keeps the tree compact while staying close to the 44pt
    /// touch-target guideline (the full row width is the target).
    static var minRowHeight: CGFloat {
        #if os(iOS)
        40
        #else
        26
        #endif
    }

    var body: some View {
        platformList
        // Quick glide when agents change lanes or reorder (rows move rather
        // than jump). Keyed to lane order only, so ordinary refreshes — tool
        // activity, timers — don't animate.
        .animation(agentReorderAnimation, value: agentLaneSignature)
        .onChange(of: agentLaneSignature) { old, new in
            noteMovedAgents(old: old, new: new)
            lastAgentIDs = Set(new)
        }
        #if os(macOS)
        // ⌘1–⌘9 jump to the Nth agent, in the Agents section's order.
        .background { agentShortcuts }
        #endif
        // tmux is authoritative for the active window: switching windows with
        // tmux keys (prefix-n, status-bar clicks) moves the active flag on the
        // next store refresh, and the sidebar selection follows instead of going
        // stale. But only follow when the user was actually *on* the previously
        // active window (`selection == oldTarget`) — i.e. tracking it. Selecting
        // a window in another session recomputes `followTarget` to that session's
        // active window as a side effect; without this guard that immediately
        // snapped the selection to the active window, making non-active (and
        // pinned) windows impossible to open. tmux converges via select-window.
        .onChange(of: followTarget) { oldTarget, target in
            guard let target, !target.sameWindow(as: selection),
                  selection?.sameWindow(as: oldTarget) ?? (oldTarget == nil) else { return }
            selection = target
        }
        .onChange(of: selection, initial: true) { _, sel in
            // An agent row's selection names its pane too: focus it.
            if let sel, let pane = sel.paneID,
               let host = hosts.first(where: { $0.id == sel.hostID }) {
                host.client.selectPane(pane)
            }
            // Tell each host which of its windows is on screen: viewing a
            // window marks its finished agents seen (see TmuxStore).
            for host in hosts {
                host.store.viewedWindowID = sel?.hostID == host.id ? sel?.windowID : nil
            }
            guard let sel,
                  let host = hosts.first(where: { $0.id == sel.hostID }),
                  let session = host.store.sessions.first(where: { $0.windows.contains { $0.id == sel.windowID } })
            else { return }
            lastSelectedSession = SessionRef(hostID: host.id, sessionID: session.id)
        }
        // The tmux session selector (prefix-s / choose-tree) moves the visible
        // surface's *client* to another session, silently breaking the
        // one-surface-per-session invariant. Attached-client counts expose it:
        // the selected session drops one client while another gains one.
        .onChange(of: attachSnapshot) { old, new in
            resolveSurfaceDrift(old: old, new: new)
        }
    }

    /// Both platforms use native List selection. iOS MUST: in a
    /// collapsed NavigationSplitView (iPhone) only a native selection change
    /// pushes the detail column — a custom tap gesture updates state the
    /// split view can't see, leaving the terminal unreachable.
    /// Both platforms draw the custom sidebar (MacSidebar.swift); iOS gets
    /// touch metrics there, and the iPhone shows the terminal on tap via the
    /// `sidebarActivate` environment hook its root view supplies.
    private var platformList: some View {
        MacSidebarContainer(hosts: hosts, model: model, selection: $selection,
                            prompt: $prompt, confirm: $confirm, justMoved: justMoved)
    }

    @ViewBuilder private var treeSections: some View {
        if !model.pins.isEmpty {
            Section {
                ForEach(model.pins) { pin in
                    pinnedRow(for: pin)
                }
                .onMove { source, destination in
                    model.movePins(fromOffsets: source, toOffset: destination)
                }
            } header: {
                PinnedSectionHeader()
                    .modifier(SidebarHeaderChrome())
            }
        }
        let agents = AgentEntry.collect(from: hosts)
        if !agents.isEmpty {
            let items = AgentLaneItem.build(agents)
            let shortcuts = Self.shortcutNumbers(items)
            Section(isExpanded: $agentsExpanded) {
                ForEach(items) { item in
                    laneRow(for: item, shortcut: shortcuts[item.id])
                }
            } header: {
                AgentsSectionHeader(entries: agents, isExpanded: $agentsExpanded)
                    .modifier(SidebarHeaderChrome())
            }
        }
        ForEach(hosts) { host in
            Section(isExpanded: expansionBinding(for: host)) {
                HostBody(host: host, model: model,
                         selection: $selection, prompt: $prompt, confirm: $confirm,
                         collapsedSessions: $collapsedSessions)
            } header: {
                HostHeader(host: host, model: model, isExpanded: expansionBinding(for: host),
                           prompt: $prompt, confirm: $confirm)
                    .modifier(SidebarHeaderChrome())
            }
        }
    }

    // MARK: Agents section

    /// A row of the Agents section's lanes: a lane header, or an agent's card.
    /// Selecting a card shows the agent's window and, on macOS, focuses the
    /// agent's own pane within it (iOS rows select via native List selection,
    /// which only carries the window). Each row paints its slice of the lane's
    /// panel as its row background.
    @ViewBuilder private func laneRow(for item: AgentLaneItem, shortcut: Int?) -> some View {
        switch item {
        case .header(let lane, let count):
            AgentLaneHeader(lane: lane, count: count)
                .listRowBackground(sidebarRowBackground(selected: false, isTop: true,
                                                        gap: lane == AgentLane.allCases.first ? 0 : 6,
                                                        tint: lane.panelTint))
                .modifier(SidebarRowChrome())
        case .agent(let entry, let lane, let isLast):
            let target = entry.selection
            AgentLaneCard(entry: entry, lane: lane, isLast: isLast, isSelected: selection == target,
                          isHighlighted: justMoved.contains(entry.id), shortcut: shortcut)
                .modifier(WindowSelectionTag(target: target))
                .modifier(SelectOnTap {
                    selection = target
                    entry.host.client.selectPane(entry.agent.id)
                })
                .contextMenu {
                    Button("Show \(entry.agent.kind.displayName)") {
                        selection = target
                        entry.host.client.selectPane(entry.agent.id)
                    }
                }
                .listRowBackground(sidebarRowBackground(selected: false, isBottom: isLast,
                                                        tint: lane.panelTint))
                .modifier(SidebarRowChrome())
        }
    }

    #if os(macOS)
    /// Invisible buttons carrying the ⌘1–⌘9 agent shortcuts (key equivalents
    /// reach them even while a terminal has focus).
    @ViewBuilder private var agentShortcuts: some View {
        let agents = Self.agentsInDisplayOrder(hosts)
        ZStack {
            ForEach(Array(agents.prefix(9).enumerated()), id: \.element.id) { index, entry in
                Button("") {
                    selection = entry.selection
                    entry.host.client.selectPane(entry.agent.id)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
    #endif

    /// Agent row id → its ⌘-number (1–9), in display order.
    static func shortcutNumbers(_ items: [AgentLaneItem]) -> [String: Int] {
        var map: [String: Int] = [:]
        var n = 0
        for case .agent(let entry, _, _) in items where n < 9 {
            n += 1
            map[entry.id] = n
        }
        return map
    }

    /// Animate lane changes and reorders only when the same agents are
    /// involved. Agents arriving or leaving — a host connecting brings dozens
    /// of rows at once — update instantly: animating a bulk change through the
    /// sidebar's table is slow enough to stall the window.
    private var agentReorderAnimation: Animation? {
        Set(agentLaneSignature) == lastAgentIDs ? .smooth(duration: 0.3) : nil
    }

    /// Mark agents that changed lane or moved up the list (and existed
    /// before), then let the glow fade after a moment.
    private func noteMovedAgents(old: [String], new: [String]) {
        let oldSet = Set(old)
        guard !oldSet.isEmpty else { return }
        func placement(_ ids: [String]) -> [String: (lane: String, index: Int)] {
            var result: [String: (lane: String, index: Int)] = [:]
            var lane = ""
            var index = 0
            for id in ids {
                if id.hasPrefix("lane-") { lane = id; continue }
                result[id] = (lane, index)
                index += 1
            }
            return result
        }
        let before = placement(old), after = placement(new)
        // Only moves that ask for attention glow: into a more urgent lane, or
        // up within one. Settling down (finished → Quiet) stays quiet.
        func rank(_ lane: String) -> Int {
            AgentLane(rawValue: String(lane.dropFirst("lane-".count)))
                .flatMap { AgentLane.allCases.firstIndex(of: $0) } ?? 0
        }
        let moved = after.compactMap { id, now -> String? in
            guard oldSet.contains(id), let was = before[id] else { return nil }
            if was.lane != now.lane { return rank(now.lane) < rank(was.lane) ? id : nil }
            return now.index < was.index ? id : nil
        }
        guard !moved.isEmpty else { return }
        justMoved.formUnion(moved)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1400))
            withAnimation(.easeOut(duration: 0.8)) { justMoved.subtract(moved) }
        }
    }

    /// Agents in the order the lanes show them (what ⌘1–⌘9 count through).
    static func agentsInDisplayOrder(_ hosts: [HostModel]) -> [AgentEntry] {
        AgentLaneItem.build(AgentEntry.collect(from: hosts)).compactMap {
            if case .agent(let entry, _, _) = $0 { return entry } else { return nil }
        }
    }

    /// Lane membership and order — the list animates whenever it changes, so
    /// agents glide between lanes instead of jumping.
    private var agentLaneSignature: [String] {
        AgentLaneItem.build(AgentEntry.collect(from: hosts)).map(\.id)
    }

    // MARK: Pinned section

    /// Join a pin against live state. tmux ids survive reconnects but not
    /// server restarts, so a session whose id is gone re-resolves by its
    /// (user-chosen, stable) name; windows resolve by id only — index/name
    /// fallbacks would too easily land on the wrong window.
    private func resolve(_ pin: PinnedItem) -> ResolvedPin {
        guard let host = hosts.first(where: { $0.id == pin.hostID }) else {
            return ResolvedPin(pin: pin, host: nil, session: nil, window: nil)
        }
        let session = host.store.sessions.first { $0.id == pin.sessionID }
            ?? host.store.sessions.first { $0.name == pin.sessionName }
        let window = pin.windowID.flatMap { id in session?.windows.first { $0.id == id } }
        return ResolvedPin(pin: pin, host: host, session: session, window: window)
    }

    @ViewBuilder private func pinnedRow(for pin: PinnedItem) -> some View {
        let resolved = resolve(pin)
        let target = resolved.target
        let index = model.pins.firstIndex(where: { $0.id == pin.id })
        PinnedRow(resolved: resolved, unpin: { model.unpin(pin) })
            // Tag with the *unwrapped* target. List(selection:) matches a
            // WindowSelection tag; tagging with the optional directly makes the
            // tag type Optional<WindowSelection>, which never matches — so on
            // iOS (where the tap relies solely on native selection) pinned rows
            // were dead. Non-live pins (target == nil) stay untagged.
            .modifier(WindowSelectionTag(target: target))
            .modifier(SelectOnTap { if let target { selection = target } })
            .modifier(PinDragReorder(pin: pin, resolved: resolved, draggedPinID: $draggedPinID, model: model))
            .contextMenu {
                if let index {
                    Button("Move Up") {
                        model.movePins(fromOffsets: IndexSet(integer: index), toOffset: index - 1)
                    }.disabled(index == 0)
                    Button("Move Down") {
                        model.movePins(fromOffsets: IndexSet(integer: index), toOffset: index + 2)
                    }.disabled(index == model.pins.count - 1)
                    Divider()
                }
                Button(pin.windowID == nil ? "Unpin Session" : "Unpin Window") { model.unpin(pin) }
            }
            .listRowBackground(sidebarRowBackground(selected: target != nil && selection == target,
                                                    isTop: index == 0,
                                                    isBottom: index == model.pins.count - 1))
            .modifier(SidebarRowChrome())
    }

    /// host id → (session id → attached client count), for drift detection.
    private var attachSnapshot: [String: [String: Int]] {
        Dictionary(uniqueKeysWithValues: hosts.map { host in
            (host.id, Dictionary(uniqueKeysWithValues: host.store.sessions.map {
                ($0.id, $0.attachedClients)
            }))
        })
    }

    /// If the selected session's surface client followed the tmux session
    /// selector to another session, retire that surface (its client can't be
    /// steered back — the next visit re-attaches cleanly) and move the sidebar
    /// selection to where the user actually went.
    private func resolveSurfaceDrift(old: [String: [String: Int]], new: [String: [String: Int]]) {
        guard let sel = selection,
              let host = hosts.first(where: { $0.id == sel.hostID }),
              let oldCounts = old[host.id], let newCounts = new[host.id],
              let session = host.store.sessions.first(where: { $0.windows.contains { $0.id == sel.windowID } }),
              host.surfaceStore.workspace(for: session.id) != nil,
              let before = oldCounts[session.id], let after = newCounts[session.id],
              after == before - 1
        else { return }
        // Exactly one other session gained a client in the same refresh —
        // anything else is ambiguous (external attaches/detaches), so leave it.
        let gainers = newCounts.filter { id, count in
            id != session.id && count == (oldCounts[id] ?? 0) + 1
        }
        guard gainers.count == 1, let gainedID = gainers.first?.key else { return }
        host.surfaceStore.deactivate(sessionID: session.id)
        if let target = host.store.sessions.first(where: { $0.id == gainedID }),
           let active = target.windows.first(where: { $0.isActive }) {
            selection = WindowSelection(hostID: host.id, windowID: active.id)
        }
    }

    /// Where the selection *should* sit given current tmux state: the active
    /// window of the selected window's session — or, if the selected window no
    /// longer exists (killed), the active window of the session it belonged to.
    /// Nil when there's nothing to correct toward.
    private var followTarget: WindowSelection? {
        guard let sel = selection, let host = hosts.first(where: { $0.id == sel.hostID }) else { return nil }
        if let session = host.store.sessions.first(where: { $0.windows.contains { $0.id == sel.windowID } }) {
            guard let active = session.windows.first(where: { $0.isActive }) else { return nil }
            return WindowSelection(hostID: host.id, windowID: active.id)
        }
        if let last = lastSelectedSession, last.hostID == sel.hostID,
           let session = host.store.sessions.first(where: { $0.id == last.sessionID }),
           let active = session.windows.first(where: { $0.isActive }) {
            return WindowSelection(hostID: host.id, windowID: active.id)
        }
        return nil
    }

    private func expansionBinding(for host: HostModel) -> Binding<Bool> {
        Binding(
            get: { !collapsedHosts.contains(host.id) },
            set: { expanded in
                if expanded {
                    collapsedHosts.remove(host.id)
                } else {
                    collapsedHosts.insert(host.id)
                }
            }
        )
    }
}

/// The selected window gets a soft theme-accent pill on both platforms;
/// unselected rows are transparent. On iOS the clear background must be
/// EXPLICIT — the grouped-list default otherwise paints every row as a
/// dark rounded card over our themed sidebar background. Replacing the
/// background changes only the visuals, not List-selection mechanics, so
/// iPhone detail navigation keeps working. Shared by the host tree and the
/// Pinned section.
@ViewBuilder func sidebarRowBackground(selected: Bool, isTop: Bool = false, isBottom: Bool = false,
                                       gap: CGFloat = 0, tint: Color? = nil) -> some View {
    SidebarPanelSlice(isTop: isTop, isBottom: isBottom, selected: selected, gap: gap, tint: tint)
}

/// One row's slice of a sidebar group's panel. Every group — Pinned, each
/// agent lane, each host's sessions — is one inset panel in the theme's
/// panel tone: the group's first row draws the rounded top, its last row the
/// rounded bottom, and the rows between plain bands, so consecutive rows read
/// as one container. A tinted panel (the agent lanes that want your eye) adds
/// a faint wash of its colour and a hairline along its outer edge; a selected
/// row adds the soft accent fill inside its band.
struct SidebarPanelSlice: View {
    var isTop = false
    var isBottom = false
    var selected = false
    /// Space above the panel (between consecutive panels in one section).
    var gap: CGFloat = 0
    var tint: Color? = nil
    /// Whether to lay the theme's panel tone under the slice. Off in the Mac's
    /// native sidebar, where the system material shows through the tint.
    var showsBase = true
    /// Whether to draw the tint's hairline outline (off in the native sidebar,
    /// where it doubled up with the system's selection highlight).
    var showsEdge = true
    /// Horizontal insets from the row's edges. The native sidebar matches
    /// the system selection highlight's, so the wash and the selection share
    /// edges.
    var leadingInset: CGFloat = Self.inset
    var trailingInset: CGFloat = Self.inset

    static let radius: CGFloat = 6
    static let inset: CGFloat = 6

    var body: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: isTop ? Self.radius : 0,
            bottomLeadingRadius: isBottom ? Self.radius : 0,
            bottomTrailingRadius: isBottom ? Self.radius : 0,
            topTrailingRadius: isTop ? Self.radius : 0,
            style: .continuous)
        ZStack {
            if showsBase { shape.fill(AppTheme.sidebarPanel) }
            if let tint {
                shape.fill(tint.opacity(0.05))
                if showsEdge {
                    PanelEdge(isTop: isTop, isBottom: isBottom, radius: Self.radius)
                        .stroke(tint.opacity(0.2), lineWidth: 1)
                }
            }
            if selected {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(AppTheme.accent.opacity(0.18))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
            }
        }
        .padding(.top, isTop ? gap : 0)
        .padding(.leading, leadingInset)
        .padding(.trailing, trailingInset)
    }
}

/// The outer edge of one row's slice of a panel: both sides always, plus the
/// rounded top on the first row and the rounded bottom on the last — so a
/// stack of slices strokes one continuous outline with no seams between rows.
private struct PanelEdge: Shape {
    let isTop: Bool
    let isBottom: Bool
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: 0.5, dy: 0)
        let top = isTop ? r.minY + 0.5 : r.minY
        let bottom = isBottom ? r.maxY - 0.5 : r.maxY
        let k = radius
        var p = Path()
        // Left side, down; then the bottom (if this slice ends the panel).
        p.move(to: CGPoint(x: r.minX, y: isTop ? top + k : top))
        if isBottom {
            p.addLine(to: CGPoint(x: r.minX, y: bottom - k))
            p.addQuadCurve(to: CGPoint(x: r.minX + k, y: bottom), control: CGPoint(x: r.minX, y: bottom))
            p.addLine(to: CGPoint(x: r.maxX - k, y: bottom))
            p.addQuadCurve(to: CGPoint(x: r.maxX, y: bottom - k), control: CGPoint(x: r.maxX, y: bottom))
        } else {
            p.addLine(to: CGPoint(x: r.minX, y: bottom))
            p.move(to: CGPoint(x: r.maxX, y: bottom))
        }
        // Right side, up; then the top (if this slice starts the panel).
        if isTop {
            p.addLine(to: CGPoint(x: r.maxX, y: top + k))
            p.addQuadCurve(to: CGPoint(x: r.maxX - k, y: top), control: CGPoint(x: r.maxX, y: top))
            p.addLine(to: CGPoint(x: r.minX + k, y: top))
            p.addQuadCurve(to: CGPoint(x: r.minX, y: top + k), control: CGPoint(x: r.minX, y: top))
        } else {
            p.addLine(to: CGPoint(x: r.maxX, y: top))
        }
        return p
    }
}

/// The section header shared by Pinned, Agents and every host, in the Mac
/// sidebar idiom: a small bold Title Case label (with an optional leading
/// mark) and a summary on the right. No band or icon chip — the panels below
/// carry the structure.
struct SidebarSectionLabel<Leading: View, Trailing: View>: View {
    let title: String
    var tint: Color = .secondary
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            leading
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .textCase(nil)
            Spacer(minLength: 4)
            trailing
                .font(.system(size: 11))
                .textCase(nil)
        }
        .padding(.top, 10)
        .padding(.bottom, 3)
        .padding(.horizontal, 4)
    }
}

/// iOS row chrome: kill the grouped-list separators and the tall default row
/// metrics so the tree reads as one dense sidebar (like the Mac) instead of a
/// stack of boxed table cells. macOS's AppKit sidebar style needs none of it.
struct SidebarRowChrome: ViewModifier {
    /// Shared leading inset for iOS rows and section headers, so both line up.
    /// With the plain list style there's no section margin, so this is the
    /// tree's actual distance from the edge (a little inside the nav title).
    static let leading: CGFloat = 12
    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .listRowSeparator(.hidden)
            // Tight leading inset: it stacks on the sidebar list style's own
            // section margin, so 16 here pushed the whole tree ~26pt in. `Self.leading`
            // lands content near the nav title's edge; the section headers use the
            // same value (SidebarHeaderChrome) so they line up with their rows.
            .listRowInsets(EdgeInsets(top: 3, leading: Self.leading, bottom: 3, trailing: 12))
        #else
        content
        #endif
    }
}

/// iOS section-header chrome: match the rows' leading inset (SidebarRowChrome)
/// so headers line up with their content instead of keeping the sidebar style's
/// wider default header inset. macOS's AppKit sidebar handles headers itself.
struct SidebarHeaderChrome: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: SidebarRowChrome.leading, bottom: 0, trailing: 12))
        #else
        content
        #endif
    }
}

/// macOS-only tap-to-select: iOS rows select natively via List(selection:)
/// (which a collapsed NavigationSplitView needs to push the detail column),
/// and a competing tap gesture there would swallow the row tap.
///
/// Simultaneous (not `.onTapGesture`) because an exclusive tap gesture eats
/// the mouse-down that starts a `.onMove` row drag (FB7367473), which would
/// make the Pinned section un-reorderable.
struct SelectOnTap: ViewModifier {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    func body(content: Content) -> some View {
        #if os(macOS)
        content.simultaneousGesture(TapGesture().onEnded(action))
        #else
        content
        #endif
    }
}

/// Native `List(selection:)` tag for a pinned row. The selection binding is
/// `WindowSelection?`, so its SelectionValue is the *non-optional*
/// `WindowSelection`; a row is only selectable when tagged with that type.
/// `resolved.target` is optional (nil for a non-live pin), and tagging with it
/// directly yields an `Optional<WindowSelection>` tag that silently never
/// matches — which left iOS pinned rows unselectable (tap did nothing). Unwrap
/// here and leave non-live pins untagged.
struct WindowSelectionTag: ViewModifier {
    let target: WindowSelection?
    func body(content: Content) -> some View {
        if let target {
            content.tag(target)
        } else {
            content
        }
    }
}

/// macOS drag-to-reorder for pinned rows. List's built-in `.onMove` never
/// starts a drag here — row gestures and context menus eat the mouse-down
/// (FB7367473) — so the rows implement the drag themselves: each is a drag
/// source and a drop target, and dragging over a row live-moves the dragged
/// pin into its slot. iOS keeps the native `.onMove` long-press drag instead
/// (`onDrag` there would fight the context-menu long-press).
private struct PinDragReorder: ViewModifier {
    let pin: PinnedItem
    let resolved: ResolvedPin
    @Binding var draggedPinID: String?
    let model: AppModel
    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .onDrag {
                draggedPinID = pin.id
                return NSItemProvider(object: pin.id as NSString)
            } preview: {
                // Without this, the system preview is the row's text snapshot
                // floating with no backing, which reads as broken. Solid theme
                // background — materials blur whatever is behind the drag and
                // render oddly mid-flight.
                PinnedRow(resolved: resolved, unpin: {})
                    .padding(.horizontal, 10)
                    .frame(width: 230)
                    .background(AppTheme.sidebarBackground, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                    .environment(\.colorScheme, AppTheme.colorScheme)
            }
            .onDrop(of: [.text], delegate: PinReorderDropDelegate(
                pin: pin, draggedPinID: $draggedPinID, model: model))
        #else
        content
        #endif
    }
}

#if os(macOS)
private struct PinReorderDropDelegate: DropDelegate {
    let pin: PinnedItem
    @Binding var draggedPinID: String?
    let model: AppModel

    /// Reorder as the drag passes over each row (live shuffle), so the drop
    /// itself has nothing left to do.
    func dropEntered(info: DropInfo) {
        guard let draggedID = draggedPinID, draggedID != pin.id,
              let from = model.pins.firstIndex(where: { $0.id == draggedID }),
              let to = model.pins.firstIndex(where: { $0.id == pin.id })
        else { return }
        withAnimation {
            model.movePins(fromOffsets: IndexSet(integer: from),
                           toOffset: to > from ? to + 1 : to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        draggedPinID = nil
        return true
    }
}
#endif

/// Whether row/header action buttons show only on pointer hover (macOS) or
/// always (iOS — nothing hovers on touch).
@inline(__always) private func actionsVisible(hovered: Bool) -> Bool {
    #if os(iOS)
    true
    #else
    hovered
    #endif
}

/// A small icon button that appears on row hover (borderless, so clicking it
/// doesn't select the row).
private struct HoverIconButton: View {
    let systemName: String
    let hint: String
    let action: () -> Void

    /// Pointer targets can be small; fingers need room (≥ ~28pt hit area on
    /// iOS, with a slightly larger glyph so it doesn't float in space).
    static var iconSize: CGFloat {
        #if os(iOS)
        13
        #else
        10.5
        #endif
    }
    static var hitSize: CGSize {
        #if os(iOS)
        CGSize(width: 30, height: 30)
        #else
        CGSize(width: 18, height: 16)
        #endif
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: Self.iconSize, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: Self.hitSize.width, height: Self.hitSize.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .hoverHint(hint)
    }
}

private struct HostHeader: View {
    let host: HostModel
    let model: AppModel
    @Binding var isExpanded: Bool
    @Binding var prompt: SidebarPrompt?
    @Binding var confirm: ConfirmAction?
    @State private var isHovered = false

    var body: some View {
        SidebarSectionLabel(title: host.displayName,
                            tint: AppTheme.hostTint(isLocal: host.transport.isLocal)) {
            HostStatusDot(status: host.store.status)
        } trailing: {
            // Hover swaps the summary for the host's actions (same slot).
            ZStack(alignment: .trailing) {
                if let subtitle {
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                        .opacity(actionsVisible(hovered: isHovered) ? 0 : 1)
                }
                HStack(spacing: 2) {
                    HoverIconButton(systemName: "plus",
                                    hint: "New session on \(host.displayName)") {
                        prompt = .newSession(host: host)
                    }
                    if host.canDisconnect {
                        switch host.store.status {
                        case .connected, .connecting, .reconnecting, .waitingForNetwork:
                            HoverIconButton(systemName: "power",
                                            hint: "Disconnect (sessions keep running)") {
                                host.disconnect()
                            }
                        case .disconnected, .offline:
                            HoverIconButton(systemName: "power",
                                            hint: "Connect to \(host.displayName)") {
                                host.reconnect()
                            }
                        }
                    }
                    #if os(iOS)
                    // Section headers don't get long-press context menus on iOS, so the
                    // host actions (Disconnect/Connect, Remove…) need a visible button.
                    Menu {
                        menu
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                    }
                    #endif
                }
                .opacity(actionsVisible(hovered: isHovered) ? 1 : 0)
                .allowsHitTesting(actionsVisible(hovered: isHovered))
            }
            // Leave room for the sidebar section's hover disclosure chevron.
            .padding(.trailing, 16)
        }
        .contentShape(Rectangle())
        // The whole machine line toggles its sessions — quicker than hunting
        // the little chevron. The hover buttons still win over the tap.
        .onTapGesture { isExpanded.toggle() }
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .contextMenu { menu }
    }

    /// "11 sessions" while connected; hidden when empty or down (the status
    /// row below the header explains those states).
    private var subtitle: String? {
        guard host.store.status.isLive, !host.store.sessions.isEmpty else { return nil }
        let sessions = host.store.sessions.count
        return "\(sessions) session\(sessions == 1 ? "" : "s")"
    }

    @ViewBuilder private var menu: some View {
        HostMenuItems(host: host, model: model, prompt: $prompt, confirm: $confirm)
    }
}

/// A host's context-menu items: new session, agent-status hooks, connect /
/// disconnect, remove. Shared by the iOS sidebar's host header and the Mac's
/// native sidebar.
struct HostMenuItems: View {
    let host: HostModel
    let model: AppModel
    @Binding var prompt: SidebarPrompt?
    @Binding var confirm: ConfirmAction?

    var body: some View {
        Button("New Session…") { prompt = .newSession(host: host) }
        Divider()
        agentHooksItems
        if host.canDisconnect {
            Divider()
            switch host.store.status {
            case .connected, .connecting, .reconnecting, .waitingForNetwork:
                Button("Disconnect") { host.disconnect() }
            case .disconnected, .offline:
                Button("Connect") { host.reconnect() }
            }
            Button("Remove Host", role: .destructive) {
                confirm = ConfirmAction(
                    title: "Remove “\(host.displayName)”?",
                    message: "Removes the host from Belfry. Its remote sessions keep running.",
                    confirmLabel: "Remove") { model.removeHost(host) }
            }
        }
    }
    /// Agent-status-hook state + install action for this host (Claude Code,
    /// Codex, OpenCode, pi, omp — whichever are installed there).
    @ViewBuilder private var agentHooksItems: some View {
        // Transports without a hooks manager (iOS, for now) hide this entirely.
        if !host.supportsHooksManagement {
            EmptyView()
        // Managing remote hooks needs the SSH link; local always works.
        } else if !(host.transport.isLocal || host.store.status.isLive) {
            Button("Agent status hooks (connect to manage)") {}.disabled(true)
        } else {
            switch host.hooksStatus {
            case .installed:
                Button { } label: { Label("Agent status hooks installed", systemImage: "checkmark.circle") }
                    .disabled(true)
                Button("Reinstall Agent Status Hooks") { host.installHooks() }
                Button("Remove Agent Status Hooks", role: .destructive) { host.removeHooks() }
            case .notInstalled:
                Button("Install Agent Status Hooks…") { host.installHooks() }
            case .checking:
                Button("Checking agent hooks…") {}.disabled(true)
            case .installing:
                Button("Installing agent hooks…") {}.disabled(true)
            case .removing:
                Button("Removing agent hooks…") {}.disabled(true)
            case .error(let message):
                Button { } label: { Label(message, systemImage: "exclamationmark.triangle") }
                    .disabled(true)
                Button("Re-check Agent Hooks") { host.checkHooks() }
            case .unknown:
                Button("Check for Agent Status Hooks") { host.checkHooks() }
            }
        }
    }
}

private struct HostBody: View {
    let host: HostModel
    let model: AppModel
    @Binding var selection: WindowSelection?
    @Binding var prompt: SidebarPrompt?
    @Binding var confirm: ConfirmAction?
    @Binding var collapsedSessions: Set<String>

    /// The host's rows, flattened so each knows whether it opens or closes
    /// the host's panel. A session with one window is a single row (session
    /// and window are the same thing to you); a session with several gets a
    /// foldable header with its windows beneath.
    private enum Row: Identifiable {
        case header(TmuxSession)
        case window(TmuxSession, TmuxWindow, merged: Bool)
        var id: String {
            switch self {
            case .header(let s): "s\(s.id)"
            case .window(_, let w, _): "w\(w.id)"
            }
        }
    }

    private var rows: [Row] {
        var rows: [Row] = []
        for session in host.store.sessions {
            if session.windows.count == 1, let only = session.windows.first {
                rows.append(.window(session, only, merged: true))
                continue
            }
            rows.append(.header(session))
            if !isCollapsed(session) {
                rows += session.windows.map { .window(session, $0, merged: false) }
            }
        }
        return rows
    }

    private func key(_ session: TmuxSession) -> String { "\(host.id)|\(session.id)" }
    private func isCollapsed(_ session: TmuxSession) -> Bool { collapsedSessions.contains(key(session)) }

    var body: some View {
        let rows = rows
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            let isTop = index == 0
            let isBottom = index == rows.count - 1
            switch row {
            case .header(let session):
                SessionHeader(host: host, session: session,
                              isPinned: model.isSessionPinned(hostID: host.id, sessionID: session.id),
                              isCollapsed: isCollapsed(session),
                              toggleCollapsed: {
                                  withAnimation(.snappy(duration: 0.25)) {
                                      if isCollapsed(session) { collapsedSessions.remove(key(session)) }
                                      else { collapsedSessions.insert(key(session)) }
                                  }
                              },
                              togglePin: { model.togglePin(host: host, session: session) },
                              kill: { confirm = killSessionConfirm(session) })
                    .contextMenu { sessionMenu(session) }
                    .listRowBackground(sidebarRowBackground(selected: false, isTop: isTop, isBottom: isBottom))
                    .modifier(SidebarRowChrome())
            case .window(let session, let window, let merged):
                let windowSelection = WindowSelection(hostID: host.id, windowID: window.id)
                WindowRow(host: host, window: window, session: merged ? session : nil,
                          isPinned: merged
                              ? model.isSessionPinned(hostID: host.id, sessionID: session.id)
                              : model.isWindowPinned(hostID: host.id, windowID: window.id),
                          togglePin: {
                              if merged { model.togglePin(host: host, session: session) }
                              else { model.togglePin(host: host, session: session, window: window) }
                          },
                          kill: { confirm = merged ? killSessionConfirm(session) : killWindowConfirm(session, window) })
                    .tag(windowSelection)   // iOS native selection (pushes detail on iPhone)
                    .modifier(SelectOnTap { selection = windowSelection })
                    .contextMenu {
                        windowMenu(session, window)
                        if merged {
                            Divider()
                            sessionMenu(session)
                        }
                    }
                    .listRowBackground(sidebarRowBackground(selected: selection == windowSelection,
                                                            isTop: isTop, isBottom: isBottom))
                    .modifier(SidebarRowChrome())
            }
        }
        if host.store.sessions.isEmpty {
            HostStatusRow(host: host)
                .padding(.horizontal, 4)
                .listRowBackground(sidebarRowBackground(selected: false, isTop: true, isBottom: true))
                .modifier(SidebarRowChrome())
        }
    }

    private func killSessionConfirm(_ session: TmuxSession) -> ConfirmAction {
        SessionMenuItems.killConfirm(host: host, session: session)
    }

    private func killWindowConfirm(_ session: TmuxSession, _ window: TmuxWindow) -> ConfirmAction {
        WindowMenuItems.killConfirm(host: host, window: window)
    }

    @ViewBuilder private func sessionMenu(_ session: TmuxSession) -> some View {
        SessionMenuItems(host: host, model: model, session: session, prompt: $prompt, confirm: $confirm)
    }

    @ViewBuilder private func windowMenu(_ session: TmuxSession, _ window: TmuxWindow) -> some View {
        WindowMenuItems(host: host, model: model, session: session, window: window,
                        prompt: $prompt, confirm: $confirm)
    }
}

/// A session's context-menu items (new window, rename, pin, kill).
struct SessionMenuItems: View {
    let host: HostModel
    let model: AppModel
    let session: TmuxSession
    @Binding var prompt: SidebarPrompt?
    @Binding var confirm: ConfirmAction?

    static func killConfirm(host: HostModel, session: TmuxSession) -> ConfirmAction {
        ConfirmAction(
            title: "Kill session “\(session.name)”?",
            message: "Ends the session and all its windows on \(host.displayName).",
            confirmLabel: "Kill") { host.client.killSession(id: session.id) }
    }

    var body: some View {
        Button("New Window") { host.client.newWindow(inSession: session.id) }
        Button("Rename Session…") { prompt = .renameSession(host: host, session: session) }
        Button(model.isSessionPinned(hostID: host.id, sessionID: session.id)
               ? "Unpin Session" : "Pin Session") {
            model.togglePin(host: host, session: session)
        }
        Divider()
        Button("Kill Session", role: .destructive) { confirm = Self.killConfirm(host: host, session: session) }
    }
}

/// A window's context-menu items (splits, rename, new window, pin, kill).
struct WindowMenuItems: View {
    let host: HostModel
    let model: AppModel
    let session: TmuxSession
    let window: TmuxWindow
    @Binding var prompt: SidebarPrompt?
    @Binding var confirm: ConfirmAction?

    static func killConfirm(host: HostModel, window: TmuxWindow) -> ConfirmAction {
        ConfirmAction(
            title: "Kill window “\(window.name.isEmpty ? "window \(window.index)" : window.name)”?",
            message: "Closes the window on \(host.displayName).",
            confirmLabel: "Kill") { host.client.killWindow(id: window.id) }
    }

    var body: some View {
        Button {
            host.client.splitWindow(id: window.id, horizontal: true)
        } label: {
            Label("Split Left / Right", systemImage: "rectangle.split.2x1")
        }
        Button {
            host.client.splitWindow(id: window.id, horizontal: false)
        } label: {
            Label("Split Top / Bottom", systemImage: "rectangle.split.1x2")
        }
        Divider()
        Button("Rename Window…") { prompt = .renameWindow(host: host, window: window) }
        Button("New Window") { host.client.newWindow(inSession: session.id) }
        Button(model.isWindowPinned(hostID: host.id, windowID: window.id)
               ? "Unpin Window" : "Pin Window") {
            model.togglePin(host: host, session: session, window: window)
        }
        Divider()
        Button("Kill Window", role: .destructive) { confirm = Self.killConfirm(host: host, window: window) }
    }
}

/// A pin joined against live tmux state. `session`/`window` are nil while the
/// pinned thing isn't reachable (host down, session ended, window closed); the
/// row then renders dimmed from the pin's cached names instead of vanishing,
/// so pins survive disconnects and tmux-server restarts and re-light when the
/// target comes back.
@MainActor
struct ResolvedPin {
    let pin: PinnedItem
    let host: HostModel?
    let session: TmuxSession?
    let window: TmuxWindow?

    /// Live = selectable: the host link is up and the pinned session (and
    /// window, for window pins) exists right now.
    var isLive: Bool {
        guard let host, host.store.status.isLive, session != nil else { return false }
        return pin.windowID == nil || window != nil
    }

    /// What selecting the row shows: the pinned window, or the session's
    /// active window for session pins.
    var target: WindowSelection? {
        guard isLive, let host, let session else { return nil }
        if pin.windowID != nil {
            guard let window else { return nil }
            return WindowSelection(hostID: host.id, windowID: window.id)
        }
        guard let active = session.windows.first(where: { $0.isActive }) ?? session.windows.first
        else { return nil }
        return WindowSelection(hostID: host.id, windowID: active.id)
    }
}

/// The Pinned section's header, in the shared light style.
private struct PinnedSectionHeader: View {
    var body: some View {
        SidebarSectionLabel(title: "Pinned") {
            Image(systemName: "pin.fill")
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(.secondary)
        } trailing: {
            EmptyView()
        }
    }
}

/// A row in the Pinned section. It appears outside its host grouping, so it
/// carries its own context: machine name and session (for window pins), the
/// agent's session name when a coding agent is running there, and the active
/// pane's working directory on its own line. Pins are the working set, so the
/// row runs slightly larger than the tree's. Unresolved pins stay in place
/// dimmed — unpin them here, or leave them to re-resolve when the target
/// returns.
private struct PinnedRow: View {
    let resolved: ResolvedPin
    let unpin: () -> Void
    @State private var pinHovered = false
    @State private var rowHovered = false

    var body: some View {
        HStack(spacing: 7) {
            // The pin glyph is itself the unpin button (borderless, like
            // HoverIconButton, so tapping it doesn't select the row).
            Button(action: unpin) {
                Image(systemName: pinHovered ? "pin.slash" : "pin.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(resolved.isLive && !pinHovered ? AppTheme.accent : Color.secondary)
                    .frame(width: 16, height: 15)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .onHover { pinHovered = $0 }
            .hoverHint("Unpin “\(title)”")
            VStack(alignment: .leading, spacing: 1.5) {
                HStack(spacing: 5) {
                    // Window pins and session pins read differently — a
                    // session pin follows its session's *active* window — so
                    // say which kind this is (same glyph vocabulary as the
                    // toolbar's window switcher).
                    Image(systemName: resolved.pin.windowID != nil ? "macwindow" : "rectangle.stack")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .hoverHint(resolved.pin.windowID != nil
                                   ? "Pinned window"
                                   : "Pinned session — shows its active window")
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                if let agentTitle {
                    Text(agentTitle)
                        .lineLimit(1)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppTheme.accent)
                        .hoverHint(agentTitleHint)
                }
                contextText
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let pathLine {
                    Text(pathLine)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
            // The leading pin glyph is the unpin control, so the trailing
            // slot keeps the status badges full-time. Key off `contextWindow`,
            // not `resolved.window`: session pins have no window of their own,
            // so `resolved.window` is nil and their badge silently vanished —
            // even though the agent *title* line above (also `contextWindow`)
            // still showed. Now both track the session's active window together.
            // .fixedSize stops the greedy multi-line text column from
            // compressing the icon-only badge off the row's trailing edge.
            if let window = contextWindow {
                WindowBadges(window: window)
                    .fixedSize()
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.primary.opacity(rowHovered ? 0.05 : 0))
        )
        .contentShape(Rectangle())
        .onHover { rowHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: rowHovered)
        .opacity(resolved.isLive ? 1 : 0.55)
        .animation(.easeOut(duration: 0.12), value: pinHovered)
    }

    private var title: String {
        if resolved.pin.windowID != nil {
            if let window = resolved.window {
                return window.name.isEmpty ? "window \(window.index)" : window.name
            }
            if let cached = resolved.pin.windowName, !cached.isEmpty { return cached }
            return "window \(resolved.pin.windowIndex ?? 0)"
        }
        return resolved.session?.name ?? resolved.pin.sessionName
    }

    /// "host · session" (window pins) or "host" (session pins), with a
    /// why-it's-dimmed note appended while unresolved. The host segment is
    /// tinted local/remote (an unresolvable host keeps the row's secondary).
    private var contextText: Text {
        var text = Text(resolved.host?.displayName ?? resolved.pin.hostID)
        if let host = resolved.host {
            text = text.foregroundStyle(AppTheme.hostTint(isLocal: host.transport.isLocal))
        }
        var rest: [String] = []
        if resolved.pin.windowID != nil {
            rest.append(resolved.session?.name ?? resolved.pin.sessionName)
        }
        if let note = staleNote {
            rest.append(note)
        }
        if !rest.isEmpty {
            text = text + Text(" · " + rest.joined(separator: " · "))
        }
        return text
    }

    /// The working directory on its own line (~-abbreviated); hidden while a
    /// stale note explains the row instead.
    private var pathLine: String? {
        guard staleNote == nil, let path = currentPath else { return nil }
        return abbreviateHomePath(path)
    }

    /// The agent session name running in the pinned window (session pins
    /// report their context window's) — e.g. Claude Code's "belfry-a2" — or,
    /// failing that, its task summary. Nil when no agent is running there.
    private var agentTitle: String? {
        guard let agent = contextWindow?.primaryAgent else { return nil }
        if !agent.name.isEmpty { return agent.name }
        return agent.summary.isEmpty ? nil : agent.summary
    }

    private var agentTitleHint: String {
        guard let agent = contextWindow?.primaryAgent else { return "" }
        return agent.name.isEmpty ? "\(agent.kind.displayName): \(agent.summary)"
                                  : "\(agent.kind.displayName) session “\(agent.name)”"
    }

    private var staleNote: String? {
        guard let host = resolved.host else { return "host removed" }
        guard host.store.status.isLive else { return "disconnected" }
        if resolved.session == nil { return "session ended" }
        if resolved.pin.windowID != nil && resolved.window == nil { return "window closed" }
        return nil
    }

    /// The window whose live state contextualizes the row: the pinned window,
    /// or the session's active window for session pins.
    private var contextWindow: TmuxWindow? {
        resolved.window
            ?? resolved.session.flatMap { s in s.windows.first(where: { $0.isActive }) ?? s.windows.first }
    }

    /// The context window's working directory ("" from tmux means unknown).
    private var currentPath: String? {
        guard let path = contextWindow?.currentPath, !path.isEmpty else { return nil }
        return path
    }
}

/// Connection state → theme tint, shared by the host chip and the group rail
/// so the machine and its sessions visibly belong together.
extension ConnectionStatus {
    var tint: Color {
        switch self {
        case .connected: return AppTheme.statusGood
        case .connecting, .reconnecting, .disconnected, .waitingForNetwork: return AppTheme.statusWarn
        case .offline: return Color.secondary
        }
    }
}

/// The host's connection state as a small dot beside its name (hover for the
/// exact status), in the terminal theme's own green/amber.
struct HostStatusDot: View {
    let status: ConnectionStatus
    var body: some View {
        Circle()
            .fill(status.tint)
            .frame(width: 6, height: 6)
            .hoverHint(statusText)
    }
    private var statusText: String {
        switch status {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .reconnecting(let n): return "Reconnecting… (attempt \(n))"
        case .disconnected: return "Connection lost"
        case .waitingForNetwork: return "Waiting for network"
        case .offline: return "Disconnected"
        }
    }
}

struct HostStatusRow: View {
    let host: HostModel
    var body: some View {
        switch host.store.status {
        case .connecting:
            Label("Connecting…", systemImage: "ellipsis.circle")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        case .reconnecting(let attempt):
            Label("Reconnecting… (\(attempt))", systemImage: "arrow.clockwise")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        case .connected:
            Text("No sessions").font(.system(size: 11)).foregroundStyle(.secondary)
        case .disconnected(let reason):
            // Reasons are real ssh/shell diagnostics and easily outgrow the
            // sidebar: wrap a few lines, and carry the full text in a tooltip.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(.orange)
                    .lineLimit(3)
                    .help(reason)
                InlineLinkButton(title: "Reconnect") { host.reconnect() }
            }
        case .waitingForNetwork:
            Label("Waiting for network", systemImage: "wifi.slash")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        case .offline:
            HStack(spacing: 6) {
                Text("Disconnected").font(.system(size: 11)).foregroundStyle(.secondary)
                InlineLinkButton(title: "Connect") { host.reconnect() }
            }
        }
    }
}

/// A multi-window session's header: a disclosure chevron and the session's
/// name as a small label over its windows. Folded, it still says what's
/// inside — the most urgent agent's glyph and how many windows.
private struct SessionHeader: View {
    let host: HostModel
    let session: TmuxSession
    let isPinned: Bool
    let isCollapsed: Bool
    let toggleCollapsed: () -> Void
    let togglePin: () -> Void
    let kill: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                .frame(width: 16)
            Text(session.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            ZStack(alignment: .trailing) {
                summary
                    .opacity(actionsVisible(hovered: isHovered) ? 0 : 1)
                HStack(spacing: 2) {
                    HoverIconButton(systemName: isPinned ? "pin.slash" : "pin",
                                    hint: isPinned ? "Unpin “\(session.name)”"
                                                   : "Pin “\(session.name)” to the top of the sidebar",
                                    action: togglePin)
                    HoverIconButton(systemName: "plus.square.on.square",
                                    hint: "New window in “\(session.name)”") {
                        host.client.newWindow(inSession: session.id)
                    }
                    HoverIconButton(systemName: "xmark",
                                    hint: "Kill session “\(session.name)”…", action: kill)
                }
                .opacity(actionsVisible(hovered: isHovered) ? 1 : 0)
                .allowsHitTesting(actionsVisible(hovered: isHovered))
            }
        }
        .padding(.top, 5)
        .padding(.bottom, 1)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggleCollapsed)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    /// Folded: the most urgent agent inside, then the window count.
    @ViewBuilder private var summary: some View {
        HStack(spacing: 5) {
            if isCollapsed, let agent = session.windows.compactMap(\.primaryAgent)
                .max(by: { $0.state.urgency < $1.state.urgency }) {
                AgentBadge(state: agent.state, kind: agent.kind, title: agent.name, unseen: agent.finishedUnseen)
            }
            Text("\(session.windows.count)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }
}

/// A window — or, for a one-window session, the session itself (`session`
/// set): an SF Symbol for what's running in a fixed icon column, a title
/// that says what the window *is* (see `TmuxWindow.title`) with its folder
/// dimmed beside it, and the status badges on the right. The tmux index sits
/// faintly at the end, like a shortcut hint. Hovering highlights the row and
/// swaps the badges for its actions.
private struct WindowRow: View {
    let host: HostModel
    let window: TmuxWindow
    /// Set when this row stands for a whole one-window session.
    var session: TmuxSession? = nil
    let isPinned: Bool
    let togglePin: () -> Void
    let kill: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: window.symbol)
                .font(.system(size: 11))
                .foregroundStyle(window.isActive || session != nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                .frame(width: 16)
            titleText
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            // Hover swaps the status badges for the actions (they share the
            // trailing slot); badges come back when the pointer leaves.
            ZStack(alignment: .trailing) {
                badges
                    .opacity(isHovered ? 0 : 1)
                actions
                    .opacity(isHovered ? 1 : 0)
                    .allowsHitTesting(isHovered)
            }
        }
        .padding(.leading, session == nil ? 12 : 0)
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.primary.opacity(isHovered ? 0.05 : 0))
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    /// One-window session: the session's name, then what the window is.
    /// Window: its title, then its folder.
    private var titleText: Text {
        if let session {
            let detail = window.title == session.name ? window.titleDetail : window.title
            return Text(session.name).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary)
                + Text(detail.isEmpty ? "" : "  \(detail)").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        let detail = window.titleDetail
        return Text(window.title)
            .font(.system(size: 13, weight: window.isActive ? .medium : .regular))
            .foregroundStyle(window.isActive ? .primary : .secondary)
            + Text(detail.isEmpty ? "" : "  \(detail)").font(.system(size: 11)).foregroundStyle(.tertiary)
    }

    private var badges: some View {
        HStack(spacing: 6) {
            if isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .hoverHint("Pinned to the top of the sidebar")
            }
            WindowBadges(window: window)
            if session == nil {
                Text("\(window.index)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(window.isActive ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary))
                    .hoverHint(window.isActive ? "Active window (index \(window.index))" : "Window index \(window.index)")
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 2) {
            HoverIconButton(systemName: isPinned ? "pin.slash" : "pin",
                            hint: isPinned ? "Unpin" : "Pin to the top of the sidebar",
                            action: togglePin)
            if let session {
                HoverIconButton(systemName: "plus.square.on.square",
                                hint: "New window in “\(session.name)”") {
                    host.client.newWindow(inSession: session.id)
                }
            }
            HoverIconButton(systemName: "rectangle.split.2x1",
                            hint: "Split left / right") {
                host.client.splitWindow(id: window.id, horizontal: true)
            }
            HoverIconButton(systemName: "rectangle.split.1x2",
                            hint: "Split top / bottom") {
                host.client.splitWindow(id: window.id, horizontal: false)
            }
            HoverIconButton(systemName: "xmark",
                            hint: session == nil ? "Kill this window…" : "Kill session “\(session!.name)”…",
                            action: kill)
        }
    }
}

/// Status badges shared by tree window rows and pinned window rows: the bell,
/// the agent state chip, or the unseen-activity dot.
struct WindowBadges: View {
    let window: TmuxWindow
    var body: some View {
        HStack(spacing: 5) {
            if window.hasBell {
                Image(systemName: "bell.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(AppTheme.statusWarn)
                    .hoverHint("Bell rang in this window")
            }
            if let agent = window.primaryAgent {
                AgentBadge(state: agent.state, kind: agent.kind, title: agent.name,
                           unseen: agent.finishedUnseen)
            } else if window.hasActivity {
                Circle().fill(AppTheme.statusWarn).frame(width: 5, height: 5)
                    .hoverHint("Unseen activity")
            }
        }
    }
}

/// The full braille cell; the still/pulsing states light every dot.
private let brailleFullCell = "⣿"
/// The spinner: a hole orbiting the full 4-row cell clockwise.
private let brailleSpinnerFrames = ["⣷", "⣯", "⣟", "⡿", "⢿", "⣻", "⣽", "⣾"]

/// Agent status glyph (Claude Code, Codex, OpenCode, pi…). A single braille
/// visual language, keyed by colour and motion: `.working` an accent spinner
/// (hole orbiting the cell); `.background` the same spinner in purple (the turn
/// ended but background tasks/agents are still running); `.idle` a still green
/// cell — nothing pending; `.waiting` a pulsing orange cell — the agent is
/// actively waiting for your input (e.g. a permission prompt), the state that
/// also badges the Dock; `.error` a still red cell — the turn ended on an error;
/// `.running` a still grey cell (no hooks reporting, so live state is unknown).
///
/// Icon-only, no capsule or word: the glyph stands on its own everywhere — the
/// sidebar rows, the Agents section and the toolbar's now-playing readout.
struct AgentBadge: View {
    let state: AgentState
    var kind: AgentKind = .claude
    /// The agent's session name, appended to the tooltip when known; "" hides it.
    var title: String = ""
    /// Finished while you weren't looking (see `AgentPane.finishedUnseen`).
    var unseen = false
    private let glyphPointSize: CGFloat = 14
    var body: some View {
        let name = kind.displayName
        switch state {
        case .none:
            EmptyView()
        case .running:
            cell(.secondary, glyphs: [brailleFullCell],
                 tip: "\(name) is running here — install agent status hooks for live Working / Idle / Waiting status")
        case .working:
            cell(.accentColor, glyphs: brailleSpinnerFrames, tip: "\(name) is working")
        case .background:
            cell(.purple, glyphs: brailleSpinnerFrames,
                 tip: "\(name)'s turn ended, but background tasks or agents are still running — it will resume on its own")
        case .idle:
            cell(AppTheme.statusGood, glyphs: [brailleFullCell],
                 tip: unseen ? "\(name) finished — you haven't looked yet" : "\(name) finished its turn — nothing pending")
        case .waiting:
            cell(.orange, glyphs: [brailleFullCell], pulses: true,
                 tip: "\(name) is waiting for your input")
        case .error:
            cell(AppTheme.statusBad, glyphs: [brailleFullCell],
                 tip: "\(name)'s turn ended on an error")
        }
    }

    /// A braille badge — a static cell, a pulsing cell, or (with >1 glyph) the
    /// cycling spinner — tinted and tooltipped. The view carries its own colour
    /// and size, so no font/foregroundStyle is needed here.
    @Environment(\.staticAgentBadges) private var staticBadges

    @ViewBuilder
    private func cell(_ color: Color, glyphs: [String], pulses: Bool = false, tip: String) -> some View {
        if staticBadges {
            Text(glyphs.first ?? brailleFullCell)
                .font(.system(size: glyphPointSize, design: .monospaced))
                .foregroundStyle(color)
                .frame(width: glyphPointSize * 0.8, height: glyphPointSize * 1.2)
        } else {
            animatedCell(color, glyphs: glyphs, pulses: pulses, tip: tip)
        }
    }

    private func animatedCell(_ color: Color, glyphs: [String], pulses: Bool, tip: String) -> some View {
        BrailleBadge(color: color, pointSize: glyphPointSize, glyphs: glyphs, pulses: pulses)
            // The glyphs are pre-rendered bitmaps: rebuild them on a theme change.
            .id(ThemeStore.shared.selectedID)
            .hoverHint(title.isEmpty ? tip : "\(tip) — session “\(title)”")
    }
}

/// The repeating badge animation, shared by both platforms: a CABasicAnimation
/// breathing a layer's opacity between 1 and 0.35.
private func makePulseAnimation() -> CABasicAnimation {
    let animation = CABasicAnimation(keyPath: "opacity")
    animation.fromValue = 1.0
    animation.toValue = 0.35
    animation.duration = 0.7
    animation.autoreverses = true
    animation.repeatCount = .infinity
    return animation
}

/// Weakly-bound `CAAnimation` delegate. Core Animation removes a layer's
/// animations on plenty of occasions the view never gets a lifecycle callback
/// for — cell recycling inside a List, a snapshot for the app switcher, a
/// transaction that rebuilds the render tree — leaving the spinner frozen on its
/// last frame with nothing to reinstall it. `animationDidStop` fires whenever the
/// loop is pulled, so the view can restart it. The closure captures the view
/// weakly: the layer → animation → delegate chain must not retain-cycle it.
private final class AnimationRestarter: NSObject, CAAnimationDelegate {
    private let onStop: () -> Void
    init(_ onStop: @escaping () -> Void) { self.onStop = onStop }
    func animationDidStop(_ anim: CAAnimation, finished: Bool) { onStop() }
}

/// Render braille `glyphs` to tinted bitmaps of `pixelSize`, each centred in the
/// cell. Pure Core Graphics / Core Text, shared by both platforms: draw straight
/// into a CGContext (native y-up, matching Core Text) and place the baseline from
/// the full cell's ink mid-point, so the glyph is upright and centred — the same
/// approach the PNG-verified spinner used. `font` is the platform monospaced
/// system font, passed via the `.font` attribute (CTLine ignores `.foregroundColor`,
/// hence the context fill + `kCTForegroundColorFromContextAttributeName`).
private func renderBrailleImages(_ glyphs: [String], font: Any, cgColor: CGColor,
                                 pixelSize: CGSize) -> [CGImage] {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
    ]
    let cellInk = CTLineGetImageBounds(
        CTLineCreateWithAttributedString(NSAttributedString(string: brailleFullCell, attributes: attributes)),
        nil)
    let textPosition = CGPoint(x: pixelSize.width / 2 - cellInk.midX,
                               y: pixelSize.height / 2 - cellInk.midY)
    return glyphs.compactMap { glyph in
        guard let ctx = CGContext(
            data: nil, width: Int(pixelSize.width), height: Int(pixelSize.height),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(cgColor)
        ctx.textPosition = textPosition
        CTLineDraw(
            CTLineCreateWithAttributedString(NSAttributedString(string: glyph, attributes: attributes)),
            ctx)
        return ctx.makeImage()
    }
}

#if canImport(AppKit)

/// A braille status badge: a still cell, a pulsing cell, or (with >1 glyph) the
/// cycling spinner — rendered to images once and animated in the render server.
///
/// Anything that updates SwiftUI state per frame (TimelineView Text swaps, SF
/// Symbol effects) re-renders the sidebar row 8–30×/sec and measured 7–17% CPU
/// per visible badge. Here the frames are cycled by a `CAKeyframeAnimation` on
/// the layer's `contents` (or a `CABasicAnimation` on opacity for the pulse) —
/// the window server runs the loop, the app does zero per-frame work, and macOS
/// pauses it when the window isn't visible.
private struct BrailleBadge: NSViewRepresentable {
    let color: Color
    var pointSize: CGFloat = 14
    /// >1 glyph → cycle them (the spinner); a single glyph → a still cell.
    var glyphs: [String]
    /// Breathe the cell's opacity on top (the waiting state).
    var pulses = false

    func makeNSView(context: Context) -> BadgeView {
        BadgeView(color: NSColor(color), pointSize: pointSize, glyphs: glyphs, pulses: pulses)
    }
    func updateNSView(_ nsView: BadgeView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BadgeView, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }

    final class BadgeView: NSView {
        private static let frameInterval = 0.125
        static func glyphSize(for pointSize: CGFloat) -> NSSize {
            NSSize(width: pointSize * 0.8, height: pointSize * 1.2)
        }
        private let glyphSize: NSSize
        private let images: [CGImage]
        private let pulses: Bool

        init(color: NSColor, pointSize: CGFloat, glyphs: [String], pulses: Bool) {
            glyphSize = Self.glyphSize(for: pointSize)
            self.pulses = pulses
            let font = NSFont.monospacedSystemFont(ofSize: pointSize * 2, weight: .regular)
            images = renderBrailleImages(glyphs, font: font, cgColor: color.cgColor,
                                         pixelSize: CGSize(width: glyphSize.width * 2,
                                                           height: glyphSize.height * 2))
            super.init(frame: NSRect(origin: .zero, size: glyphSize))
            wantsLayer = true
            layer?.contents = images.first  // stable base; see install()
            setContentHuggingPriority(.required, for: .horizontal)
            setContentHuggingPriority(.required, for: .vertical)
            NotificationCenter.default.addObserver(
                self, selector: #selector(reinstall),
                name: NSApplication.didBecomeActiveNotification, object: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var intrinsicContentSize: NSSize { glyphSize }

        // CA strips a layer's animations when it leaves the hierarchy, when the
        // app deactivates, on a superview move (which doesn't re-fire
        // viewDidMoveToWindow), and on other tree rebuilds with no callback at
        // all. Defence in depth: reinstall from every lifecycle hook, restart via
        // the animation's stop delegate for the callback-less strips, and keep the
        // base `contents` so it degrades to a still glyph rather than vanishing.
        private func install() {
            guard let layer else { return }
            layer.contentsScale = window?.backingScaleFactor ?? 2
            layer.contents = images.first
            guard layer.animation(forKey: "belfry.badge") == nil else { return }
            let animation: CAAnimation
            if images.count > 1 {
                let cycle = CAKeyframeAnimation(keyPath: "contents")
                cycle.values = images
                cycle.calculationMode = .discrete
                cycle.duration = Double(images.count) * Self.frameInterval
                cycle.repeatCount = .infinity
                animation = cycle
            } else if pulses {
                animation = makePulseAnimation()
            } else {
                return  // still cell — the base `contents` is all it needs
            }
            animation.delegate = AnimationRestarter { [weak self] in
                guard let self, self.window != nil,
                      self.layer?.animation(forKey: "belfry.badge") == nil else { return }
                self.install()
            }
            layer.add(animation, forKey: "belfry.badge")
        }

        @objc private func reinstall() {
            layer?.removeAnimation(forKey: "belfry.badge")
            install()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { install() }
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            if superview != nil { install() }
        }
    }
}

#else  // UIKit — same render-server animations, UIView-hosted.

/// iOS twin of the macOS BrailleBadge (see that doc comment for the why).
private struct BrailleBadge: UIViewRepresentable {
    let color: Color
    var pointSize: CGFloat = 14
    /// >1 glyph → cycle them (the spinner); a single glyph → a still cell.
    var glyphs: [String]
    /// Breathe the cell's opacity on top (the waiting state).
    var pulses = false

    func makeUIView(context: Context) -> BadgeView {
        BadgeView(color: UIColor(color), pointSize: pointSize, glyphs: glyphs, pulses: pulses)
    }
    func updateUIView(_ uiView: BadgeView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: BadgeView, context: Context) -> CGSize? {
        uiView.intrinsicContentSize
    }

    final class BadgeView: UIView {
        private static let frameInterval = 0.125
        static func glyphSize(for pointSize: CGFloat) -> CGSize {
            CGSize(width: pointSize * 0.8, height: pointSize * 1.2)
        }
        private let glyphSize: CGSize
        private let images: [CGImage]
        private let pulses: Bool

        init(color: UIColor, pointSize: CGFloat, glyphs: [String], pulses: Bool) {
            glyphSize = Self.glyphSize(for: pointSize)
            self.pulses = pulses
            let font = UIFont.monospacedSystemFont(ofSize: pointSize * 2, weight: .regular)
            images = renderBrailleImages(glyphs, font: font, cgColor: color.cgColor,
                                         pixelSize: CGSize(width: glyphSize.width * 2,
                                                           height: glyphSize.height * 2))
            super.init(frame: CGRect(origin: .zero, size: glyphSize))
            layer.contentsScale = 2
            layer.contents = images.first  // stable base; see install()
            NotificationCenter.default.addObserver(
                self, selector: #selector(reinstall),
                name: UIApplication.didBecomeActiveNotification, object: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var intrinsicContentSize: CGSize { glyphSize }

        // Core Animation strips a layer's animations when it leaves the view
        // hierarchy, when the app backgrounds, on a superview move (which does NOT
        // re-fire didMoveToWindow), and on other tree rebuilds with no callback.
        // Losing a `contents`-driven cycle (with a nil model value) blanked the
        // spinner; even with a base frame it froze mid-cycle. Defence in depth:
        // reinstall from every lifecycle hook, restart via the animation's stop
        // delegate for the callback-less strips, and keep the base `contents` so
        // it degrades to a still glyph rather than vanishing.
        private func install() {
            layer.contents = images.first
            guard layer.animation(forKey: "belfry.badge") == nil else { return }
            let animation: CAAnimation
            if images.count > 1 {
                let cycle = CAKeyframeAnimation(keyPath: "contents")
                cycle.values = images
                cycle.calculationMode = .discrete
                cycle.duration = Double(images.count) * Self.frameInterval
                cycle.repeatCount = .infinity
                animation = cycle
            } else if pulses {
                animation = makePulseAnimation()
            } else {
                return  // still cell — the base `contents` is all it needs
            }
            animation.delegate = AnimationRestarter { [weak self] in
                guard let self, self.window != nil,
                      self.layer.animation(forKey: "belfry.badge") == nil else { return }
                self.install()
            }
            layer.add(animation, forKey: "belfry.badge")
        }

        @objc private func reinstall() {
            layer.removeAnimation(forKey: "belfry.badge")
            install()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { install() }
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            if superview != nil { install() }
        }
    }
}

#endif
