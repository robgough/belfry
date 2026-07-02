import SwiftUI

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

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SessionTreeView(hosts: model.hosts, model: model,
                            selection: $selection, prompt: $prompt, confirm: $confirm)
                .navigationTitle("Belfry")
                .toolbar {
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
        // Screen space is precious: keep the terminal full-width and slide the
        // sidebar *over* it instead of squeezing the grid.
        .navigationSplitViewStyle(.prominentDetail)
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
