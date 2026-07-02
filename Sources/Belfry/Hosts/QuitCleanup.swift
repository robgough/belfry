import Foundation

/// Best-effort cleanup of server-side state we created, run synchronously at app
/// quit. Kills this instance's hidden control session on each host (so it doesn't
/// accumulate), then closes shared SSH masters. The user's *real* sessions are
/// intentionally left running. If a hard kill skips this, the next launch reaps
/// the orphan (liveness-gated) instead.
enum QuitCleanup {
    /// One host to clean: its transport and *its own* control-session name.
    struct Target {
        let transport: TmuxTransport
        let controlSession: String
    }

    /// Kill each host's control session and close SSH masters. Runs each command
    /// with a short timeout and bounds total wall time so quit stays snappy even
    /// if a host is unreachable.
    static func run(targets: [Target]) {
        let group = DispatchGroup()
        for target in targets {
            group.enter()
            DispatchQueue.global().async {
                cleanup(target)
                group.leave()
            }
        }
        // Keep this well under the app's quit watchdog so cleanup normally finishes
        // before the hard force-exit, but never let a slow/unreachable host stall
        // the quit. Orphaned control sessions are reaped on the next launch.
        _ = group.wait(timeout: .now() + 1.5)
    }

    private static func cleanup(_ target: Target) {
        let session = target.controlSession
        switch target.transport {
        case .local:
            run(Tmux.executablePath,
                ["kill-session", "-t", session],
                timeout: 2.0)
        case .ssh(let alias):
            run("/usr/bin/ssh",
                SSHControl.options + [alias, RemoteTmux.command(argv: ["kill-session", "-t", session])],
                timeout: 2.5)
            // Close the multiplexed master connection.
            run("/usr/bin/ssh", SSHControl.options + ["-O", "exit", alias], timeout: 1.5)
        }
    }

    private static func run(_ launchPath: String, _ args: [String], timeout: TimeInterval) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        // Process inherits the parent environment by default (PATH etc.).
        do {
            try proc.run()
        } catch {
            return
        }
        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if proc.isRunning { proc.terminate() }
    }
}
