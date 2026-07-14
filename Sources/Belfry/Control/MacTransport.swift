import Foundation
import SwiftUI
import Termini

// macOS side of the transport seam: `TmuxTransport` (local tmux binary, or the
// system ssh binary with ControlMaster sharing) implements `HostTransport`,
// with a forkpty-backed `ControlChannel` and Termini's local-PTY workspace as
// the surface. iOS has its own implementations over library SSH.

/// Control channel backed by a local PTY process (`tmux -C …` directly, or
/// `ssh <alias> tmux -C …`). For the local server it first makes sure launchd —
/// not Belfry — owns the tmux server, so a Dock force-quit can't kill it.
@MainActor
final class PTYControlChannel: ControlChannel {
    var onOutput: ((Data) -> Void)?
    var onReady: (() -> Void)?
    var onExit: ((Int32) -> Void)?

    private let process = TerminiLocalPTYProcess()
    private let spec: TerminiProcessSpec
    private var stopRequested = false

    // The LOCAL server is ensured (launchd-owned, coalition-safe) *before* this
    // channel is started — see `TmuxTransport.prepareServer`, driven by HostModel
    // so a wedged server can be surfaced to the user instead of silently hijacked.
    init(spec: TerminiProcessSpec) {
        self.spec = spec
        process.onOutput = { [weak self] data in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.onOutput?(data) }
            }
        }
        process.onExit = { [weak self] code in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.onExit?(code) }
            }
        }
    }

    func start() {
        startProcess()
    }

    private func startProcess() {
        guard !stopRequested else { return }
        do {
            try process.start(spec: spec, initialSize: .init(columns: 200, rows: 50))
            onReady?()
        } catch {
            clog("control channel failed to start: \(error.localizedDescription)")
            onExit?(-1)
        }
    }

    func send(_ data: Data) {
        process.send(data)
    }

    func stop() {
        stopRequested = true
        process.terminate()
    }
}

extension TmuxTransport: HostTransport {
    var savedHost: SavedHost? {
        guard let alias = sshAlias else { return nil }
        return SavedHost(alias: alias, displayName: nil)
    }

    var hooksManager: (any HooksManaging)? {
        TmuxHooksManager(transport: self)
    }

    // Ensure the LOCAL tmux server is up (launchd-owned) before a client attaches.
    // Runs the blocking probe/wait off-main. Only the local transport has a server
    // to pre-flight; ssh hosts fall through to the protocol default (`.ready`).
    func prepareServer(controlSessionName: String, forceCreate: Bool) async -> ServerReadiness {
        guard isLocal else { return .ready }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let result = LaunchdTmux.ensureLocalServer(
                    controlSessionName: controlSessionName, forceCreate: forceCreate)
                continuation.resume(returning: result == .ready ? .ready : .unresponsive)
            }
        }
    }

    // `-u` on every client: a GUI-launched app has no LANG in its environment,
    // and a non-UTF-8 tmux client gets every non-ASCII cell rewritten as `_`.
    func makeControlChannel(controlSessionName: String) -> any ControlChannel {
        PTYControlChannel(
            spec: tmuxProcessSpec(["-u", "-C", "new-session", "-A", "-s", controlSessionName]))
    }

    func makeSurfaceWorkspace(sessionName: String) -> any TerminalWorkspace {
        TerminiLocalPTYWorkspace(
            processSpec: tmuxProcessSpec(["-u", "new-session", "-A", "-s", sessionName]))
    }

    func invalidateAuthentication(completion: @escaping @MainActor () -> Void) {
        guard let alias = sshAlias else { completion(); return }
        // Drop the shared SSH master (`ssh -O exit`) so the next connect
        // re-authenticates instead of silently reusing the cached connection.
        SSHControl.closeMaster(alias: alias) {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion() }
            }
        }
    }

    func cleanUpOnRemoval() {
        // Nothing stored: keys/passwords live in the user's ~/.ssh setup.
    }
}

extension TerminiLocalPTYWorkspace: TerminalWorkspace {
    func resize(columns: Int, rows: Int) {
        resize(to: .init(columns: columns, rows: rows))
    }

    func focus() {
        controller.focus()
    }

    func sendInput(_ data: Data) {
        send(data)
    }

    func makeSurfaceView(fontSize: Double?, isVisible: Bool) -> AnyView {
        AnyView(
            TerminiTerminalView(controller: controller,
                                appearance: TerminiTerminalAppearance(
                                    theme: SurfaceTheme.theme,
                                    fontSize: fontSize,
                                    extraConfigFilePaths: SurfaceTheme.configFilePaths),
                                // Hidden warm surfaces keep absorbing output but stop
                                // rendering entirely (battery) — see LOCAL_PATCHES.md.
                                isRenderVisible: isVisible)
        )
    }
}

/// Bridges the shared HooksManaging seam to the macOS ClaudeHooks engine
/// (which shells out over the same transport).
struct TmuxHooksManager: HooksManaging {
    let transport: TmuxTransport

    func check() -> HooksOutcome { map(ClaudeHooks.check(transport)) }
    func install() -> HooksOutcome { map(ClaudeHooks.install(transport)) }
    func remove() -> HooksOutcome { map(ClaudeHooks.remove(transport)) }

    private func map(_ outcome: ClaudeHooks.Outcome) -> HooksOutcome {
        switch outcome {
        case .status(let installed, let current): return .status(installed: installed, current: current)
        case .failure(let message): return .failure(message)
        }
    }
}

extension HostModel {
    static func local() -> HostModel {
        HostModel(id: "local", displayName: "Local", transport: TmuxTransport.local)
    }

    static func ssh(alias: String, displayName: String? = nil) -> HostModel {
        // Default label is the first DNS label (e.g. "magrathea" from "magrathea.x.ts.net").
        let name = displayName ?? alias.split(separator: ".").first.map(String.init) ?? alias
        return HostModel(id: alias, displayName: name, transport: TmuxTransport.ssh(alias: alias))
    }
}

extension AppModel {
    /// macOS add-host entry point: an ssh-config alias / user@host string that
    /// the system ssh binary resolves.
    @discardableResult
    func addHost(alias: String, displayName: String? = nil) -> HostModel? {
        let alias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidSSHAlias(alias) else { return nil }
        return adopt(.ssh(alias: alias, displayName: displayName))
    }

    /// Tear down every host and reap server-side leftovers (called at quit).
    func shutdownAllWithCleanup() {
        qlog("shutdownAll BEGIN (\(hosts.count) hosts)")
        let targets = hosts.filter { $0.wantsConnection }.compactMap { host -> QuitCleanup.Target? in
            guard let transport = host.transport as? TmuxTransport else { return nil }
            return QuitCleanup.Target(transport: transport, controlSession: host.controlSessionName)
        }
        shutdownAll()
        qlog("shutdownAll: hosts torn down; running QuitCleanup (\(targets.count) targets)")
        QuitCleanup.run(targets: targets)
        qlog("shutdownAll END")
    }
}
