import SwiftUI
import AppKit
import Darwin
import WebKit

@main
struct BelfryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = BelfryApp.bootstrapModel()


    /// Local host + saved ssh aliases, with the SSH socket dir ready.
    private static func bootstrapModel() -> AppModel {
        SSHControl.ensureSocketDir()
        var hosts: [HostModel] = [.local()]
        for saved in HostPersistence.load() {
            hosts.append(.ssh(alias: saved.alias, displayName: saved.displayName))
        }
        return AppModel(hosts: hosts)
    }

    /// ⌘+/⌘−/⌘0: page zoom while a web tab is showing, terminal font otherwise.
    private func adjustSize(_ step: Int) {
        if let web = model.browserTabs.activeWebTab?.webView {
            web.pageZoom = min(max(web.pageZoom + Double(step) * 0.1, 0.5), 3.0)
        } else if step > 0 {
            model.increaseFont()
        } else {
            model.decreaseFont()
        }
    }

    private func resetSize() {
        if let web = model.browserTabs.activeWebTab?.webView {
            web.pageZoom = 1.0
        } else {
            model.resetFont()
        }
    }

    var body: some Scene {
        // A single, unique window (not a WindowGroup): ⌘N can't spawn a second
        // window that would double-start the control clients and fight over the
        // libghostty surface controllers.
        Window("Belfry", id: "main") {
            RootView(model: model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .windowStyle(.titleBar)
        // Every agent on every host at once, Activity Monitor style.
        Window("Agents", id: "agents") {
            AgentsTableView(model: model)
                .frame(minWidth: 720, minHeight: 240)
        }
        .defaultSize(width: 1100, height: 420)
        .keyboardShortcut("a", modifiers: [.command, .shift])
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Updater.controller?.checkForUpdates(nil) }
            }
            // Browser tabs for the selected session. "Close Browser Tab" is
            // only *present* while a web tab is showing, so terminal-active
            // ⌘W keeps meaning Close Window (and the quit-on-last-window
            // path behind it). Command content can't observe @Observable
            // state directly (it never re-evaluates), so the active tab
            // arrives as a focused scene value published by RootView.
            CommandGroup(after: .newItem) {
                BrowserTabCommands(store: model.browserTabs)
            }
            // Extend the SYSTEM View menu (the one NavigationSplitView owns)
            // rather than CommandMenu("View"), which would add a second menu
            // with the same name next to it. With a web tab showing, the size
            // keys zoom the page instead of the terminal font.
            CommandGroup(after: .sidebar) {
                ThemeCommands()
                Divider()
                Button("Increase Font Size") { adjustSize(+1) }
                    .keyboardShortcut("+", modifiers: .command)
                // Also catch ⌘= (the +/= key without Shift), which doesn't match "+".
                Button("Increase Font Size") { adjustSize(+1) }
                    .keyboardShortcut("=", modifiers: .command)
                Button("Decrease Font Size") { adjustSize(-1) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Actual Size") { resetSize() }
                    .keyboardShortcut("0", modifiers: .command)
            }
        }
    }
}

/// View ▸ Theme: the built-in coding themes (dark, then light) plus "Match
/// Ghostty". Command content never re-evaluates for @Observable state, so the
/// checkmark binds through @AppStorage on the same defaults key `ThemeStore`
/// persists to; choosing routes through `ThemeStore.select`, which recolours
/// the chrome and every live terminal.
struct ThemeCommands: View {
    @AppStorage("colorTheme") private var selected = ThemeStore.ghosttyID

    var body: some View {
        Picker("Theme", selection: Binding(get: { selected }, set: { ThemeStore.shared.select($0) })) {
            Text("Match Ghostty").tag(ThemeStore.ghosttyID)
            Divider()
            Section("Dark") {
                ForEach(ThemeStore.darkThemes) { Text($0.name).tag($0.id) }
            }
            Section("Light") {
                ForEach(ThemeStore.lightThemes) { Text($0.name).tag($0.id) }
            }
        }
    }
}

// AppModel now lives in BelfryKit (shared with iOS); the macOS-specific
// pieces — ssh-alias add-host and quit-time server cleanup — are extensions
// in MacTransport.swift.

struct RootView: View {
    let model: AppModel
    @State private var selection: WindowSelection?
    @Environment(\.openWindow) private var openWindow
    @State private var prompt: SidebarPrompt?
    @State private var confirm: ConfirmAction?
    /// The last readout that resolved, kept so a host dropping its connection
    /// (which clears its store, unresolving the selection) doesn't blank the
    /// title mid-reconnect — that's the moment you most want to know which
    /// session you were looking at.
    @State private var lastReadout: CachedReadout?
    @State private var showsFilePane = false
    @State private var closeTabKeyMonitor: Any?
    @State private var git: HeaderGit?
    /// The detail column's width, which decides how much of the header fits.
    @State private var detailWidth: CGFloat = 1000
    /// The facts' own width as laid out, so the title knows what's left.
    @State private var factsWidth: CGFloat = 0
    /// Bumped by the paperclip button; `terminalAttachments` opens its panel.
    @State private var attachRequest = 0

    private struct HeaderGit: Equatable {
        let directory: String
        let overview: GitOverview
    }

    private struct CachedReadout: Equatable {
        let selection: WindowSelection
        let readout: WindowReadout
    }

    /// The selected window joined against live tmux state; nil falls back to
    /// the stale readout (host down) or the plain "Belfry" title.
    private var readout: WindowReadout? {
        WindowReadout(hosts: model.hosts, selection: selection)
    }

    private var selectedHost: HostModel? {
        guard let sel = selection else { return nil }
        return model.hosts.first { $0.id == sel.hostID }
    }

    /// The cached readout for the current selection, but only while its host
    /// is actually down. A *connected* host that can't resolve the selection
    /// means the window was killed — then the stale label would be a lie.
    private var staleReadout: WindowReadout? {
        guard readout == nil,
              let sel = selection,
              let host = selectedHost,
              !host.store.status.isLive,
              let cached = lastReadout, cached.selection == sel
        else { return nil }
        return cached.readout
    }

    /// "reconnecting…" while the link is coming back on its own; "disconnected"
    /// when the user took the host offline and nothing is pending.
    private var staleStatusWord: String {
        if case .offline = selectedHost?.store.status { return "disconnected" }
        return "reconnecting…"
    }

    /// The session, whichever tab is showing: the tab strip names the page.
    private var windowTitle: String {
        readout?.primary ?? staleReadout?.primary ?? "Belfry"
    }

    @ViewBuilder private var sidebar: some View {
        #if DEBUG
        if SidebarLab.isOn {
            MacSidebarView(snapshot: SidebarSamples.snapshot(), selection: $selection)
                .modifier(MacSidebarChrome())
        } else {
            SessionTreeView(hosts: model.hosts, model: model,
                            selection: $selection, prompt: $prompt, confirm: $confirm)
        }
        #else
        SessionTreeView(hosts: model.hosts, model: model,
                        selection: $selection, prompt: $prompt, confirm: $confirm)
        #endif
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 250)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) { addMenu }
                }
        } detail: {
            TerminalDetailView(hosts: model.hosts, selection: selection, fontSize: model.fontSize,
                               browserTabs: model.browserTabs)
                // The terminal's colour runs up under the toolbar, so the
                // toolbar, the tmux status line and the sidebar seam meet on
                // one surface rather than three slightly different ones.
                .background(AppTheme.windowBackground.ignoresSafeArea())
                // No toolbar background of its own: each column's colour shows
                // through (a painted toolbar put the terminal's colour above
                // the sidebar too).
                .toolbarBackground(.hidden, for: .windowToolbar)
                .terminalAttachments(hosts: model.hosts, selection: selection,
                                     openPanelRequest: attachRequest)
                // Track the detail column's own width (inside the inspector,
                // which takes its toolbar space with it) so the header's facts
                // can drop out before they'd crowd the title.
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                    detailWidth = $0
                }
                // The file pane rides in an inspector so the warm terminal
                // surfaces stay mounted beside it, never re-parented.
                .inspector(isPresented: $showsFilePane) {
                    FileBrowserPane(hosts: model.hosts, selection: selection,
                                    transferCenter: model.transferCenter)
                        .inspectorColumnWidth(min: 260, ideal: 320, max: 560)
                }
                .task(id: gitPollKey) { await pollGit() }
                .toolbar { detailToolbar }
        }
        // The window title still carries the readout's first line — Mission
        // Control, the Window menu, screen sharing and VoiceOver all name the
        // session, not the app — but the visible title is the styled
        // `titleReadout` above, so hide the native rendering where the API
        // exists (macOS 15+; on 14 the two coexist).
        .navigationTitle(windowTitle)
        .hidingToolbarTitle()
        // The Agents window asks to jump to an agent: select its window here,
        // focus its pane, and bring this window forward.
        .onChange(of: model.jumpRequest, initial: true) { _, request in
            guard let request else { return }
            model.jumpRequest = nil
            selection = request.selection   // carries the pane; the sidebar focuses it
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }
        .onChange(of: readout, initial: true) { _, new in
            if let new, let sel = selection {
                lastReadout = CachedReadout(selection: sel, readout: new)
            }
            updateProxyIcon(for: new)
        }
        .tint(AppTheme.accent)
        .preferredColorScheme(AppTheme.colorScheme)
        .onChange(of: model.attentionCount, initial: true) { _, count in
            NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        }
        .task {
            #if DEBUG
            if !SidebarLab.isOn { model.startAll() }
            // BELFRY_DEMO_SELECT=<session>: select that session's active window
            // once it appears (staged screenshots).
            if let name = ProcessInfo.processInfo.environment["BELFRY_DEMO_SELECT"] {
                for _ in 0..<100 {
                    try? await Task.sleep(for: .milliseconds(200))
                    if let host = model.hosts.first,
                       let session = host.store.sessions.first(where: { $0.name == name }),
                       let window = session.windows.first(where: \.isActive) ?? session.windows.first {
                        model.jumpRequest = AppModel.JumpRequest(
                            selection: WindowSelection(hostID: host.id, windowID: window.id), paneID: nil)
                        break
                    }
                }
            }
            #else
            model.startAll()
            #endif
            installCloseTabKeyMonitor()
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
        // Local tmux server up but wedged past the auto-wait (memory pressure):
        // ask rather than silently start a competing server that would orphan its
        // sessions. Default (dismiss) keeps waiting; "Start fresh server" is opt-in.
        .alert(
            "Local tmux server isn’t responding",
            isPresented: Binding(get: { model.stuckHost != nil },
                                 set: { if !$0 { model.stuckHost?.keepWaitingForServer() } }),
            presenting: model.stuckHost
        ) { host in
            Button("Keep waiting") { host.keepWaitingForServer() }
            Button("Start fresh server", role: .destructive) { host.createFreshServer() }
        } message: { _ in
            Text("It may be stuck under memory pressure. Your existing sessions are "
                 + "probably fine and will reappear once it recovers. Starting a fresh "
                 + "server abandons whatever the stuck one is holding.")
        }
    }

    /// The detail column's toolbar, leading to trailing: the readout that
    /// stands in for the native title, then — past a flexible space — the
    /// facts, and the buttons in glass groups by what they act on: this
    /// session (browser tab, attach a file, transfers), every agent, and the
    /// files inspector, which stands apart at the trailing edge as the
    /// inspector toggle does in Finder and Xcode. Adjacent buttons share one
    /// glass capsule on macOS 26; the fixed spacers are what split the groups.
    @ToolbarContentBuilder private var detailToolbar: some ToolbarContent {
        if #available(macOS 26.0, *) {
            // No glass capsule behind the readout or the facts — they're a
            // title and its annotations, not controls.
            ToolbarItem(placement: .navigation) { titleReadout }
                .sharedBackgroundVisibility(.hidden)
            // Removing the native title also removes the flexible space it
            // brought; reinstate it so the trailing items stay trailing.
            ToolbarSpacer(.flexible)
            ToolbarItem(placement: .primaryAction) { headerFacts }
                .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.fixed, placement: .primaryAction)
        } else {
            ToolbarItem(placement: .navigation) { titleReadout }
            ToolbarItem(placement: .primaryAction) { headerFacts }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.browserTabs.openTabInCurrent()
            } label: {
                Label("New Browser Tab", systemImage: "globe")
            }
            .disabled(selection == nil)
            .help("Open a browser tab in this session (⌘T)")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                attachRequest += 1
            } label: {
                Label("Attach File…", systemImage: "paperclip")
            }
            .disabled(selection == nil)
            .help("Send a file to this session: it's staged on the host and its path is pasted into the prompt")
        }
        ToolbarItem(placement: .primaryAction) {
            TransfersButton(center: model.transferCenter)
        }
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                openWindow(id: "agents")
            } label: {
                // Belfry's own mark — the braille cell every agent badge is
                // drawn from — as a template image, so the toolbar sizes and
                // tints it like any SF Symbol (a Text icon got a custom-view
                // item with a glass of its own).
                Label {
                    Text("Agents")
                } icon: {
                    Image(nsImage: BrailleMark.toolbarImage)
                }
            }
            .help("Every agent at a glance (⇧⌘A)")
        }
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                showsFilePane.toggle()
            } label: {
                Label("Files", systemImage: "sidebar.right")
            }
            .disabled(selection == nil)
            .keyboardShortcut("i", modifiers: [.command, .option])
            .help("Browse the selected window's working directory (⌥⌘I)")
        }
    }

    /// The visible title: the same two lines the old lozenge showed, styled
    /// like the native title/subtitle it replaces — plus the two things the
    /// native rendering can't do: a tinted machine name and the animated
    /// Claude chip in the same bubble. Local windows keep the proxy-icon
    /// affordance as a draggable folder icon.
    private var titleReadout: some View {
        HeaderTitle(
            readout: readout,
            staleReadout: staleReadout,
            staleWord: staleStatusWord,
            window: selectedWindow,
            agent: headerAgent,
            folderURL: localFolderURL,
            maxWidth: titleMaxWidth)
    }

    /// The selected window's working directory, when it's on this Mac and the
    /// directory actually exists here.
    private var localFolderURL: URL? {
        guard let current = readout ?? staleReadout, current.isLocalHost,
              !current.currentPath.isEmpty,
              FileManager.default.fileExists(atPath: current.currentPath)
        else { return nil }
        return URL(fileURLWithPath: current.currentPath)
    }

    /// The selected window itself, joined against live tmux state.
    private var selectedWindow: TmuxWindow? {
        guard let sel = selection, let host = selectedHost else { return nil }
        for session in host.store.sessions {
            if let window = session.windows.first(where: { $0.id == sel.windowID }) { return window }
        }
        return nil
    }

    /// Re-runs the git poll whenever the window, its directory, or its agent's
    /// state changes — a turn ending is exactly when the branch or the
    /// working tree is likely to have moved.
    private var gitPollKey: String? {
        guard let sel = selection, let window = selectedWindow, !window.currentPath.isEmpty
        else { return nil }
        return "\(sel.hostID)|\(window.currentPath)|\(window.agentState)"
    }

    /// The selected window's repo overview for the header: fetched at once,
    /// then refreshed on a slow timer (slower over ssh). Kept per directory,
    /// so switching windows never shows the previous one's branch.
    private func pollGit() async {
        guard let host = selectedHost, let window = selectedWindow,
              let browser = host.transport.makeFileBrowser()
        else { git = nil; return }
        let directory = "\(host.id)|\(window.currentPath)"
        if git?.directory != directory { git = nil }
        let interval: Duration = host.transport.isLocal ? .seconds(10) : .seconds(30)
        while !Task.isCancelled {
            let overview = (try? await browser.gitOverview(directory: window.currentPath)) ?? nil
            guard !Task.isCancelled else { return }
            git = overview.map { HeaderGit(directory: directory, overview: $0) }
            try? await Task.sleep(for: interval)
        }
    }

    /// The selected window's primary agent, when it has one worth showing
    /// (or the staged demo agent in debug builds).
    private var headerAgent: AgentPane? {
        #if DEBUG
        if let demo = HeaderDemo.agent { return demo }
        #endif
        guard let agent = selectedWindow?.primaryAgent, agent.state != .none else { return nil }
        return agent
    }

    private var headerGit: GitOverview? {
        #if DEBUG
        if let demo = HeaderDemo.git { return demo }
        #endif
        return git?.overview
    }

    private var headerLayout: HeaderLayout { HeaderLayout(width: detailWidth) }

    /// What's left for the title once the trailing items have their room.
    /// NSToolbar gives a SwiftUI item its ideal width and, when the row runs
    /// out, pushes whole items into the » menu rather than squeezing any —
    /// so without a cap a long task title shoved the branch and every
    /// button off the toolbar on a narrow window. Capped, the title truncates
    /// instead. The buttons' width is AppKit's to decide, so it's measured
    /// off the toolbar once (four glass buttons in three groups, plus the
    /// transfers button while it shows).
    private var titleMaxWidth: CGFloat {
        let buttons: CGFloat = 176 + (model.transferCenter.transfers.isEmpty ? 0 : 38)
        let gaps: CGFloat = 28   // leading inset, a breath before the facts, trailing edge
        return max(140, detailWidth - factsWidth - buttons - gaps)
    }

    private var headerFacts: some View {
        HeaderFacts(git: headerGit, agent: headerAgent, layout: headerLayout)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { factsWidth = $0 }
    }

    /// Local windows get their working directory as the title-bar proxy icon:
    /// draggable into terminals and Finder, ⌘-clickable for the path menu.
    /// Set through AppKit rather than `.navigationDocument`, which can only be
    /// applied unconditionally and has no "no document" state to return to.
    private func updateProxyIcon(for readout: WindowReadout?) {
        let url: URL? = {
            guard let readout, readout.isLocalHost, !readout.currentPath.isEmpty,
                  FileManager.default.fileExists(atPath: readout.currentPath)
            else { return nil }
            return URL(fileURLWithPath: readout.currentPath)
        }()
        for window in NSApp.windows where window.isVisible && !(window is NSPanel) {
            window.representedURL = url
        }
    }

    /// ⌘W means "close the web tab" while one is showing, and Close Window
    /// otherwise. Neither SwiftUI route can express that here: Commands
    /// content doesn't observe @Observable models, and focused scene values
    /// stall when an AppKit view (the WKWebView, the terminal surface) holds
    /// first responder. A local event monitor sees the keystroke before menu
    /// key-equivalent dispatch and consumes it only when a web tab is up, so
    /// the terminal-active window-close path (and app quit behind it) is
    /// untouched.
    private func installCloseTabKeyMonitor() {
        guard closeTabKeyMonitor == nil else { return }
        closeTabKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
                  event.charactersIgnoringModifiers == "w",
                  let key = NSApp.keyWindow, !(key is NSPanel), key.isMainWindow,
                  model.browserTabs.activeWebTab != nil
            else { return event }
            model.browserTabs.closeActiveTab()
            return nil
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
        .menuIndicator(.hidden)
    }
}

private extension View {
    /// Hide the toolbar's native title text (macOS 15+): `navigationTitle`
    /// keeps feeding Mission Control / the Window menu / VoiceOver, while the
    /// styled `titleReadout` toolbar item is what the title bar shows.
    /// macOS 14 lacks `toolbar(removing: .title)` and shows both.
    @ViewBuilder
    func hidingToolbarTitle() -> some View {
        if #available(macOS 15.0, *) {
            toolbar(removing: .title)
        } else {
            self
        }
    }
}

/// Browser-tab menu items. Everything here is always present and always
/// enabled (the store no-ops without a selected session): Commands content
/// doesn't re-evaluate on @Observable changes, so any conditional item or
/// .disabled state would freeze at its first value. ⌘W (close web tab) is
/// deliberately NOT here — it needs to fall through to Close Window when the
/// terminal is showing, which a menu item can't do; RootView's key monitor
/// handles it.
private struct BrowserTabCommands: View {
    let store: BrowserTabStore

    var body: some View {
        Divider()
        Button("New Browser Tab") { store.openTabInCurrent() }
            .keyboardShortcut("t", modifiers: .command)
        Button("Open Location") { store.focusURLField() }
            .keyboardShortcut("l", modifiers: .command)
        Button("Show Next Tab") { store.cycleCurrent(1) }
            .keyboardShortcut(.tab, modifiers: .control)
        Button("Show Previous Tab") { store.cycleCurrent(-1) }
            .keyboardShortcut(.tab, modifiers: [.control, .shift])
    }
}

/// Appends a timestamped line to ~/Library/Logs/Belfry-quit.log. Diagnostic for the
/// quit path: which delegate methods fire, when shutdown runs, and whether the
/// watchdog trips — so a "still running after ⌘Q" report can be traced precisely.
func qlog(_ message: String) {
    let line = "\(Date()) [\(getpid())] \(message)\n"
    let path = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/Belfry-quit.log")
    if let handle = FileHandle(forWritingAtPath: path) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    } else {
        try? Data(line.utf8).write(to: URL(fileURLWithPath: path))
    }
}

/// Lets the app come to the foreground with a real menu/Dock presence even when
/// launched from a bare SPM executable (no .app bundle yet).
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Only the bare `swift build` binary needs to force a GUI presence —
        // the bundled app is .regular already, and flipping the policy during
        // launch makes SwiftUI build the menu bar twice: standard-menu
        // CommandGroups land in the discarded first build (observed as a
        // doubled View menu and a missing Check for Updates item).
        if Bundle.main.bundleIdentifier == nil {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        Self.rotateQuitLogIfNeeded()
        qlog("didFinishLaunching")
        #if DEBUG
        DebugSnapshot.install()
        #endif
        // After sleep, ssh links that look live are often dead (ServerAlive
        // takes up to a minute to notice) — probe them and skip any pending
        // backoff so remote hosts are back by the time the lid is open.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { AppModel.current?.systemDidWake() }
        }
        // Safety net: a SwiftUI single-`Window` scene doesn't always terminate the
        // app when its window closes, which can strand Belfry "still running" so the
        // user force-quits it — and a Dock force-quit force-kills the whole coalition,
        // taking the tmux server (and the user's local sessions) with it. If the last
        // visible window closes, terminate *gracefully* instead.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, !self.isTerminating else { return }
            DispatchQueue.main.async {
                let visible = NSApp.windows.filter { $0.isVisible && !($0 is NSPanel) }
                qlog("window willClose; remaining visible windows=\(visible.count)")
                if visible.isEmpty { NSApp.terminate(nil) }
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        qlog("applicationShouldTerminate")
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        qlog("applicationShouldTerminateAfterLastWindowClosed -> true")
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        qlog("applicationWillTerminate BEGIN")
        // Guarantee the process actually exits even if teardown stalls, so Belfry
        // never lingers as a half-dead "still running" app the user must force-quit.
        // Sessions live in the tmux server, which outlives a clean exit, so
        // force-exiting here is safe: worst case a control session is left to reap.
        Self.armQuitWatchdog(after: 1.5)
        MainActor.assumeIsolated {
            AppModel.current?.shutdownAllWithCleanup()
        }
        qlog("applicationWillTerminate END (shutdownAll returned)")
    }

    /// The quit log appends forever; keep it from growing unbounded. Over
    /// ~512 KB at launch, move it aside (one .old generation) and start fresh.
    private static func rotateQuitLogIfNeeded() {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/Belfry-quit.log")
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int,
              size > 512 * 1024 else { return }
        let old = path + ".old"
        try? FileManager.default.removeItem(atPath: old)
        try? FileManager.default.moveItem(atPath: path, toPath: old)
    }

    /// Force `_exit(0)` after `seconds` on a dedicated thread that can't be blocked
    /// by a main-thread deadlock. Fires only if graceful shutdown overran; on a
    /// normal quit the process is already gone well before then.
    private static func armQuitWatchdog(after seconds: Double) {
        let watchdog = Thread {
            Thread.sleep(forTimeInterval: seconds)
            qlog("quit watchdog firing _exit(0) after \(seconds)s")
            _exit(0)
        }
        watchdog.name = "belfry.quit-watchdog"
        watchdog.stackSize = 64 * 1024
        watchdog.start()
    }
}
