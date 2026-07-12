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
                    if horizontalSizeClass == .regular {
                        ToolbarItem(placement: .primaryAction) { sidebarLayoutMenu }
                    }
                    ToolbarItem(placement: .primaryAction) { addMenu }
                }
        } detail: {
            TerminalDetailView(hosts: model.hosts, selection: selection, fontSize: model.fontSize)
                .background(AppTheme.windowBackground)
                .toolbar {
                    if selectedWorkspace != nil {
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                (selectedWorkspace as? BelfrySSHWorkspace)?.toggleKeyboard()
                            } label: {
                                Image(systemName: "keyboard")
                            }
                        }
                    }
                }
        }
        // iPad honours the user's choice: dock the tree beside the terminal
        // (balanced) or slide it *over* a full-width terminal (prominent detail).
        // iPhone ignores the style — it's always a stack.
        .modifier(SidebarLayoutStyle(keepOpen: sidebarLayout == .keepOpen))
        .tint(AppTheme.accent)
        .preferredColorScheme(AppTheme.colorScheme)
        .task {
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

    /// iPad-only control to dock or overlay the sidebar. A Picker inside the
    /// menu shows both choices with the current one checked.
    private var sidebarLayoutMenu: some View {
        Menu {
            Picker("Sidebar", selection: $sidebarLayout) {
                Text("Keep Sidebar Open").tag(SidebarLayout.keepOpen)
                Text("Overlay Sidebar").tag(SidebarLayout.overlay)
            }
        } label: {
            Image(systemName: "sidebar.left")
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
