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
/// unexpected exit of the control channel while we still want a connection
/// triggers a backoff reconnect. `disconnect()` clears the intent and tears the
/// link + surfaces down. The `ControlModeClient` (and its channel) is one-shot,
/// so each (re)connect builds a fresh one.
@MainActor
@Observable
final class HostModel: Identifiable {
    let id: String          // "local" or the ssh alias / saved-host id
    let displayName: String
    let transport: any HostTransport
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

    /// The local tmux server is up but not answering (classically the box
    /// thrashing under memory pressure) and has stayed that way past the auto-wait.
    /// Drives the "server stuck" prompt; cleared when the user chooses or a later
    /// connect succeeds. We stop here rather than let the client hijack the socket.
    private(set) var serverStuck = false

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

    init(id: String, displayName: String, transport: any HostTransport) {
        self.id = id
        self.displayName = displayName
        self.transport = transport
        self.surfaceStore = SessionSurfaceStore { sessionName in
            transport.makeSurfaceWorkspace(sessionName: sessionName)
        }
        self.client = ControlModeClient(
            store: store,
            channel: transport.makeControlChannel(controlSessionName: controlSessionName),
            controlSessionName: controlSessionName)
        wireClient()
    }

    /// The local host is always meant to be connected and offers no disconnect.
    var canDisconnect: Bool { !transport.isLocal }

    /// Whether this host supports Claude-hooks management (macOS transports do).
    var supportsHooksManagement: Bool { transport.hooksManager != nil }

    // MARK: Lifecycle

    /// Connect (idempotent — a no-op while already connected/connecting).
    func start() {
        guard !wantsConnection else { return }
        wantsConnection = true
        reconnectAttempts = 0
        everConnected = false
        lastFailureReason = nil
        prepareThenStart(ensureSession: true, forceServerCreate: false)
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
        // Drop cached auth so a later Connect re-authenticates (lets you re-enter
        // a password) rather than silently reusing a cached connection.
        transport.invalidateAuthentication {}
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
        // A *manual* retry should re-authenticate: drop cached auth first so the
        // next connect prompts again (e.g. to fix a mistyped password), then
        // connect. Silent auto-reconnects skip this and reuse cached auth.
        transport.invalidateAuthentication { [weak self] in
            self?.rebuildClientAndStart(ensureSession: true)
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

    /// App moved to the background (iOS): drop the live connections quietly but
    /// keep the intent, so `resumeIfWanted()` restores everything on foreground.
    /// Sessions live in the tmux server; only our links are torn down.
    func suspend() {
        guard wantsConnection else { return }
        reconnectWork?.cancel()
        reconnectWork = nil
        client.onExitHandler = nil
        client.stop()
        surfaceStore.teardownAll()
        store.clear()
        store.status = .disconnected("suspended")
    }

    /// Foreground again (iOS): reconnect hosts whose intent survived suspension.
    func resumeIfWanted() {
        guard wantsConnection else { return }
        reconnectAttempts = 0
        store.status = .connecting
        rebuildClientAndStart(ensureSession: false)
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
    /// diagnostic; otherwise a generic hint.
    private var failureMessage: String {
        guard let reason = lastFailureReason?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reason.isEmpty else {
            return "Couldn’t connect — check the host and your SSH access"
        }
        return reason.count > 80 ? String(reason.prefix(79)) + "…" : reason
    }

    private func rebuildClientAndStart(ensureSession: Bool, forceServerCreate: Bool = false) {
        client.onExitHandler = nil            // detach the old client
        // Stop it explicitly: a *manual* reconnect can arrive while the old link
        // is still live, and just dropping the reference would strand its poll
        // timer in the run loop (firing no-ops forever) and leave its control
        // process to die by deinit timing. No-op if it already exited.
        client.stop()
        client = ControlModeClient(
            store: store,
            channel: transport.makeControlChannel(controlSessionName: controlSessionName),
            controlSessionName: controlSessionName)
        wireClient()
        prepareThenStart(ensureSession: ensureSession, forceServerCreate: forceServerCreate)
    }

    /// Ensure the host's tmux server is reachable, then start the control client.
    /// If the local server is wedged past the auto-wait, surface the decision to
    /// the user (`serverStuck`) instead of letting the client hijack the socket.
    private func prepareThenStart(ensureSession: Bool, forceServerCreate: Bool) {
        serverStuck = false
        client.ensureSessionOnConnect = ensureSession
        let startedClient = client
        let name = controlSessionName
        Task { @MainActor [weak self] in
            guard let self else { return }
            let readiness = await self.transport.prepareServer(
                controlSessionName: name, forceCreate: forceServerCreate)
            // Bail if the intent changed or the client was rebuilt while we waited.
            guard self.wantsConnection, self.client === startedClient else { return }
            switch readiness {
            case .ready:        startedClient.start()
            case .unresponsive: self.enterServerStuckState()
            }
        }
    }

    /// The local server is present but has stayed unresponsive past the auto-wait.
    /// Stop (no auto-reconnect, no hijack) and let the UI ask the user what to do.
    private func enterServerStuckState() {
        reconnectWork?.cancel()
        reconnectWork = nil
        store.status = .disconnected("Local tmux server isn’t responding")
        serverStuck = true
    }

    /// User chose "Start fresh server" over a stuck one — abandons the wedged
    /// server's sessions and boots a clean one.
    func createFreshServer() {
        guard wantsConnection else { return }
        serverStuck = false
        reconnectAttempts = 0
        store.status = .connecting
        rebuildClientAndStart(ensureSession: true, forceServerCreate: true)
    }

    /// User chose "Keep waiting" — re-enter the auto-wait; if the server recovers
    /// we attach, otherwise the prompt returns.
    func keepWaitingForServer() {
        guard wantsConnection else { return }
        serverStuck = false
        reconnectAttempts = 0
        store.status = .connecting
        rebuildClientAndStart(ensureSession: false, forceServerCreate: false)
    }

    // MARK: Claude status hooks

    /// Check once automatically after the first successful connect.
    private func checkHooksIfNeeded() {
        guard !didCheckHooks, supportsHooksManagement else { return }
        didCheckHooks = true
        checkHooks()
    }

    func checkHooks() {
        hooksStatus = .checking
        runHookIO { $0.check() }
    }

    func installHooks() {
        hooksStatus = .installing
        runHookIO { $0.install() }
    }

    func removeHooks() {
        hooksStatus = .removing
        runHookIO { $0.remove() }
    }

    /// Run a blocking hooks call off the main thread, then fold the result
    /// back into `hooksStatus`.
    private func runHookIO(_ work: @escaping @Sendable (any HooksManaging) -> HooksOutcome) {
        guard let manager = transport.hooksManager else {
            hooksStatus = .unknown
            return
        }
        DispatchQueue.global().async { [weak self] in
            let outcome = work(manager)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch outcome {
                    case .status(installed: true, current: false):
                        // Hooks from an older Belfry are installed — their commands
                        // are stale (e.g. Stop used to report "waiting"). The user
                        // already opted in, so refresh them in place; install() is
                        // idempotent and reports .status(true, true), ending this.
                        self?.installHooks()
                    case .status(let installed, _):
                        self?.hooksStatus = installed ? .installed : .notInstalled
                    case .failure(let message):
                        self?.hooksStatus = .error(message)
                    }
                }
            }
        }
    }
}
