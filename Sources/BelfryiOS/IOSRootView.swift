import SwiftUI

/// How the iPad lays out the sidebar beside the terminal, remembered across
/// launches. `.keepOpen` keeps the tree docked next to the terminal (a balanced
/// split); `.overlay` slides the tree over a full-width terminal (prominent
/// detail). Irrelevant on iPhone, where the split view is always a stack.
private enum SidebarLayout: String { case keepOpen, overlay }

/// iOS/iPadOS root: same sidebar-tree + warm-surface detail as the Mac, in a
/// NavigationSplitView (sidebar column on iPad; stacked on iPhone).
struct IOSRootView: View {
    let model: AppModel
    @State private var selection: WindowSelection?
    @State private var prompt: SidebarPrompt?
    @State private var confirm: ConfirmAction?
    // Start with the sidebar shown: prominentDetail otherwise opens on an
    // empty detail pane with the tree hidden behind the toggle button.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showsFilePane = false
    /// Saved commands (shortcut palette) — app-lifetime, persisted.
    @State private var shortcutStore = ShortcutStore()
    /// iPad sidebar behaviour (see `SidebarLayout`). Defaults to keeping the
    /// tree docked; the toolbar toggle switches to the over-the-terminal overlay.
    @AppStorage("belfry.ipadSidebarLayout") private var sidebarLayout: SidebarLayout = .keepOpen
    /// `.regular` only when the split view actually shows two columns (iPad, and
    /// large iPhones in landscape) — where the layout choice is meaningful and
    /// the toggle belongs. `.compact` (stacked) hides it.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SessionTreeView(hosts: model.hosts, model: model,
                            selection: $selection, prompt: $prompt, confirm: $confirm)
                .navigationTitle("Belfry")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) { optionsMenu }
                    ToolbarItem(placement: .primaryAction) { addMenu }
                }
        } detail: {
            TerminalDetailView(hosts: model.hosts, selection: selection, fontSize: model.fontSize)
                .background(AppTheme.windowBackground)
                // Floating keyboard dock (sticky ctrl / esc / tab / palette /
                // keyboard). Rides the keyboard safe area, so it sits just
                // above the keyboard when it's up and the bottom edge when not.
                .overlay(alignment: .bottom) {
                    if let workspace = selectedWorkspace as? BelfrySSHWorkspace {
                        TerminalDockLayer(workspace: workspace, store: shortcutStore,
                                          context: dockContext(for: workspace))
                            .id(ObjectIdentifier(workspace))
                    }
                }
                // Without this the detail column defaults to a large-title bar
                // with an empty title, reserving a tall empty band above the
                // terminal. Inline collapses the bar to a single row.
                .navigationBarTitleDisplayMode(.inline)
                // Trailing column on a regular-width iPad; SwiftUI presents it
                // as a sheet in compact widths (iPhone) automatically.
                .inspector(isPresented: $showsFilePane) {
                    FileBrowserPane(hosts: model.hosts, selection: selection,
                                    transferCenter: model.transferCenter)
                        .inspectorColumnWidth(min: 280, ideal: 340)
                }
                .toolbar {
                    // Same iTunes-style "now playing" readout as the Mac's title
                    // bar (shared BelfryKit view); renders nothing until a window
                    // resolves, so an empty detail keeps a bare nav bar. Sized up
                    // on iPad (regular width), where there's room for it.
                    ToolbarItem(placement: .principal) {
                        NowPlayingView(hosts: model.hosts, selection: selection,
                                       prominent: horizontalSizeClass == .regular)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        TransfersButton(center: model.transferCenter)
                    }
                    if selection != nil {
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                showsFilePane.toggle()
                            } label: {
                                Image(systemName: "folder")
                            }
                        }
                    }
                    // (The keyboard toggle lives in the dock's bottom-right
                    // capsule only — a toolbar twin proved redundant.)
                }
        }
        // iPad honours the user's choice: dock the tree beside the terminal
        // (balanced) or slide it *over* a full-width terminal (prominent detail).
        // iPhone ignores the style — it's always a stack.
        .modifier(SidebarLayoutStyle(keepOpen: sidebarLayout == .keepOpen))
        .tint(AppTheme.accent)
        .preferredColorScheme(AppTheme.colorScheme)
        .task {
            Haptics.prewarm()
            model.startAll()
            #if DEBUG
            // Harness hook: BELFRY_TEST_AUTOSELECT=1 selects the first window
            // once it appears, so headless simulator runs exercise the full
            // selection → attach → render path without synthetic taps.
            guard ProcessInfo.processInfo.environment["BELFRY_TEST_AUTOSELECT"] == "1" else { return }
            for _ in 0..<50 {
                try? await Task.sleep(for: .milliseconds(200))
                if let host = model.hosts.first,
                   let window = host.store.sessions.first?.windows.first {
                    selection = WindowSelection(hostID: host.id, windowID: window.id)
                    break
                }
            }
            // BELFRY_TEST_EXERCISE=1: drive the input primitives end-to-end
            // (typed text, synthesized Enter, control bytes, wheel scrollback)
            // so screenshots can verify them without synthetic touches. These
            // are exactly the primitives the dock, hardware-key router, and
            // scroll gesture call.
            guard ProcessInfo.processInfo.environment["BELFRY_TEST_EXERCISE"] == "1" else { return }
            try? await Task.sleep(for: .seconds(5))
            guard let workspace = selectedWorkspace as? BelfrySSHWorkspace else { return }
            workspace.sendInput(Data("seq 1 200".utf8))
            workspace.sendKey(.enter)                       // Enter via ghostty key event
            try? await Task.sleep(for: .seconds(1))
            workspace.sendInput(Data("echo ENTER-OK && sleep 30".utf8))
            workspace.sendKey(.enter)
            try? await Task.sleep(for: .milliseconds(1500))
            workspace.sendInput(Data([0x03]))               // ^C — the router's ctrl path
            try? await Task.sleep(for: .seconds(1))
            // BELFRY_TEST_KEYS=1: synthesized special keys end-to-end. `cat -v`
            // echoes them visibly (^[ for Esc, ^[[A… for arrows), so the
            // screenshot proves the ghostty keycode translation — Enter's text
            // payload made it immune to the HID/mac-keycode mixup that killed
            // Esc and arrows on device. Replaces the scroll phase this run.
            if ProcessInfo.processInfo.environment["BELFRY_TEST_KEYS"] == "1" {
                workspace.sendInput(Data("cat -v".utf8))
                workspace.sendKey(.enter)
                try? await Task.sleep(for: .milliseconds(800))
                for key in [TerminalKey.arrowUp, .arrowDown, .arrowLeft, .arrowRight, .escape] {
                    workspace.sendKey(key)
                    try? await Task.sleep(for: .milliseconds(150))
                }
                // Paste fidelity: with mode 2004 on, ghostty must wrap the
                // paste in ^[[200~ … ^[[201~ (cat -v makes that visible).
                workspace.sendInput(Data([0x03]))
                try? await Task.sleep(for: .milliseconds(500))
                workspace.sendInput(Data("printf '\\033[?2004h' && cat -v".utf8))
                workspace.sendKey(.enter)
                try? await Task.sleep(for: .milliseconds(800))
                workspace.terminalView.pasteText("paste1\npaste2")
                return
            }
            let mid = CGPoint(x: workspace.terminalView.bounds.midX,
                              y: workspace.terminalView.bounds.midY)
            NSLog("BELFRY-EXERCISE mouseCaptured=%d", workspace.terminalView.isMouseCaptured ? 1 : 0)
            let delta = Double(ProcessInfo.processInfo.environment["BELFRY_TEST_SCROLL_DELTA"] ?? "14") ?? 14
            for _ in 0..<40 {                               // wheel → tmux copy-mode
                workspace.terminalView.scrollWheel(deltaY: delta, at: mid)
                try? await Task.sleep(for: .milliseconds(50))
            }
            #endif
        }
        .sheet(item: $prompt) { prompt in
            PromptSheet(prompt: prompt, model: model)
        }
        .confirmationDialog(
            confirm?.title ?? "",
            isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
            presenting: confirm
        ) { action in
            Button(action.confirmLabel, role: .destructive) { action.perform(); confirm = nil }
            Button("Cancel", role: .cancel) { confirm = nil }
        } message: { action in
            Text(action.message)
        }
    }

    /// The warm workspace behind the current selection (for the keyboard button).
    private var selectedWorkspace: (any TerminalWorkspace)? {
        guard let sel = selection,
              let host = model.hosts.first(where: { $0.id == sel.hostID }),
              let session = host.store.sessions.first(where: { $0.windows.contains { $0.id == sel.windowID } })
        else { return nil }
        return host.surfaceStore.workspace(for: session.id)
    }

    /// Host/session context for the dock's attachments + previews. nil (no
    /// paperclip, no previews) when the host can't browse files.
    private func dockContext(for workspace: BelfrySSHWorkspace) -> DockContext? {
        guard let sel = selection,
              let host = model.hosts.first(where: { $0.id == sel.hostID }),
              let session = host.store.sessions.first(where: { $0.windows.contains { $0.id == sel.windowID } }),
              let browser = host.transport.makeFileBrowser(),
              let transport = host.transport as? SSHHostTransport
        else { return nil }
        let window = session.windows.first { $0.id == sel.windowID }
        let path = window?.currentPath ?? ""
        return DockContext(
            hostID: host.id, sessionName: session.name,
            currentDirectory: path.isEmpty ? nil : path,
            browser: browser,
            transferCenter: model.transferCenter, workspace: workspace,
            openForward: { host, port in
                try await transport.openLocalForward(targetHost: host, targetPort: port)
            })
    }

    /// Options menu: low-frequency preferences. Font size applies to every
    /// session surface live and persists; the sidebar picker only appears
    /// where the split view actually shows two columns (iPad / big iPhones
    /// in landscape — it's meaningless in a stacked layout).
    private var optionsMenu: some View {
        Menu {
            Section("Font Size — \(model.displayFontSize) pt") {
                Button {
                    model.increaseFont()
                } label: {
                    Label("Larger", systemImage: "textformat.size.larger")
                }
                Button {
                    model.decreaseFont()
                } label: {
                    Label("Smaller", systemImage: "textformat.size.smaller")
                }
                Button("Reset") { model.resetFont() }
            }
            if horizontalSizeClass == .regular {
                Section("Sidebar") {
                    Picker("Sidebar", selection: $sidebarLayout) {
                        Text("Keep Sidebar Open").tag(SidebarLayout.keepOpen)
                        Text("Overlay Sidebar").tag(SidebarLayout.overlay)
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    private var addMenu: some View {
        Menu {
            Button("Add Host…") { prompt = .addHost }
            let live = model.connectedHosts
            if !live.isEmpty {
                Divider()
                ForEach(live) { host in
                    Button("New Session on \(host.displayName)…") {
                        prompt = .newSession(host: host)
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
        }
    }
}

/// Applies the chosen `NavigationSplitView` style. The two styles are distinct
/// concrete types, so the branch can't collapse to a ternary — it lives in a
/// `@ViewBuilder` modifier instead.
private struct SidebarLayoutStyle: ViewModifier {
    let keepOpen: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if keepOpen {
            content.navigationSplitViewStyle(.balanced)
        } else {
            content.navigationSplitViewStyle(.prominentDetail)
        }
    }
}
