import Foundation

/// State of the Claude Code status hooks on a host (see ClaudeHooks).
enum HookStatus: Equatable {
    case unknown
    case checking
    case installing
    case removing
    case installed
    case notInstalled
    case error(String)
}

/// One tmux server we talk to — the local machine, or a remote over SSH. Each
/// host owns its own control-mode link, session tree, and warm surfaces.
///
/// Connection lifecycle: `start()`/`reconnect()` set `wantsConnection`, and any
/// unexpected exit of the control process while we still want a connection
/// triggers a backoff reconnect. `disconnect()` clears the intent and tears the
/// link + surfaces down. The `ControlModeClient` (and its PTY process) is one-shot,
/// so each (re)connect builds a fresh one.
@MainActor
@Observable
final class HostModel: Identifiable {
    let id: String          // "local" or the ssh alias
    let displayName: String
    let transport: TmuxTransport
    let store = TmuxStore()
    let surfaceStore: SessionSurfaceStore
    private(set) var client: ControlModeClient

    /// This host's control-session name. Generated once per launch and reused
    /// across reconnects, so a blip re-attaches (`new-session -A`) to the same
    /// hidden session instead of churning names; it's unique per launch so two
    /// Belfry instances never collide. Also what quit-cleanup kills.
    let controlSessionName = ControlModeClient.makeControlSessionName()

    /// Whether the user wants this host connected. Drives auto-reconnect.
    private(set) var wantsConnection = false
    private var reconnectAttempts = 0
    private var reconnectWork: DispatchWorkItem?

    /// Whether this connection intent has ever reached `connected`. A link that
    /// has connected and then drops is treated as a transient outage (retry
    /// forever); one that has *never* connected is treated as a config/auth
    /// problem — give up after `maxColdAttempts` and surface why.
    private var everConnected = false
    private var lastFailureReason: String?
    private let maxColdAttempts = 4

    /// Whether Belfry's Claude-status hooks are installed on this host.
    private(set) var hooksStatus: HookStatus = .unknown
    private var didCheckHooks = false

    init(id: String, displayName: String, transport: TmuxTransport) {
        self.id = id
        self.displayName = displayName
        self.transport = transport
        self.surfaceStore = SessionSurfaceStore(transport: transport)
        self.client = ControlModeClient(
            store: store, transport: transport, controlSessionName: controlSessionName)
        wireClient()
    }

    static func local() -> HostModel {
        HostModel(id: "local", displayName: "Local", transport: .local)
    }

    static func ssh(alias: String, displayName: String? = nil) -> HostModel {
        // Default label is the first DNS label (e.g. "magrathea" from "magrathea.x.ts.net").
        let name = displayName ?? alias.split(separator: ".").first.map(String.init) ?? alias
        return HostModel(id: alias, displayName: name, transport: .ssh(alias: alias))
    }

    /// The local host is always meant to be connected and offers no disconnect.
    var canDisconnect: Bool { !transport.isLocal }

    // MARK: Lifecycle

    /// Connect (idempotent — a no-op while already connected/connecting).
    func start() {
        guard !wantsConnection else { return }
        wantsConnection = true
        reconnectAttempts = 0
        everConnected = false
        lastFailureReason = nil
        client.ensureSessionOnConnect = true
        client.start()
    }

    /// User-initiated disconnect: drop the link + warm surfaces, stay down.
    func disconnect() {
        wantsConnection = false
        reconnectWork?.cancel()
        reconnectWork = nil
        client.onExitHandler = nil   // deliberate stop must not schedule a reconnect
        client.stop()
        surfaceStore.teardownAll()
        store.clear()
        store.status = .offline
        // Drop the shared SSH master so a later Connect re-authenticates (lets you
        // re-enter a password) rather than silently reusing the cached connection.
        if let alias = transport.sshAlias { SSHControl.closeMaster(alias: alias) }
    }

    /// Reconnect now (also used by the UI's "Connect" on an offline host). This is
    /// an intentional connect, so it ensures a session exists.
    func reconnect() {
        reconnectWork?.cancel()
        reconnectWork = nil
        wantsConnection = true
        reconnectAttempts = 0
        everConnected = false       // fresh cold-attempt window for a manual retry
        lastFailureReason = nil
        store.status = .connecting
        // A *manual* retry should re-authenticate: close the shared SSH master
        // first so ssh prompts again (e.g. to fix a mistyped password), then
        // connect. Silent auto-reconnects skip this and reuse the master.
        if let alias = transport.sshAlias {
            SSHControl.closeMaster(alias: alias) { [weak self] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.rebuildClientAndStart(ensureSession: true) }
                }
            }
        } else {
            rebuildClientAndStart(ensureSession: true)
        }
    }

    /// Full teardown for app quit / host removal.
    func shutdown() {
        wantsConnection = false
        reconnectWork?.cancel()
        reconnectWork = nil
        client.onExitHandler = nil
        client.stop()
        surfaceStore.teardownAll()
    }

    // MARK: Reconnect plumbing

    private func wireClient() {
        client.onLivingSessions = { [weak self] ids in
            self?.surfaceStore.prune(livingSessionIDs: ids)
        }
        client.onConnected = { [weak self] in
            self?.everConnected = true
            self?.reconnectAttempts = 0
            self?.lastFailureReason = nil
            self?.checkHooksIfNeeded()
        }
        client.onExitHandler = { [weak self] reason in
            self?.handleUnexpectedExit(reason: reason)
        }
    }

    private func handleUnexpectedExit(reason: String?) {
        guard wantsConnection else { return }   // disconnect() cleared the intent
        if let reason, !reason.isEmpty { lastFailureReason = reason }
        // An auth failure won't fix itself on retry, and auto-retrying just re-pops
        // the password dialog. Surface it and stop until the user hits Reconnect.
        if !everConnected && isAuthFailure(lastFailureReason) {
            store.status = .disconnected(failureMessage)
            return
        }
        scheduleReconnect()
    }

    private func isAuthFailure(_ reason: String?) -> Bool {
        guard let reason = reason?.lowercased() else { return false }
        return reason.contains("permission denied")
            || reason.contains("authentication failed")
            || reason.contains("too many authentication")
    }

    private func scheduleReconnect() {
        guard wantsConnection, reconnectWork == nil else { return }
        // Never connected + repeated failures ⇒ almost certainly auth/config, not
        // a transient drop. Stop looping and show the reason; the user fixes it
        // and hits Reconnect (which resets this window).
        if !everConnected && reconnectAttempts >= maxColdAttempts {
            store.status = .disconnected(failureMessage)
            return
        }
        reconnectAttempts += 1
        let delay = min(2.0 * Double(reconnectAttempts), 15.0)
        store.status = .reconnecting(attempt: reconnectAttempts)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconnectWork = nil
            guard self.wantsConnection else { return }
            // Silent auto-reconnect: don't auto-create a session.
            self.rebuildClientAndStart(ensureSession: false)
        }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Short, user-facing reason for a failed connect. Prefers the actual ssh/tmux
    /// diagnostic; otherwise a generic hint. Password hosts no longer land here —
    /// the askpass dialog handles them — so this is real failure (wrong password,
    /// unreachable host, tmux missing, …).
    private var failureMessage: String {
        guard let reason = lastFailureReason?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reason.isEmpty else {
            return "Couldn’t connect — check the host and your SSH access"
        }
        return reason.count > 80 ? String(reason.prefix(79)) + "…" : reason
    }

    private func rebuildClientAndStart(ensureSession: Bool) {
        client.onExitHandler = nil            // detach the old client
        // Stop it explicitly: a *manual* reconnect can arrive while the old link
        // is still live, and just dropping the reference would strand its poll
        // timer in the run loop (firing no-ops forever) and leave its control
        // process to die by deinit timing. No-op if it already exited.
        client.stop()
        client = ControlModeClient(
            store: store, transport: transport, controlSessionName: controlSessionName)
        wireClient()
        client.ensureSessionOnConnect = ensureSession
        client.start()
    }

    // MARK: Claude status hooks

    /// Check once automatically after the first successful connect.
    private func checkHooksIfNeeded() {
        guard !didCheckHooks else { return }
        didCheckHooks = true
        checkHooks()
    }

    func checkHooks() {
        hooksStatus = .checking
        runHookIO { ClaudeHooks.check($0) }
    }

    func installHooks() {
        hooksStatus = .installing
        runHookIO { ClaudeHooks.install($0) }
    }

    func removeHooks() {
        hooksStatus = .removing
        runHookIO { ClaudeHooks.remove($0) }
    }

    /// Run a blocking ClaudeHooks call off the main thread, then fold the result
    /// back into `hooksStatus`.
    private func runHookIO(_ work: @escaping (TmuxTransport) -> ClaudeHooks.Outcome) {
        let transport = self.transport
        DispatchQueue.global().async { [weak self] in
            let outcome = work(transport)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch outcome {
                    case .status(let installed):
                        self?.hooksStatus = installed ? .installed : .notInstalled
                    case .failure(let message):
                        self?.hooksStatus = .error(message)
                    }
                }
            }
        }
    }
}
