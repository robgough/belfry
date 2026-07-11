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
                // iTunes-style "now playing" readout, centered in the title
                // bar: what's running in the selected window and where. Renders
                // nothing when no window is selected, leaving the plain
                // "Belfry" title as before.
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        NowPlayingView(hosts: model.hosts, selection: selection)
                    }
                }
        }
        .navigationTitle("Belfry")
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
