import Foundation

/// Starts the LOCAL tmux server inside **launchd's** coalition instead of Belfry's, so a
/// Dock "Force Quit" of Belfry can't take it down.
///
/// Why this exists: the Dock's quit path for an unresponsive app is
/// `_LSForceQuitApplication`, which SIGKILLs the app's entire process *coalition*. A tmux
/// server started by one of Belfry's own PTY children inherits Belfry's coalition, so a
/// force-quit destroys every local session. A process's coalition is fixed at spawn and
/// cannot be moved afterward, and neither `setsid`, double-fork daemonization, nor
/// LaunchServices "disclaim" leaves the coalition — the only reliable escape is to have
/// **launchd** spawn the server. We do that via a tiny transient user agent; Belfry's
/// control client then just *attaches* to the already-running server. On a force-quit only
/// the client (in Belfry's coalition) dies — a harmless detach — and the server, with the
/// user's sessions, keeps running.
enum LaunchdTmux {
    /// Stable label so re-launches reuse (and can clear) the same job.
    static let label = "net.robgough.belfry.localserver"

    /// Ensure a local tmux server is running, launched by launchd if it isn't already.
    ///
    /// - If a server is already up (ours from a prior launch, or the user's own terminal),
    ///   leave it: it isn't in Belfry's coalition, so it's already safe.
    /// - Otherwise write a transient LaunchAgent that runs `tmux new-session -A -d -s <ctl>`
    ///   and `launchctl bootstrap` it into the GUI domain, then wait (bounded) for the
    ///   server to accept a query.
    ///
    /// Best-effort and strictly bounded — every subprocess has a timeout and the wait loop
    /// is capped — so the caller can always proceed to start its control client afterward,
    /// even if launchd misbehaves (worst case the control client starts the server itself,
    /// i.e. back to the old, still-functional behavior).
    /// Outcome of `ensureLocalServer`, so the caller knows whether a control client
    /// may safely attach (`.ready`) or whether the server is wedged and the user
    /// should be asked what to do (`.unresponsive`).
    enum EnsureResult { case ready, unresponsive }

    /// How long to silently wait out a stalled server before giving up and asking
    /// the user. A memory-pressure stall is usually seconds; 60s comfortably clears
    /// a jetsam thrash without pestering the user, yet bounds the wait.
    private static let stallWait: TimeInterval = 60

    @discardableResult
    static func ensureLocalServer(controlSessionName: String, forceCreate: Bool = false) -> EnsureResult {
        // The user explicitly chose "Start fresh server" over a stuck one: create,
        // accepting that this abandons whatever the wedged server was holding.
        if forceCreate {
            qlog("LaunchdTmux: forceCreate — starting a fresh server at user request")
            startViaLaunchd(controlSessionName: controlSessionName)
            return .ready
        }
        // Decide, safely, whether to START a server or just ATTACH to one already
        // there. The subtlety this guards against: if a server is alive but
        // momentarily *unresponsive* — classically the host thrashing under memory
        // pressure — a naive "is it up? no → start one" misreads the stall as
        // absence and runs `new-session`, which makes tmux treat the live socket as
        // stale, unlink it, and spawn a SECOND server. Both then claim the default
        // socket, silently splitting the user's sessions across two servers, one of
        // which becomes unreachable by path. So: only ever create when the server is
        // *confirmed absent*; while it's merely stalled, wait (bounded) and re-probe.
        let deadline = Date().addingTimeInterval(stallWait)
        while true {
            switch probeServer() {
            case .up:
                qlog("LaunchdTmux: local server already running; attaching (no launchd start)")
                return .ready
            case .absent:
                startViaLaunchd(controlSessionName: controlSessionName)
                return .ready
            case .unresponsive:
                if Date() >= deadline {
                    qlog("LaunchdTmux: server still unresponsive after \(Int(stallWait))s — NOT starting a competing server (would hijack the socket); asking the user")
                    return .unresponsive
                }
                usleep(750_000)  // stalled, not gone — wait it out, never create
            }
        }
    }

    /// Write the transient LaunchAgent and bootstrap it, then wait (≤3s) for the
    /// launchd-spawned server to accept a query. Only called once the socket has been
    /// confirmed to have no server on it, so `new-session` here can't hijack a live one.
    private static func startViaLaunchd(controlSessionName: String) {
        guard writePlist(controlSessionName: controlSessionName) else {
            qlog("LaunchdTmux: failed to write plist; control client will start the server")
            return
        }
        let domain = "gui/\(getuid())"
        // Clear any stale (loaded-but-exited) job of the same label first — bootstrap
        // refuses a label that's already loaded. Ignore its status (usually "not found").
        _ = run("/bin/launchctl", ["bootout", "\(domain)/\(label)"], timeout: 5)
        let rc = run("/bin/launchctl", ["bootstrap", domain, plistPath], timeout: 5)
        qlog("LaunchdTmux: bootstrap \(label) rc=\(rc)")
        // Wait (≤3s) for the launchd-spawned server to come up.
        for _ in 0..<15 {
            if case .up = probeServer() {
                qlog("LaunchdTmux: launchd server is up (coalition-safe)")
                return
            }
            usleep(200_000)
        }
        qlog("LaunchdTmux: server did not come up in time; control client will proceed")
    }

    // MARK: - Internals

    private static var plistPath: String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("\(label).plist")
    }

    /// What a quick `tmux ls` says about the default-socket server.
    private enum ServerState {
        case up            // answered, exit 0 — a server is running
        case absent        // answered fast with non-zero — no server on this socket
        case unresponsive  // didn't answer in time — a server is likely alive but wedged
    }

    /// Probe the default socket, distinguishing a *wedged* server (the query times
    /// out) from a genuinely *absent* one (`tmux ls` fails fast with "no server
    /// running on …"). Only absence is safe to start a new server on — starting one
    /// against a wedged server is what unlinks the live socket and splits sessions.
    private static func probeServer() -> ServerState {
        switch runOutcome(Tmux.executablePath, ["ls"], timeout: 3) {
        case .exited(0): return .up
        case .exited: return .absent
        case .timedOut: return .unresponsive
        case .spawnFailed: return .unresponsive  // couldn't even ask; err toward not creating
        }
    }

    private static func writePlist(controlSessionName: String) -> Bool {
        // launchd GUI jobs start with a minimal environment; give tmux a sane PATH and,
        // critically, propagate TMUX_TMPDIR so the launchd server and Belfry's control
        // client share the *same* socket (matters for isolated test instances; for the
        // real app both fall through to the default /tmp/tmux-$UID/default).
        var env = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"]
        if let tmpdir = ProcessInfo.processInfo.environment["TMUX_TMPDIR"] {
            env["TMUX_TMPDIR"] = tmpdir
        }
        let plist: [String: Any] = [
            "Label": label,
            // Create the control session detached; the client exits, the daemonized
            // server (now in launchd's coalition) keeps running with that session.
            "ProgramArguments": [
                Tmux.executablePath, "new-session", "-A", "-d", "-s", controlSessionName,
            ],
            // launchd GUI jobs default their cwd to "/"; without this the tmux server
            // (and every session/window that doesn't pass its own -c) would start in "/"
            // instead of the user's home. Mirrors the non-launchd path in TmuxTransport.
            "WorkingDirectory": NSHomeDirectory(),
            "RunAtLoad": true,
            "EnvironmentVariables": env,
        ]
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        ) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: plistPath))) != nil
    }

    // `internal` (not `private`) so a unit test can exercise the exit-vs-timeout
    // distinction directly — that split is the whole fix, so it's worth pinning.
    enum RunOutcome: Equatable { case exited(Int32); case timedOut; case spawnFailed }

    /// Run `path args…`, bounded by `timeout`. Distinguishes a clean exit (with its
    /// status) from a timeout and from a spawn failure — the timeout case is what lets
    /// `probeServer` tell a wedged server apart from a gone one.
    static func runOutcome(_ path: String, _ args: [String], timeout: TimeInterval) -> RunOutcome {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return .spawnFailed }
        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning && Date() < deadline { usleep(50_000) }
        if proc.isRunning { proc.terminate(); return .timedOut }
        return .exited(proc.terminationStatus)
    }

    /// Status-only convenience over `runOutcome` (timeout/spawn-failure collapse to -1),
    /// used for the launchctl calls where the distinction doesn't matter.
    @discardableResult
    private static func run(_ path: String, _ args: [String], timeout: TimeInterval) -> Int32 {
        switch runOutcome(path, args, timeout: timeout) {
        case .exited(let s): return s
        case .timedOut, .spawnFailed: return -1
        }
    }
}
