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
    static func ensureLocalServer(controlSessionName: String) {
        if serverRunning() {
            qlog("LaunchdTmux: local server already running; attaching (no launchd start)")
            return
        }
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
            if serverRunning() {
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

    /// `tmux ls` exits 0 iff a server is running on the (TMUX_TMPDIR-derived) default socket.
    private static func serverRunning() -> Bool {
        run(Tmux.executablePath, ["ls"], timeout: 3) == 0
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
            "RunAtLoad": true,
            "EnvironmentVariables": env,
        ]
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        ) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: plistPath))) != nil
    }

    /// Run `path args…`, wait (bounded) for exit, return its status (-1 on spawn failure or
    /// timeout). Mirrors QuitCleanup.run but surfaces the exit code.
    @discardableResult
    private static func run(_ path: String, _ args: [String], timeout: TimeInterval) -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return -1 }
        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning && Date() < deadline { usleep(50_000) }
        if proc.isRunning { proc.terminate(); return -1 }
        return proc.terminationStatus
    }
}
