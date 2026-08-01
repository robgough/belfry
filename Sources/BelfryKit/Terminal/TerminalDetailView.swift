import SwiftUI
import Termini

/// Detail pane: every visited session (across all hosts) keeps a live surface
/// mounted in a ZStack; only the selected one is visible, so switching is an
/// instant visibility toggle. Selecting a window issues `select-window` to that
/// window's host, which its surface follows.
///
/// Browser tabs (macOS) are a second, session-scoped axis over the same
/// selection: each session's tab strip decides whether the pane shows the
/// terminal surface or one of the session's web tabs. Web layers join the
/// warm ZStack — mounted while hidden, so dev servers keep their sockets.
struct TerminalDetailView: View {
    let hosts: [HostModel]
    let selection: WindowSelection?
    let fontSize: Double?
    /// nil (iOS) hides the browser-tab axis entirely.
    var browserTabs: BrowserTabStore? = nil

    private var selectedHost: HostModel? {
        hosts.first { $0.id == selection?.hostID }
    }

    private var selectedSession: TmuxSession? {
        guard let sel = selection, let host = selectedHost else { return nil }
        return host.store.sessions.first { $0.windows.contains { $0.id == sel.windowID } }
    }

    private var selectedKey: BrowserTabStore.SessionKey? {
        guard let sel = selection, let session = selectedSession else { return nil }
        return BrowserTabStore.SessionKey(hostID: sel.hostID, sessionID: session.id)
    }

    /// Whether the selected session's strip is showing the terminal (always
    /// true when there's no browser axis).
    private var showsTerminal: Bool {
        guard let browserTabs, let key = selectedKey else { return true }
        return browserTabs.isTerminalActive(for: key)
    }

    var body: some View {
        ZStack {
            ForEach(hosts) { host in
                ForEach(host.surfaceStore.activatedSessionIDs, id: \.self) { sessionID in
                    if let workspace = host.surfaceStore.workspace(for: sessionID) {
                        WarmSurface(
                            workspace: workspace,
                            fontSize: fontSize,
                            isVisible: host.id == selection?.hostID
                                && sessionID == selectedSession?.id
                                && showsTerminal
                        )
                    }
                }
            }
            #if os(macOS)
            if let browserTabs {
                ForEach(browserTabs.sessionOrder, id: \.self) { key in
                    ForEach(browserTabs.tabs(for: key)) { tab in
                        WebTabLayer(
                            tab: tab, store: browserTabs, key: key,
                            isVisible: key == selectedKey
                                && browserTabs.active(for: key) == .web(tab.id))
                    }
                }
            }
            #endif
            if selectedSession == nil {
                Text("Select a window")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        #if os(macOS)
        .safeAreaInset(edge: .top, spacing: 0) {
            // Inset, never re-parent: the warm surfaces stay mounted below.
            if let browserTabs, let key = selectedKey, !browserTabs.tabs(for: key).isEmpty {
                BrowserTabStrip(store: browserTabs, key: key) {
                    browserTabs.setActive(.terminal, for: key)
                    selectedHost?.surfaceStore.workspace(for: key.sessionID)?.focus()
                }
            }
        }
        #endif
        .onChange(of: selection, initial: true) { _, _ in
            // A real selection change: the user asked for that window, so the
            // strip snaps back to the terminal.
            activateSelection(snapToTerminal: true)
        }
        // After a reconnect (mobile background resume, network blip) the store
        // repopulates while `selection` is unchanged — the selected session's id
        // transitioning nil→value re-arms its surface without needing a re-tap.
        // No terminal snap: don't yank the user off a web tab they were reading.
        .onChange(of: selectedSession?.id) { _, _ in
            activateSelection(snapToTerminal: false)
        }
    }

    /// Defer the side-effects: this fires from the List's selection change,
    /// and mutating observed state (activating a surface) synchronously here
    /// can re-enter the NSTableView delegate. One tick later is safe.
    private func activateSelection(snapToTerminal: Bool) {
        DispatchQueue.main.async {
            guard let sel = selection, let host = selectedHost, let session = selectedSession else {
                browserTabs?.selectionCleared()
                return
            }
            host.surfaceStore.activate(sessionID: session.id, sessionName: session.name)
            host.client.selectWindow(sel.windowID)
            host.surfaceStore.workspace(for: session.id)?.focus()
            browserTabs?.sessionSelected(
                hostID: host.id, sessionID: session.id, sessionName: session.name,
                snapToTerminal: snapToTerminal)
        }
    }
}

/// A single warm terminal surface. Stays mounted while its session is activated,
/// so it never re-attaches; only its visibility changes when switching.
private struct WarmSurface: View {
    let workspace: any TerminalWorkspace
    let fontSize: Double?
    let isVisible: Bool

    var body: some View {
        workspace.makeSurfaceView(fontSize: fontSize, isVisible: isVisible)
            // Keyboard avoidance is handled in UIKit from real keyboard-frame
            // notifications (see BelfryGhosttySurfaceView "Keyboard geometry");
            // SwiftUI's automatic avoidance sometimes left a phantom inset
            // after the keyboard was dismissed. No-op on macOS.
            .ignoresSafeArea(.keyboard)
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .task {
                workspace.start()
                // Clean up the first-attach redraw (tmux drew at the initial PTY
                // size, then reflowed) with a one-shot winsize nudge.
                try? await Task.sleep(for: .milliseconds(350))
                guard let size = workspace.terminalSize else { return }
                workspace.resize(columns: size.columns, rows: max(1, size.rows - 1))
                try? await Task.sleep(for: .milliseconds(40))
                workspace.resize(columns: size.columns, rows: size.rows)
            }
    }
}
