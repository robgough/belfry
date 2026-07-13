import SwiftUI
import CoreText

/// `.help()` tooltips exist on macOS only; elsewhere this is a no-op.
extension View {
    @ViewBuilder
    func hoverHint(_ text: String) -> some View {
        #if os(macOS)
        help(text)
        #else
        self
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
/// when anything is pinned. Each host is a collapsible section; sessions list
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
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(AppTheme.sidebarBackground)
        .environment(\.defaultMinListRowHeight, Self.minRowHeight)
        // tmux is authoritative for the active window: switching windows with
        // tmux keys (prefix-n, status-bar clicks) moves the active flag on the
        // next store refresh, and the sidebar selection follows instead of
        // going stale. User clicks are safe: a click changes `selection`, not
        // `followTarget`, and the two converge once tmux confirms the switch.
        .onChange(of: followTarget) { _, target in
            guard let target, target != selection else { return }
            selection = target
        }
        .onChange(of: selection, initial: true) { _, sel in
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

    /// macOS renders selection itself (soft theme-accent pill) so the List
    /// carries no selection binding. iOS MUST use native List selection: in a
    /// collapsed NavigationSplitView (iPhone) only a native selection change
    /// pushes the detail column — a custom tap gesture updates state the
    /// split view can't see, leaving the terminal unreachable.
    @ViewBuilder private var platformList: some View {
        #if os(iOS)
        List(selection: $selection) { treeSections }
            .listSectionSpacing(.compact)
        #else
        List { treeSections }
        #endif
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
            }
        }
        ForEach(hosts) { host in
            Section(isExpanded: expansionBinding(for: host)) {
                HostBody(host: host, model: model,
                         selection: $selection, prompt: $prompt, confirm: $confirm)
            } header: {
                HostHeader(host: host, model: model, isExpanded: expansionBinding(for: host),
                           prompt: $prompt, confirm: $confirm)
            }
        }
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
            .listRowBackground(sidebarRowBackground(selected: target != nil && selection == target))
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
@ViewBuilder private func sidebarRowBackground(selected: Bool) -> some View {
    if selected {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(AppTheme.accent.opacity(0.15))
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
    } else {
        #if os(iOS)
        Color.clear
        #endif
    }
}

/// iOS row chrome: kill the grouped-list separators and the tall default row
/// metrics so the tree reads as one dense sidebar (like the Mac) instead of a
/// stack of boxed table cells. macOS's AppKit sidebar style needs none of it.
private struct SidebarRowChrome: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 3, leading: 16, bottom: 3, trailing: 12))
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
private struct SelectOnTap: ViewModifier {
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
private struct WindowSelectionTag: ViewModifier {
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
        HStack(spacing: 9) {
            HostIconChip(systemName: host.transport.isLocal ? "desktopcomputer" : "globe",
                         status: host.store.status)
            VStack(alignment: .leading, spacing: 1) {
                Text(host.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .textCase(nil)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                HoverIconButton(systemName: "plus",
                                hint: "New session on \(host.displayName)") {
                    prompt = .newSession(host: host)
                }
                if host.canDisconnect {
                    switch host.store.status {
                    case .connected, .connecting, .reconnecting:
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
            }
            .opacity(actionsVisible(hovered: isHovered) ? 1 : 0)
            .allowsHitTesting(actionsVisible(hovered: isHovered))
            // Leave room for the sidebar section's hover disclosure chevron.
            .padding(.trailing, 16)
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
        .padding(.vertical, 6)
        // The machine line is the anchor of its group: a full-bleed band
        // behind the header makes each host read as a distinct block, and the
        // section's hover disclosure chevron lands on the band instead of
        // floating beside it. Section headers float above the list (no
        // listRowBackground), so the band over-extends well past the List's
        // margins — including the extra trailing space the header loses to
        // the hover chevron — and the sidebar edge clips it flush.
        .background(AppTheme.sidebarPanel.padding(.horizontal, -48))
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        // The whole machine line toggles its sessions — quicker than hunting
        // the little chevron. The hover buttons still win over the tap.
        .onTapGesture { isExpanded.toggle() }
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .contextMenu { menu }
    }

    /// "2 sessions · 5 windows" while connected; hidden when empty or down
    /// (the status row below the header explains those states).
    private var subtitle: String? {
        guard host.store.status.isLive, !host.store.sessions.isEmpty else { return nil }
        let sessions = host.store.sessions.count
        let windows = host.store.sessions.reduce(0) { $0 + $1.windows.count }
        return "\(sessions) session\(sessions == 1 ? "" : "s") · \(windows) window\(windows == 1 ? "" : "s")"
    }

    @ViewBuilder private var menu: some View {
        Button("New Session…") { prompt = .newSession(host: host) }
        Divider()
        claudeHooksItems
        if host.canDisconnect {
            Divider()
            switch host.store.status {
            case .connected, .connecting, .reconnecting:
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

    /// Claude-status-hook state + install action for this host.
    @ViewBuilder private var claudeHooksItems: some View {
        // Transports without a hooks manager (iOS, for now) hide this entirely.
        if !host.supportsHooksManagement {
            EmptyView()
        // Managing remote hooks needs the SSH link; local always works.
        } else if !(host.transport.isLocal || host.store.status.isLive) {
            Button("Claude status hooks (connect to manage)") {}.disabled(true)
        } else {
            switch host.hooksStatus {
            case .installed:
                Button { } label: { Label("Claude status hooks installed", systemImage: "checkmark.circle") }
                    .disabled(true)
                Button("Reinstall Claude Status Hooks") { host.installHooks() }
                Button("Remove Claude Status Hooks", role: .destructive) { host.removeHooks() }
            case .notInstalled:
                Button("Install Claude Status Hooks…") { host.installHooks() }
            case .checking:
                Button("Checking Claude hooks…") {}.disabled(true)
            case .installing:
                Button("Installing Claude hooks…") {}.disabled(true)
            case .removing:
                Button("Removing Claude hooks…") {}.disabled(true)
            case .error(let message):
                Button { } label: { Label(message, systemImage: "exclamationmark.triangle") }
                    .disabled(true)
                Button("Re-check Claude Hooks") { host.checkHooks() }
            case .unknown:
                Button("Check for Claude Status Hooks") { host.checkHooks() }
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

    var body: some View {
        ForEach(host.store.sessions) { session in
            SessionHeader(host: host, session: session,
                          isPinned: model.isSessionPinned(hostID: host.id, sessionID: session.id),
                          togglePin: { model.togglePin(host: host, session: session) },
                          kill: { confirm = killSessionConfirm(session) })
                .contextMenu { sessionMenu(session) }
                .listRowBackground(sidebarRowBackground(selected: false))
                .modifier(SidebarRowChrome())
            ForEach(session.windows) { window in
                let windowSelection = WindowSelection(hostID: host.id, windowID: window.id)
                WindowRow(host: host, window: window,
                          isPinned: model.isWindowPinned(hostID: host.id, windowID: window.id),
                          togglePin: { model.togglePin(host: host, session: session, window: window) },
                          kill: { confirm = killWindowConfirm(session, window) })
                    .tag(windowSelection)   // iOS native selection (pushes detail on iPhone)
                    .modifier(SelectOnTap { selection = windowSelection })
                    .contextMenu { windowMenu(session, window) }
                    .listRowBackground(sidebarRowBackground(selected: selection == windowSelection))
                    .modifier(SidebarRowChrome())
            }
        }
        if host.store.sessions.isEmpty {
            HostStatusRow(host: host)
                .listRowBackground(sidebarRowBackground(selected: false))
                .modifier(SidebarRowChrome())
        }
    }

    private func killSessionConfirm(_ session: TmuxSession) -> ConfirmAction {
        ConfirmAction(
            title: "Kill session “\(session.name)”?",
            message: "Ends the session and all its windows on \(host.displayName).",
            confirmLabel: "Kill") { host.client.killSession(id: session.id) }
    }

    private func killWindowConfirm(_ session: TmuxSession, _ window: TmuxWindow) -> ConfirmAction {
        ConfirmAction(
            title: "Kill window “\(window.name.isEmpty ? "window \(window.index)" : window.name)”?",
            message: "Closes the window on \(host.displayName).",
            confirmLabel: "Kill") { host.client.killWindow(id: window.id) }
    }

    @ViewBuilder private func sessionMenu(_ session: TmuxSession) -> some View {
        Button("New Window") { host.client.newWindow(inSession: session.id) }
        Button("Rename Session…") { prompt = .renameSession(host: host, session: session) }
        Button(model.isSessionPinned(hostID: host.id, sessionID: session.id)
               ? "Unpin Session" : "Pin Session") {
            model.togglePin(host: host, session: session)
        }
        Divider()
        Button("Kill Session", role: .destructive) { confirm = killSessionConfirm(session) }
    }

    @ViewBuilder private func windowMenu(_ session: TmuxSession, _ window: TmuxWindow) -> some View {
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
        Button("Kill Window", role: .destructive) { confirm = killWindowConfirm(session, window) }
    }
}

/// A pin joined against live tmux state. `session`/`window` are nil while the
/// pinned thing isn't reachable (host down, session ended, window closed); the
/// row then renders dimmed from the pin's cached names instead of vanishing,
/// so pins survive disconnects and tmux-server restarts and re-light when the
/// target comes back.
@MainActor
private struct ResolvedPin {
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

/// Header band for the Pinned section — the same full-bleed treatment as
/// `HostHeader`, so the section anchors the sidebar the way host groups do.
private struct PinnedSectionHeader: View {
    var body: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(AppTheme.accent.opacity(0.16))
                .frame(width: 18, height: 18)
                .overlay(
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
                )
            Text("Pinned")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .textCase(nil)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .background(AppTheme.sidebarPanel.padding(.horizontal, -48))
        .padding(.vertical, 2)
    }
}

/// A row in the Pinned section. It appears outside its host grouping, so it
/// carries its own context: machine name and session (for window pins), the
/// Claude Code session name when Claude is running there, and the active
/// pane's working directory on its own line. Pins are the working set, so the
/// row runs slightly larger than the tree's. Unresolved pins stay in place
/// dimmed — unpin them here, or leave them to re-resolve when the target
/// returns.
private struct PinnedRow: View {
    let resolved: ResolvedPin
    let unpin: () -> Void
    @State private var pinHovered = false

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
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let claudeTitle {
                    Text(claudeTitle)
                        .lineLimit(1)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(AppTheme.accent)
                        .hoverHint("Claude Code session “\(claudeTitle)”")
                }
                Text(contextLine)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let pathLine {
                    Text(pathLine)
                        .font(.system(size: 10.5))
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
            // even though the Claude *title* line above (also `contextWindow`)
            // still showed. Now both track the session's active window together.
            // .fixedSize stops the greedy multi-line text column from
            // compressing the icon-only badge off the row's trailing edge.
            if let window = contextWindow {
                WindowBadges(window: window)
                    .fixedSize()
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
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
    /// why-it's-dimmed note appended while unresolved.
    private var contextLine: String {
        var parts: [String] = [resolved.host?.displayName ?? resolved.pin.hostID]
        if resolved.pin.windowID != nil {
            parts.append(resolved.session?.name ?? resolved.pin.sessionName)
        }
        if let note = staleNote {
            parts.append(note)
        }
        return parts.joined(separator: " · ")
    }

    /// The working directory on its own line (~-abbreviated); hidden while a
    /// stale note explains the row instead.
    private var pathLine: String? {
        guard staleNote == nil, let path = currentPath else { return nil }
        return abbreviateHomePath(path)
    }

    /// The Claude Code session name running in the pinned window (session pins
    /// report their context window's), from the `@claude_title` option the
    /// status hooks maintain. Suppressed whenever the status badge would be —
    /// a leftover title with no Claude in the window is stale.
    private var claudeTitle: String? {
        guard let window = contextWindow, window.claudeState != .none,
              !window.claudeTitle.isEmpty else { return nil }
        return window.claudeTitle
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
        case .connecting, .reconnecting, .disconnected: return AppTheme.statusWarn
        case .offline: return Color.secondary
        }
    }
}

/// Host icon in a status-tinted chip — anchors each host group on the left and
/// shows the connection state by colour (hover for the exact status). Uses the
/// terminal theme's own green/amber, matching the group rail below it.
private struct HostIconChip: View {
    let systemName: String
    let status: ConnectionStatus
    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(status.tint.opacity(0.16))
            .frame(width: 18, height: 18)
            .overlay(
                Image(systemName: systemName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(status.tint)
            )
            .hoverHint(statusText)
    }
    private var statusText: String {
        switch status {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .reconnecting(let n): return "Reconnecting… (attempt \(n))"
        case .disconnected: return "Connection lost"
        case .offline: return "Disconnected"
        }
    }
}



private struct HostStatusRow: View {
    let host: HostModel
    var body: some View {
        switch host.store.status {
        case .connecting:
            Label("Connecting…", systemImage: "ellipsis.circle")
                .font(.caption).foregroundStyle(.secondary)
        case .reconnecting(let attempt):
            Label("Reconnecting… (\(attempt))", systemImage: "arrow.clockwise")
                .font(.caption).foregroundStyle(.secondary)
        case .connected:
            Text("No sessions").font(.caption).foregroundStyle(.secondary)
        case .disconnected(let reason):
            // Reasons are real ssh/shell diagnostics and easily outgrow the
            // sidebar: wrap a few lines, and carry the full text in a tooltip.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .lineLimit(3)
                    .help(reason)
                InlineLinkButton(title: "Reconnect") { host.reconnect() }
            }
        case .offline:
            HStack(spacing: 6) {
                Text("Disconnected").font(.caption).foregroundStyle(.secondary)
                InlineLinkButton(title: "Connect") { host.reconnect() }
            }
        }
    }
}

private struct SessionHeader: View {
    let host: HostModel
    let session: TmuxSession
    let isPinned: Bool
    let togglePin: () -> Void
    let kill: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Text(session.name)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 0)
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
        .padding(.top, 4)
        .padding(.bottom, 1)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

private struct WindowRow: View {
    let host: HostModel
    let window: TmuxWindow
    let isPinned: Bool
    let togglePin: () -> Void
    let kill: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 7) {
            WindowIndexChip(index: window.index, isActive: window.isActive)
            Text(window.name.isEmpty ? "window \(window.index)" : window.name)
                .font(.system(size: 12, weight: window.isActive ? .medium : .regular))
                .foregroundStyle(window.isActive ? .primary : .secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            // Hover swaps the status badges for the split actions (they share
            // the trailing slot); badges come back when the pointer leaves.
            ZStack(alignment: .trailing) {
                badges
                    .opacity(isHovered ? 0 : 1)
                actions
                    .opacity(isHovered ? 1 : 0)
                    .allowsHitTesting(isHovered)
            }
        }
        .padding(.leading, 18)
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private var badges: some View {
        HStack(spacing: 5) {
            if isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .hoverHint("Pinned to the top of the sidebar")
            }
            WindowBadges(window: window)
        }
    }

    private var actions: some View {
        HStack(spacing: 2) {
            HoverIconButton(systemName: isPinned ? "pin.slash" : "pin",
                            hint: isPinned ? "Unpin this window"
                                           : "Pin to the top of the sidebar",
                            action: togglePin)
            HoverIconButton(systemName: "rectangle.split.2x1",
                            hint: "Split left / right") {
                host.client.splitWindow(id: window.id, horizontal: true)
            }
            HoverIconButton(systemName: "rectangle.split.1x2",
                            hint: "Split top / bottom") {
                host.client.splitWindow(id: window.id, horizontal: false)
            }
            HoverIconButton(systemName: "xmark",
                            hint: "Kill this window…", action: kill)
        }
    }
}

/// Status badges shared by tree window rows and pinned window rows: the bell,
/// the Claude state chip, or the unseen-activity dot.
private struct WindowBadges: View {
    let window: TmuxWindow
    var body: some View {
        HStack(spacing: 5) {
            if window.hasBell {
                Image(systemName: "bell.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(AppTheme.statusWarn)
                    .hoverHint("Bell rang in this window")
            }
            if window.claudeState != .none {
                ClaudeBadge(state: window.claudeState, title: window.claudeTitle)
            } else if window.hasActivity {
                Circle().fill(AppTheme.statusWarn).frame(width: 5, height: 5)
                    .hoverHint("Unseen activity")
            }
        }
    }
}

/// The tmux window index in a small chip — active window gets an accent-tinted
/// fill (same treatment as the host chip and Claude badges), inactive ones a
/// plain secondary numeral. Doubles as the "which window is prefix-N" hint.
private struct WindowIndexChip: View {
    let index: Int
    let isActive: Bool

    var body: some View {
        Text("\(index)")
            .font(.system(size: 10, weight: isActive ? .bold : .regular).monospacedDigit())
            .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
            .frame(width: 16, height: 15)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isActive ? Color.accentColor.opacity(0.16) : Color.clear)
            )
            .hoverHint(isActive ? "Active window (index \(index))" : "Window index \(index)")
    }
}

/// The full braille cell; the still/pulsing states light every dot.
private let brailleFullCell = "⣿"
/// The spinner: a hole orbiting the full 4-row cell clockwise.
private let brailleSpinnerFrames = ["⣷", "⣯", "⣟", "⡿", "⢿", "⣻", "⣽", "⣾"]

/// Per-window Claude Code status glyph. A single braille visual language, keyed
/// by colour and motion: `.working` an accent spinner (hole orbiting the cell);
/// `.background` the same spinner in purple (Claude's turn ended but background
/// tasks/agents are still running); `.idle` a still green cell — nothing pending;
/// `.waiting` a pulsing orange cell — Claude is actively waiting for your input
/// (e.g. a permission prompt), the state that also badges the Dock; `.running` a
/// still grey cell (status hooks not installed, so live state is unknown).
///
/// Icon-only, no capsule or word: the glyph stands on its own everywhere — the
/// sidebar rows and the toolbar's now-playing readout (`NowPlayingView`) alike.
///
/// Internal (not file-private) so `NowPlayingView` can reuse it.
struct ClaudeBadge: View {
    let state: ClaudeState
    /// Claude Code session name (from `@claude_title`), appended to the
    /// tooltip when known; "" hides it.
    var title: String = ""
    private let glyphPointSize: CGFloat = 14
    var body: some View {
        switch state {
        case .none:
            EmptyView()
        case .running:
            cell(.secondary, glyphs: [brailleFullCell],
                 tip: "Claude is running here — install status hooks for live Working / Idle / Waiting status")
        case .working:
            cell(.accentColor, glyphs: brailleSpinnerFrames, tip: "Claude is working")
        case .background:
            cell(.purple, glyphs: brailleSpinnerFrames,
                 tip: "Claude's turn ended, but background tasks or agents are still running — it will resume on its own")
        case .idle:
            cell(AppTheme.statusGood, glyphs: [brailleFullCell],
                 tip: "Claude finished its turn — nothing pending")
        case .waiting:
            cell(.orange, glyphs: [brailleFullCell], pulses: true,
                 tip: "Claude is waiting for your input")
        }
    }

    /// A braille badge — a static cell, a pulsing cell, or (with >1 glyph) the
    /// cycling spinner — tinted and tooltipped. The view carries its own colour
    /// and size, so no font/foregroundStyle is needed here.
    private func cell(_ color: Color, glyphs: [String], pulses: Bool = false, tip: String) -> some View {
        BrailleBadge(color: color, pointSize: glyphPointSize, glyphs: glyphs, pulses: pulses)
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
