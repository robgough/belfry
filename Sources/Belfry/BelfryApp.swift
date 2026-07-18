import SwiftUI
import AppKit
import Darwin

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

    var body: some Scene {
        // A single, unique window (not a WindowGroup): ⌘N can't spawn a second
        // window that would double-start the control clients and fight over the
        // libghostty surface controllers.
        Window("Belfry", id: "main") {
            RootView(model: model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Updater.controller?.checkForUpdates(nil) }
            }
            // Extend the SYSTEM View menu (the one NavigationSplitView owns)
            // rather than CommandMenu("View"), which would add a second menu
            // with the same name next to it.
            CommandGroup(after: .sidebar) {
                Button("Increase Font Size") { model.increaseFont() }
                    .keyboardShortcut("+", modifiers: .command)
                // Also catch ⌘= (the +/= key without Shift), which doesn't match "+".
                Button("Increase Font Size") { model.increaseFont() }
                    .keyboardShortcut("=", modifiers: .command)
                Button("Decrease Font Size") { model.decreaseFont() }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Actual Size") { model.resetFont() }
                    .keyboardShortcut("0", modifiers: .command)
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
    @State private var prompt: SidebarPrompt?
    @State private var confirm: ConfirmAction?
    /// The last readout that resolved, kept so a host dropping its connection
    /// (which clears its store, unresolving the selection) doesn't blank the
    /// title mid-reconnect — that's the moment you most want to know which
    /// session you were looking at.
    @State private var lastReadout: CachedReadout?
    @State private var showsFilePane = false

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

    private var windowTitle: String {
        readout?.primary ?? staleReadout?.primary ?? "Belfry"
    }

    /// The readout's second line, with the machine name tinted local/remote —
    /// the reason the visible title is custom: NSWindow.subtitle is a plain
    /// string, so a native subtitle can't carry the colour.
    private var secondaryLine: Text? {
        if let readout { return readout.secondaryText }
        if let stale = staleReadout { return stale.secondaryText + Text(" — \(staleStatusWord)") }
        return nil
    }

    var body: some View {
        NavigationSplitView {
            SessionTreeView(hosts: model.hosts, model: model,
                            selection: $selection, prompt: $prompt, confirm: $confirm)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) { addMenu }
                }
        } detail: {
            TerminalDetailView(hosts: model.hosts, selection: selection, fontSize: model.fontSize)
                .background(AppTheme.windowBackground)
                .terminalAttachments(hosts: model.hosts, selection: selection)
                // The file pane rides in an inspector so the warm terminal
                // surfaces stay mounted beside it, never re-parented.
                .inspector(isPresented: $showsFilePane) {
                    FileBrowserPane(hosts: model.hosts, selection: selection,
                                    transferCenter: model.transferCenter)
                        .inspectorColumnWidth(min: 260, ideal: 320, max: 560)
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        TransfersButton(center: model.transferCenter)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showsFilePane.toggle()
                        } label: {
                            Label("Files", systemImage: "folder")
                        }
                        .disabled(selection == nil)
                        .keyboardShortcut("i", modifiers: [.command, .option])
                        .help("Browse the selected window's working directory (⌥⌘I)")
                    }
                }
                // The jump bar (a menu of every window on every host) and the
                // now-playing readout that stands in for the native title:
                // title-styled two-line text with the host name tinted and the
                // live Claude chip inside the same item, so badge and label
                // share one toolbar bubble instead of the chip floating in its
                // own glass capsule.
                .toolbar {
                    ToolbarItem(placement: .navigation) { windowSwitcher }
                    // No glass capsule behind the readout — it's a title, not
                    // a control, and the chip was clipping against the bubble.
                    if #available(macOS 26.0, *) {
                        ToolbarItem(placement: .navigation) { titleReadout }
                            .sharedBackgroundVisibility(.hidden)
                        // Removing the native title also removes the flexible
                        // space it brought, which let trailing items (the
                        // paperclip) crowd in next to the readout. Reinstate it.
                        ToolbarSpacer(.flexible)
                    } else {
                        ToolbarItem(placement: .navigation) { titleReadout }
                    }
                }
        }
        // The window title still carries the readout's first line — Mission
        // Control, the Window menu, screen sharing and VoiceOver all name the
        // session, not the app — but the visible title is the styled
        // `titleReadout` above, so hide the native rendering where the API
        // exists (macOS 15+; on 14 the two coexist).
        .navigationTitle(windowTitle)
        .hidingToolbarTitle()
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
        .task { model.startAll() }
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

    /// The visible title: the same two lines the old lozenge showed, styled
    /// like the native title/subtitle it replaces — plus the two things the
    /// native rendering can't do: a tinted machine name and the animated
    /// Claude chip in the same bubble. Local windows keep the proxy-icon
    /// affordance as a draggable folder icon.
    private var titleReadout: some View {
        HStack(spacing: 8) {
            if let url = localFolderURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 17, height: 17)
                    .onDrag { NSItemProvider(object: url as NSURL) }
                    .hoverHint("Working directory — drag to copy the folder")
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(windowTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let secondaryLine {
                    secondaryLine
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if let readout, readout.claudeState != .none {
                ClaudeBadge(state: readout.claudeState, title: readout.claudeTitle)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        // The LCD: the old lozenge's rounded panel, drawn ourselves (the
        // system glass capsule is hidden) so it reads as a readout, not a
        // button, and the chip gets real padding instead of clipping.
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(AppTheme.sidebarPanel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
        .frame(maxWidth: 460)
        .fixedSize(horizontal: false, vertical: true)
        .hoverHint((readout ?? staleReadout)?.hint ?? "")
        .accessibilityElement(children: .combine)
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

    /// The jump bar: a menu of every window on every host, labelled with the
    /// selected window's live Claude chip (a plain stack icon when Claude
    /// isn't running there). A Picker gives the native checkmark on the
    /// current window; choosing another entry is exactly a sidebar click.
    private var windowSwitcher: some View {
        Menu {
            Picker("Window", selection: $selection) {
                ForEach(model.hosts) { host in
                    if !host.store.sessions.isEmpty {
                        Section(host.displayName) {
                            ForEach(host.store.sessions) { session in
                                ForEach(session.windows) { window in
                                    Text(switcherLabel(session: session, window: window))
                                        .tag(Optional(WindowSelection(hostID: host.id, windowID: window.id)))
                                }
                            }
                        }
                    }
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            if model.hosts.allSatisfy({ $0.store.sessions.isEmpty }) {
                Text("No windows")
            }
        } label: {
            Image(systemName: "rectangle.stack")
        }
        .hoverHint("Jump to a window")
    }

    private func switcherLabel(session: TmuxSession, window: TmuxWindow) -> String {
        let name = window.name.isEmpty ? "window \(window.index)" : window.name
        var label = name == session.name ? name : "\(session.name) · \(name)"
        // Live Claude state as a plain word — menu items can't carry the
        // coloured braille chip.
        switch window.claudeState {
        case .none, .running: break
        case .working:    label += " — working"
        case .background: label += " — background"
        case .idle:       label += " — idle"
        case .waiting:    label += " — waiting"
        }
        return label
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
