import Foundation

/// Drives a persistent `tmux -C` control-mode connection and keeps a `TmuxStore`
/// in sync with the whole server.
///
/// Design notes:
/// - We attach control mode to a dedicated hidden session
///   (`__belfry-ctl-<host>-<pid>-<nonce>`, unique per launch) so the control
///   client never becomes a *sizing* client of the user's real sessions, and so
///   two Belfry instances on one server never share — or reap — each other's
///   control session. Orphans from dead instances are reaped on connect, gated on
///   liveness so a still-running instance's session is always spared.
/// - tmux's `%window-*` notifications only fire for the control client's *own*
///   session, so for cross-session reactivity we re-list on `%sessions-changed`
///   plus a `refresh-client -B` format subscription (tmux ≥ 3.2): the *server*
///   watches the whole session/window tree and pushes `%subscription-changed`
///   when it changes, so the app sleeps unless something actually happened. A
///   periodic re-list remains as a backstop — slow once a subscription
///   notification proves the server supports push, legacy-fast otherwise.
/// - Query output is tagged with a literal line prefix (`SESS`/`WIN`) so we can
///   parse by line-prefix and skip fragile command↔response correlation.
final class ControlModeClient {
    private let store: TmuxStore
    /// Platform byte channel to the control-mode tmux (PTY on macOS, SSH on iOS).
    private let channel: any ControlChannel

    /// Called with the current living session ids after each session-list refresh
    /// (used to prune warm surfaces for sessions that have gone away).
    var onLivingSessions: ((Set<String>) -> Void)?

    /// Fired when the connection first reaches `connected` (used to reset reconnect
    /// backoff). May fire on every refresh; treat as idempotent.
    var onConnected: (() -> Void)?

    /// Fired when the control process exits, with a human-readable failure reason
    /// if we noticed one (e.g. "Permission denied"). The owner decides whether to
    /// reconnect and how to surface it.
    var onExitHandler: ((String?) -> Void)?

    /// Most recent error-looking line seen outside the protocol stream (ssh / tmux
    /// diagnostics like "Permission denied", "Connection refused"). Surfaced on exit.
    private var lastDiagnostic: String?

    private var lineBuffer = Data()
    private var inBlock = false
    private var blockLines: [String] = []

    private var refreshTimer: Timer?
    private var refreshDebounce: DispatchWorkItem?
    /// Fires if a fresh connect never delivers its first session list in time, so
    /// a stalled control stream surfaces a reason instead of spinning forever.
    private var connectWatchdog: Timer?
    private var isStarted = false
    /// Set once the server delivers a `%subscription-changed` (proving it
    /// supports `refresh-client -B` push updates); the poll then drops from
    /// `fastRefreshInterval` to the slow `backstopRefreshInterval`.
    private var subscriptionsConfirmed = false
    /// Set by `stop()` so a control client whose disclaimed server-start is still in
    /// flight doesn't connect after we've been asked to disconnect.
    private var stopRequested = false

    /// When true, create a default session on connect if the server has no
    /// user-visible sessions. Set by the owner for intentional connects (first
    /// connect / user-pressed Connect), left false for silent auto-reconnects so
    /// we don't resurrect sessions the user deliberately killed.
    var ensureSessionOnConnect = false
    private var didEnsureSession = false
    private let defaultSessionName = "main"

    /// Reap orphaned control sessions once per (re)connect, on the first list.
    private var didReap = false

    /// Shared prefix of every Belfry control session (current + this instance's).
    /// Stays within `TmuxStore.internalSessionPrefix` so the sidebar hides them,
    /// and lets us recognise control sessions left by other launches when reaping.
    static let controlSessionPrefix = "__belfry-ctl"
    /// Pre-rename / fixed names we still recognise when reaping orphans.
    private static let legacyControlPrefixes = ["__sessionator-ctl"]

    /// This instance's dedicated hidden control session, unique per launch (see
    /// `makeControlSessionName`). The control client attaches here so it never
    /// sizes a real session and never collides with another Belfry instance.
    let controlSessionName: String

    /// Build a per-launch control-session name from a sanitized client hostname,
    /// the pid, and a random nonce — unique across machines and launches, and an
    /// orphan stays traceable to whoever left it.
    static func makeControlSessionName() -> String {
        let host = ProcessInfo.processInfo.hostName.lowercased()
            .filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
            .prefix(16)
        let pid = ProcessInfo.processInfo.processIdentifier
        let nonce = String(format: "%04x", UInt16.random(in: 0...UInt16.max))
        return "\(controlSessionPrefix)-\(host.isEmpty ? "host" : host)-\(pid)-\(nonce)"
    }

    private static let sessionFormat =
        "SESS #{session_id} #{session_attached} #{session_windows} #{session_name}"
    // `pane_current_command` (active pane) + `@claude_state` (window option set by
    // Claude Code hooks) drive the per-window Claude status badge; `@claude_title`
    // (same hooks) carries the Claude session name; `pane_current_path` gives
    // pinned rows their working-directory context.
    // Window fields are TAB-separated (unlike the session line): the path can
    // contain spaces, so positional space-splitting can't carry both it and the
    // greedy window name. The hooks strip tabs/newlines from the title before
    // setting it, so it can't break this positional parse.
    private static let windowFormat =
        "WIN\t#{session_id}\t#{window_id}\t#{window_index}\t#{window_active}\t#{window_activity_flag}\t#{window_bell_flag}\t#{pane_current_command}\t#{@claude_state}\t#{@claude_title}\t#{pane_current_path}\t#{window_name}"

    /// Poll cadence before the server has proven push support (old tmux), and
    /// the slow backstop once `%subscription-changed` notifications flow.
    private static let fastRefreshInterval: TimeInterval = 2.0
    private static let backstopRefreshInterval: TimeInterval = 30.0
    /// A healthy connect delivers its first session list well under a second; if
    /// none arrives this long after we start, treat control mode as stalled (e.g.
    /// the tmux driving it is a different build than the server it attached to) and
    /// fail with a diagnostic rather than an endless "Connecting…".
    private static let connectTimeout: TimeInterval = 12.0

    /// Format for the server-side tree subscription: every session (`#{S:}` loop)
    /// with its windows nested (`#{W:}` loop), covering everything the sidebar
    /// renders (attach state, active/activity/bell flags, foreground command,
    /// `@claude_state`, names). The value is never parsed — any change simply
    /// triggers a re-list — so the separators only need to make changes visible,
    /// not be unambiguous. NOTE: a literal `,` inside `#{S:}`/`#{W:}` is loop
    /// syntax (it introduces the current-item alternate format) and silently
    /// breaks nesting — no commas allowed here.
    private static let treeSubscriptionFormat =
        "#{S:#{session_id}#{session_attached}#{session_name}="
        + "#{W:#{window_id}#{window_index}#{window_active}#{window_activity_flag}"
        + "#{window_bell_flag}#{pane_current_command}#{@claude_state}#{@claude_title}"
        + "#{pane_current_path}#{window_name}|}~}"

    @MainActor
    init(store: TmuxStore, channel: any ControlChannel, controlSessionName: String) {
        self.store = store
        self.channel = channel
        self.controlSessionName = controlSessionName
        channel.onOutput = { [weak self] data in
            self?.ingest(data)
        }
        channel.onReady = { [weak self] in
            self?.beginProtocol()
        }
        channel.onExit = { [weak self] code in
            self?.handleExit(code)
        }
    }

    @MainActor
    func start() {
        store.status = .connecting
        didEnsureSession = false
        didReap = false
        lastDiagnostic = nil
        stopRequested = false
        armConnectWatchdog()
        channel.start()
    }

    /// (Re)arm the connect watchdog. Cancelled the moment the first session list
    /// arrives (`processBlock`), and on stop/exit.
    @MainActor
    private func armConnectWatchdog() {
        connectWatchdog?.invalidate()
        let timer = Timer(timeInterval: Self.connectTimeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.connectTimedOut() }
        }
        RunLoop.main.add(timer, forMode: .common)
        connectWatchdog = timer
    }

    @MainActor
    private func connectTimedOut() {
        connectWatchdog = nil
        guard !stopRequested, !store.status.isLive else { return }
        clog("no session list within \(Int(Self.connectTimeout))s — control mode stalled")
        if lastDiagnostic == nil {
            lastDiagnostic = "tmux control mode didn't respond — Belfry's tmux may be a "
                + "different build than the tmux running your sessions"
        }
        // Tear the half-open channel down; the normal exit path surfaces the reason
        // and lets the owner back off / stop looping.
        channel.stop()
    }

    /// The channel is up (PTY spawned / SSH exec running): send the initial
    /// protocol commands and arm the backstop poll.
    @MainActor
    private func beginProtocol() {
        guard !stopRequested else { return }
        send("refresh-client -C 200,50")
        // Server-side change watching: tmux re-evaluates the format ~1/s in
        // the server and pushes %subscription-changed only when the value
        // differs — no client wakeups, PTY traffic, or (for SSH hosts)
        // network chatter while nothing changes. Errors harmlessly on
        // tmux < 3.2, in which case the fast poll below stays in charge.
        send("refresh-client -B 'belfry-tree::\(Self.treeSubscriptionFormat)'")
        refreshNow()
        startRefreshTimer(interval: Self.fastRefreshInterval)
        isStarted = true
        clog("control client started")
    }

    /// (Re)start the periodic re-list. Generous tolerance lets the OS coalesce
    /// the wakeup with other timers — this is a backstop, not a heartbeat.
    @MainActor
    private func startRefreshTimer(interval: TimeInterval) {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshNow() }
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    @MainActor
    func stop() {
        stopRequested = true
        refreshTimer?.invalidate()
        refreshTimer = nil
        connectWatchdog?.invalidate()
        connectWatchdog = nil
        isStarted = false
        channel.stop()
    }

    /// Make `windowID` (e.g. "@6") the active window of its session, server-side.
    /// The render surface attached to that session follows automatically.
    @MainActor
    func selectWindow(_ windowID: String) {
        send("select-window -t \(windowID)")
    }

    // MARK: Server-side actions (drive tmux from the sidebar)

    @MainActor func renameSession(id: String, to name: String) {
        send("rename-session -t \(id) \(Self.quote(name))")
        scheduleRefresh()
    }

    @MainActor func killSession(id: String) {
        send("kill-session -t \(id)")
        scheduleRefresh()
    }

    @MainActor func newSession(name: String) {
        // Detached create so it doesn't disturb the control client's own session.
        // Pin the start directory to home: a detached new-session has no client/pane
        // to derive a cwd from, so without -c it inherits the server's cwd (which is
        // "/" for an already-running launchd server).
        send("new-session -d -c \(Self.quote(NSHomeDirectory())) -s \(Self.quote(name))")
        scheduleRefresh()
    }

    @MainActor func newWindow(inSession sessionID: String) {
        // Start in the session's active pane directory, matching splitWindow, rather
        // than falling back to the server cwd.
        send("new-window -c '#{pane_current_path}' -t \(sessionID)")
        scheduleRefresh()
    }

    @MainActor func renameWindow(id: String, to name: String) {
        send("rename-window -t \(id) \(Self.quote(name))")
        scheduleRefresh()
    }

    /// Split the window's active pane (`horizontal` = side by side, else
    /// stacked). tmux expands `#{pane_current_path}` against the target pane,
    /// so the new pane starts in the same directory — matching the common
    /// `bind % split-window -c "#{pane_current_path}"` convention.
    @MainActor func splitWindow(id: String, horizontal: Bool) {
        send("split-window \(horizontal ? "-h" : "-v") -c '#{pane_current_path}' -t \(id)")
        scheduleRefresh()
    }

    @MainActor func killWindow(id: String) {
        send("kill-window -t \(id)")
        scheduleRefresh()
    }

    /// Single-quote a tmux command argument. Callers sanitize names to drop the
    /// single-quote character itself (tmux single-quotes can't contain one), so a
    /// plain wrap is safe here.
    private static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "") + "'"
    }

    // MARK: Commands

    @MainActor
    private func send(_ command: String) {
        channel.send(Data((command + "\n").utf8))
    }

    /// Re-query the full session + window list.
    @MainActor
    private func refreshNow() {
        send("list-sessions -F '\(Self.sessionFormat)'")
        send("list-windows -a -F '\(Self.windowFormat)'")
    }

    /// Coalesce refreshes triggered by a burst of notifications.
    @MainActor
    private func scheduleRefresh() {
        guard refreshDebounce == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshDebounce = nil
                self?.refreshNow()
            }
        }
        refreshDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    // MARK: Parsing

    @MainActor
    private func ingest(_ data: Data) {
        lineBuffer.append(data)
        while let newlineIndex = lineBuffer.firstIndex(of: 0x0A) {
            let lineData = lineBuffer[lineBuffer.startIndex..<newlineIndex]
            lineBuffer.removeSubrange(lineBuffer.startIndex...newlineIndex)
            var line = String(decoding: lineData, as: UTF8.self)
            if line.hasSuffix("\r") { line.removeLast() }
            handleLine(line)
        }
    }

    @MainActor
    private func handleLine(_ line: String) {
        if line.hasPrefix("%begin") {
            inBlock = true
            blockLines.removeAll(keepingCapacity: true)
            return
        }
        if line.hasPrefix("%end") || line.hasPrefix("%error") {
            inBlock = false
            processBlock(blockLines)
            blockLines.removeAll(keepingCapacity: true)
            return
        }
        if inBlock {
            blockLines.append(line)
            return
        }
        // Outside a block: a notification, or echoed input we don't care about.
        if line.hasPrefix("%") {
            handleNotification(line)
            return
        }
        noteDiagnostic(line)
    }

    /// Remember the last line that looks like an ssh/tmux failure, so a connect
    /// that never succeeds can tell the user *why* instead of looping silently.
    @MainActor
    private func noteDiagnostic(_ line: String) {
        let l = line.lowercased()
        let markers = [
            "permission denied", "denied", "authentication failed",
            "too many authentication", "connection refused", "connection timed out",
            "operation timed out", "could not resolve", "no route to host",
            "host key verification failed", "remote host identification has changed",
            "command not found", "not a directory", "connection closed",
            "no such file or directory", "tmux not found",
        ]
        if markers.contains(where: { l.contains($0) }) {
            lastDiagnostic = line.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    @MainActor
    private func processBlock(_ lines: [String]) {
        // A block is the response to exactly one query, so it carries only one
        // kind of tagged line (SESS or WIN).
        if lines.contains(where: { $0.hasPrefix("SESS ") }) {
            let sessions = lines.compactMap { $0.hasPrefix("SESS ") ? Self.parseSession($0) : nil }
            reapOrphanedControlSessions(sessions)
            store.applySessionList(sessions)
            connectWatchdog?.invalidate()
            connectWatchdog = nil
            let wasLive = store.status.isLive
            store.setStatus(.connected)
            if !wasLive { onConnected?() }
            onLivingSessions?(Set(sessions.map(\.id)))
            ensureDefaultSessionIfEmpty(sessions)
        }
        if lines.contains(where: { $0.hasPrefix("WIN\t") }) {
            let windows = lines.compactMap { $0.hasPrefix("WIN\t") ? Self.parseWindow($0) : nil }
            store.applyWindowList(windows)
        }
    }

    /// On the first session list after an intentional connect, if there are no
    /// user-visible sessions (the server wasn't running anything but our control
    /// session), create a default one so the host is immediately usable.
    @MainActor
    private func ensureDefaultSessionIfEmpty(_ sessions: [(id: String, name: String, attached: Int)]) {
        guard ensureSessionOnConnect, !didEnsureSession else { return }
        didEnsureSession = true
        let hasUserSession = sessions.contains { !$0.name.hasPrefix(TmuxStore.internalSessionPrefix) }
        guard !hasUserSession else { return }
        clog("no sessions on connect — creating default session '\(defaultSessionName)'")
        newSession(name: defaultSessionName)
    }

    /// Kill control sessions left behind by *other* Belfry launches that no longer
    /// have a client attached (their app died without a clean shutdown). Gated on
    /// `session_attached == 0`, so a still-running sibling instance — whose control
    /// client is attached — is never touched, even across machines. Our own session
    /// is excluded by name. Runs once per (re)connect.
    @MainActor
    private func reapOrphanedControlSessions(_ sessions: [(id: String, name: String, attached: Int)]) {
        guard !didReap else { return }
        didReap = true
        let prefixes = [Self.controlSessionPrefix] + Self.legacyControlPrefixes
        for session in sessions
        where session.name != controlSessionName
            && session.attached == 0
            && prefixes.contains(where: { session.name.hasPrefix($0) }) {
            clog("reaping orphaned control session \(session.name) (\(session.id))")
            send("kill-session -t \(session.id)")
        }
    }

    @MainActor
    private func handleNotification(_ line: String) {
        // Any structural change → refresh. Skip the high-frequency / irrelevant ones.
        if line.hasPrefix("%output") || line.hasPrefix("%extended-output") { return }
        // The server-side tree subscription fired: something in the session/window
        // tree changed (at most once a second). First one also proves the server
        // supports push, so the poll drops to its slow backstop.
        if line.hasPrefix("%subscription-changed") {
            if !subscriptionsConfirmed {
                subscriptionsConfirmed = true
                clog("push subscriptions active — poll slowed to \(Int(Self.backstopRefreshInterval))s backstop")
                startRefreshTimer(interval: Self.backstopRefreshInterval)
            }
            scheduleRefresh()
            return
        }
        if line.hasPrefix("%sessions-changed")
            || line.hasPrefix("%session-renamed")
            || line.hasPrefix("%session-window-changed")
            || line.hasPrefix("%window-add")
            || line.hasPrefix("%window-close")
            || line.hasPrefix("%window-renamed")
            || line.hasPrefix("%unlinked-window") {
            scheduleRefresh()
        }
    }

    private static func parseSession(_ line: String) -> (id: String, name: String, attached: Int)? {
        // SESS <id> <attached> <windows> <name...>
        // `session_attached` is a client COUNT, not a flag (2 clients → "2").
        let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: false)
        guard parts.count >= 5 else { return nil }
        let id = String(parts[1])
        let attached = Int(parts[2]) ?? 0
        let name = String(parts[4])
        return (id, name, attached)
    }

    private static func parseWindow(_ line: String) -> TmuxWindow? {
        // WIN <sid> <wid> <index> <active> <activity> <bell> <command> <claude_state> <claude_title> <path> <name...>
        // TAB-separated (see `windowFormat`): the path can contain spaces.
        let parts = line.split(separator: "\t", maxSplits: 11, omittingEmptySubsequences: false)
        guard parts.count >= 12 else { return nil }
        return TmuxWindow(
            id: String(parts[2]),
            sessionID: String(parts[1]),
            index: Int(parts[3]) ?? 0,
            name: String(parts[11]),
            isActive: parts[4] == "1",
            hasActivity: parts[5] == "1",
            hasBell: parts[6] == "1",
            claudeState: ClaudeState(command: String(parts[7]), hookState: String(parts[8])),
            claudeTitle: String(parts[9]),
            currentPath: String(parts[10])
        )
    }

    @MainActor
    private func handleExit(_ code: Int32) {
        clog("control client exited (code \(code))")
        if store.status.isLive || isStarted {
            store.status = .disconnected("connection lost")
        }
        refreshTimer?.invalidate()
        refreshTimer = nil
        connectWatchdog?.invalidate()
        connectWatchdog = nil
        isStarted = false
        onExitHandler?(lastDiagnostic)
    }
}

/// Lightweight stderr logger for bring-up (visible in the run log).
func clog(_ message: String) {
    FileHandle.standardError.write(Data("[ctl] \(message)\n".utf8))
}
