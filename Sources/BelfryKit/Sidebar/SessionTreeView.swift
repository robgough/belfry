import SwiftUI

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
        PinnedRow(resolved: resolved, unpin: { model.unpin(pin) })
            .tag(target)   // iOS native selection (pushes detail on iPhone)
            .modifier(SelectOnTap { if let target { selection = target } })
            .contextMenu {
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
private struct SelectOnTap: ViewModifier {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    func body(content: Content) -> some View {
        #if os(macOS)
        content.onTapGesture(perform: action)
        #else
        content
        #endif
    }
}

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
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "pin.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(resolved.isLive ? AppTheme.accent : Color.secondary)
                .frame(width: 16, height: 15)
            VStack(alignment: .leading, spacing: 1.5) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let claudeTitle {
                    HStack(spacing: 3) {
                        Image(systemName: "sparkle")
                            .font(.system(size: 8, weight: .semibold))
                        Text(claudeTitle)
                            .lineLimit(1)
                    }
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
            // Same trailing-slot swap as WindowRow: badges give way to the
            // unpin button on hover (iOS unpins via the context menu).
            ZStack(alignment: .trailing) {
                if let window = resolved.window {
                    WindowBadges(window: window)
                        .opacity(isHovered ? 0 : 1)
                }
                HoverIconButton(systemName: "pin.slash",
                                hint: "Unpin “\(title)”", action: unpin)
                    .opacity(isHovered ? 1 : 0)
                    .allowsHitTesting(isHovered)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .opacity(resolved.isLive ? 1 : 0.55)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
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
        return abbreviatePath(path)
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

    /// Collapse the common macOS/Linux home prefixes to "~" — we can't know a
    /// remote host's real home, but keeping the interesting tail of the path
    /// visible matters more than prefix fidelity in a 250pt sidebar.
    private func abbreviatePath(_ path: String) -> String {
        for prefix in ["/Users/", "/home/"] where path.hasPrefix(prefix) {
            let rest = path.dropFirst(prefix.count)
            guard let slash = rest.firstIndex(of: "/") else { return "~" }
            return "~" + rest[slash...]
        }
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

/// Per-window Claude Code status chip: an indicator plus a word, so states are legible
/// at a glance. `.working` shows a braille "processing" spinner; `.background` (Claude's
/// turn ended but background tasks/agents are still running) pulses purple as "Agents";
/// `.idle` is a calm green check — the turn is over, nothing pending; `.waiting` is an
/// amber question mark — Claude is actively waiting for your input (e.g. a permission
/// prompt), the only state that pulses and badges the Dock.
private struct ClaudeBadge: View {
    let state: ClaudeState
    /// Claude Code session name (from `@claude_title`), appended to the
    /// tooltip when known; "" hides it.
    var title: String = ""
    var body: some View {
        switch state {
        case .none:
            EmptyView()
        case .running:
            chip(text: "Claude", color: .secondary, weight: .regular,
                 help: "Claude is running here — install status hooks for live Working / Idle / Waiting status") {
                Image(systemName: "sparkle")
            }
        case .working:
            chip(text: "Working", color: .accentColor, weight: .medium,
                 help: "Claude is working") {
                BrailleSpinner(color: .accentColor)
            }
        case .background:
            chip(text: "Agents", color: .purple, weight: .medium,
                 help: "Claude's turn ended, but background tasks or agents are still running — it will resume on its own") {
                BrailleSpinner(color: .purple)
            }
        case .idle:
            chip(text: "Idle", color: AppTheme.statusGood, weight: .regular,
                 help: "Claude finished its turn — nothing pending") {
                Image(systemName: "checkmark.circle")
            }
        case .waiting:
            chip(text: "Waiting", color: .orange, weight: .semibold,
                 help: "Claude is waiting for your input") {
                PulsingIcon(systemName: "questionmark.circle.fill", color: .orange)
            }
        }
    }

    private func chip<Glyph: View>(
        text: String, color: Color, weight: Font.Weight, help: String,
        @ViewBuilder glyph: () -> Glyph
    ) -> some View {
        HStack(spacing: 3) {
            glyph()
            Text(text)
        }
        .font(.system(size: 10, weight: weight))
        .foregroundStyle(color)
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(Capsule().fill(color.opacity(0.14)))
        .hoverHint(title.isEmpty ? help : "\(help) — session “\(title)”")
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

#if canImport(AppKit)

/// A pulsing SF Symbol, animated for free. `.symbolEffect(.pulse, .repeating)`
/// is frame-driven in-process like every per-frame SwiftUI update (measured
/// ~17% CPU for one badge); a `CABasicAnimation` on layer opacity runs
/// entirely in the render server instead.
private struct PulsingIcon: NSViewRepresentable {
    let systemName: String
    let color: Color

    func makeNSView(context: Context) -> IconView { IconView(systemName: systemName, color: NSColor(color)) }
    func updateNSView(_ nsView: IconView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: IconView, context: Context) -> CGSize? {
        IconView.iconSize
    }

    final class IconView: NSView {
        static let iconSize = NSSize(width: 12, height: 12)
        private let imageView = NSImageView()

        init(systemName: String, color: NSColor) {
            super.init(frame: NSRect(origin: .zero, size: Self.iconSize))
            wantsLayer = true
            let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
                .applying(.init(paletteColors: [color]))
            imageView.image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            imageView.frame = bounds
            imageView.autoresizingMask = [.width, .height]
            imageView.wantsLayer = true
            addSubview(imageView)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var intrinsicContentSize: NSSize { Self.iconSize }

        // CA strips animations from a layer that leaves the hierarchy, so
        // (re)install whenever we land in a window.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, let layer = imageView.layer else { return }
            guard layer.animation(forKey: "belfry.pulse") == nil else { return }
            layer.add(makePulseAnimation(), forKey: "belfry.pulse")
        }
    }
}

/// The classic braille "processing" spinner (⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏), animated for free.
///
/// Anything that updates SwiftUI state per frame (TimelineView Text swaps,
/// SF Symbol effects) re-renders the sidebar row 8–30×/sec and measured
/// 7–17% CPU while a single badge was visible. Here the ten frames are
/// rendered to images once and cycled by a `CAKeyframeAnimation` on a layer's
/// `contents` — the window server runs the loop, the app does zero per-frame
/// work, and macOS pauses it automatically when the window isn't visible.
private struct BrailleSpinner: NSViewRepresentable {
    let color: Color

    func makeNSView(context: Context) -> SpinnerView { SpinnerView(color: NSColor(color)) }
    func updateNSView(_ nsView: SpinnerView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SpinnerView, context: Context) -> CGSize? {
        SpinnerView.glyphSize
    }

    final class SpinnerView: NSView {
        private static let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
        private static let frameInterval = 0.125
        static let glyphSize = NSSize(width: 8, height: 12)
        private let images: [CGImage]

        init(color: NSColor) {
            images = Self.renderFrames(color: color)
            super.init(frame: NSRect(origin: .zero, size: Self.glyphSize))
            wantsLayer = true
            setContentHuggingPriority(.required, for: .horizontal)
            setContentHuggingPriority(.required, for: .vertical)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var intrinsicContentSize: NSSize { Self.glyphSize }

        // CA strips animations from a layer that leaves the hierarchy, so
        // (re)install whenever we land in a window.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let layer, window != nil else { return }
            layer.contentsScale = window?.backingScaleFactor ?? 2
            guard layer.animation(forKey: "belfry.spin") == nil else { return }
            let animation = CAKeyframeAnimation(keyPath: "contents")
            animation.values = images
            animation.calculationMode = .discrete
            animation.duration = Double(images.count) * Self.frameInterval
            animation.repeatCount = .infinity
            layer.add(animation, forKey: "belfry.spin")
        }

        /// Draw each braille frame once into a 2x bitmap tinted `color`.
        private static func renderFrames(color: NSColor) -> [CGImage] {
            let scale: CGFloat = 2
            let size = NSSize(width: glyphSize.width * scale, height: glyphSize.height * scale)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 10 * scale, weight: .regular),
                .foregroundColor: color,
            ]
            return frames.compactMap { glyph in
                guard let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
                ) else { return nil }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                (glyph as NSString).draw(at: .zero, withAttributes: attributes)
                NSGraphicsContext.restoreGraphicsState()
                return rep.cgImage
            }
        }
    }
}

#else  // UIKit — same render-server animations, UIView-hosted.

/// iOS twin of the macOS PulsingIcon (see that doc comment for the why).
private struct PulsingIcon: UIViewRepresentable {
    let systemName: String
    let color: Color

    func makeUIView(context: Context) -> IconView { IconView(systemName: systemName, color: UIColor(color)) }
    func updateUIView(_ uiView: IconView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: IconView, context: Context) -> CGSize? {
        IconView.iconSize
    }

    final class IconView: UIView {
        static let iconSize = CGSize(width: 12, height: 12)
        private let imageView = UIImageView()

        init(systemName: String, color: UIColor) {
            super.init(frame: CGRect(origin: .zero, size: Self.iconSize))
            let config = UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            imageView.image = UIImage(systemName: systemName, withConfiguration: config)
            imageView.tintColor = color
            imageView.contentMode = .scaleAspectFit
            imageView.frame = bounds
            imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(imageView)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var intrinsicContentSize: CGSize { Self.iconSize }

        // CA strips animations from a layer that leaves the hierarchy, so
        // (re)install whenever we land in a window.
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            let layer = imageView.layer
            guard layer.animation(forKey: "belfry.pulse") == nil else { return }
            layer.add(makePulseAnimation(), forKey: "belfry.pulse")
        }
    }
}

/// iOS twin of the macOS BrailleSpinner (see that doc comment for the why).
private struct BrailleSpinner: UIViewRepresentable {
    let color: Color

    func makeUIView(context: Context) -> SpinnerView { SpinnerView(color: UIColor(color)) }
    func updateUIView(_ uiView: SpinnerView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: SpinnerView, context: Context) -> CGSize? {
        SpinnerView.glyphSize
    }

    final class SpinnerView: UIView {
        private static let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
        private static let frameInterval = 0.125
        static let glyphSize = CGSize(width: 8, height: 12)
        private let images: [CGImage]

        init(color: UIColor) {
            images = Self.renderFrames(color: color)
            super.init(frame: CGRect(origin: .zero, size: Self.glyphSize))
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var intrinsicContentSize: CGSize { Self.glyphSize }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            layer.contentsScale = 2
            guard layer.animation(forKey: "belfry.spin") == nil else { return }
            let animation = CAKeyframeAnimation(keyPath: "contents")
            animation.values = images
            animation.calculationMode = .discrete
            animation.duration = Double(images.count) * Self.frameInterval
            animation.repeatCount = .infinity
            layer.add(animation, forKey: "belfry.spin")
        }

        /// Draw each braille frame once into a 2x bitmap tinted `color`.
        private static func renderFrames(color: UIColor) -> [CGImage] {
            let scale: CGFloat = 2
            let size = CGSize(width: glyphSize.width * scale, height: glyphSize.height * scale)
            let font = UIFont.monospacedSystemFont(ofSize: 10 * scale, weight: .regular)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = false
            let renderer = UIGraphicsImageRenderer(size: size, format: format)
            return frames.compactMap { glyph in
                renderer.image { _ in
                    (glyph as NSString).draw(
                        at: .zero,
                        withAttributes: [.font: font, .foregroundColor: color])
                }.cgImage
            }
        }
    }
}

#endif
