import SwiftUI
import AppKit
import Darwin

@main
struct BelfryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

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
            CommandMenu("View") {
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

/// Owns the hosts (each with its own control-mode connection) + UI prefs, plus
/// host add/remove and persistence.
@MainActor
@Observable
final class AppModel {
    /// For the app delegate's quit-time cleanup hook.
    static private(set) weak var current: AppModel?

    private(set) var hosts: [HostModel]

    /// Terminal font size in points; nil = libghostty's default. Applied to all
    /// session surfaces.
    var fontSize: Double?

    init() {
        SSHControl.ensureSocketDir()
        var hosts: [HostModel] = [.local()]
        for saved in HostPersistence.load() {
            hosts.append(.ssh(alias: saved.alias, displayName: saved.displayName))
        }
        self.hosts = hosts
        AppModel.current = self
    }

    func startAll() { hosts.forEach { $0.start() } }

    /// Hosts that can currently host a new session (their link is live).
    var connectedHosts: [HostModel] { hosts.filter { $0.store.status.isLive } }

    /// Number of windows across all hosts where Claude is waiting for you — drives
    /// the Dock badge so you notice while Belfry is in the background.
    var attentionCount: Int {
        hosts.reduce(0) { total, host in
            total + host.store.sessions.reduce(0) { sum, session in
                sum + session.windows.filter { $0.claudeState.needsAttention }.count
            }
        }
    }

    // MARK: Host management

    @discardableResult
    func addHost(alias: String, displayName: String? = nil) -> HostModel? {
        let alias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidSSHAlias(alias), !hosts.contains(where: { $0.id == alias }) else { return nil }
        let host = HostModel.ssh(alias: alias, displayName: displayName)
        hosts.append(host)
        persist()
        host.start()
        return host
    }

    /// The alias is passed to ssh as its own argv element, so reject anything
    /// ssh would parse as an *option* (leading "-", e.g. "-oProxyCommand=…")
    /// or that can't be a real alias/user@host (whitespace, quotes, non-ASCII
    /// control forms). ssh has no "--" end-of-options marker, so validating
    /// here is the only guard.
    static func isValidSSHAlias(_ alias: String) -> Bool {
        guard !alias.isEmpty, !alias.hasPrefix("-") else { return false }
        return alias.allSatisfy { char in
            char.isASCII && !char.isWhitespace && char != "'" && char != "\"" && char != "\\"
        }
    }

    func removeHost(_ host: HostModel) {
        guard host.canDisconnect else { return }   // never remove Local
        host.shutdown()
        hosts.removeAll { $0.id == host.id }
        persist()
    }

    private func persist() {
        let saved = hosts.compactMap { host -> SavedHost? in
            guard let alias = host.transport.sshAlias else { return nil }
            return SavedHost(alias: alias, displayName: host.displayName)
        }
        HostPersistence.save(saved)
    }

    /// Tear down every host and reap server-side leftovers (called at quit).
    func shutdownAll() {
        qlog("shutdownAll BEGIN (\(hosts.count) hosts)")
        let targets = hosts.filter { $0.wantsConnection }.map {
            QuitCleanup.Target(transport: $0.transport, controlSession: $0.controlSessionName)
        }
        hosts.forEach { $0.shutdown() }
        qlog("shutdownAll: hosts torn down; running QuitCleanup (\(targets.count) targets)")
        QuitCleanup.run(targets: targets)
        qlog("shutdownAll END")
    }

    // MARK: Font

    private let baseFontSize: Double = 13
    func increaseFont() { fontSize = min((fontSize ?? baseFontSize) + 1, 36) }
    func decreaseFont() { fontSize = max((fontSize ?? baseFontSize) - 1, 8) }
    // Reset to an explicit base (not nil): the nil → `reset_font_size` path in
    // Termini doesn't reliably re-apply, whereas `set_font_size` does.
    func resetFont() { fontSize = baseFontSize }
}

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
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
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
            AppModel.current?.shutdownAll()
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
