import Darwin  // proc_listpids / proc_pidpath — to match the running server's tmux
import Foundation
import Termini

/// Resolves the tmux binary Belfry should drive, once.
///
/// Control mode (`tmux -C`) is sensitive to the tmux *build*: a client whose
/// version differs from the tmux that owns the running server can still attach
/// (protocol 8 is shared across all 3.x), yet never complete the control-mode
/// handshake — so the sidebar hangs on "Connecting…" forever. This bit a host
/// whose sessions run under a Nix tmux 3.5a while Belfry reached for a Homebrew
/// tmux 3.7b (which our own cask dependency had installed and put first on the
/// search path).
///
/// So when a server is already running, drive it with *its own* binary: ask any
/// working tmux for the server pid and read that process's executable path. Any
/// tmux able to `list-sessions` will do as the prober — including one discovered
/// by scanning running processes, which recovers on hosts (Nix, custom prefixes)
/// where tmux lives nowhere we'd think to look. Only when no server is running
/// do we fall back to the well-known locations and let launchd start a fresh
/// one, whose client and server then match by construction.
enum Tmux {
    static let executablePath: String = resolve()

    /// Well-known install locations, in preference order. Used to start a fresh
    /// server and as prober candidates; the *running* server's own binary always
    /// wins over these when one exists.
    private static let knownPaths = [
        "/opt/homebrew/bin/tmux",  // Apple-silicon Homebrew
        "/usr/local/bin/tmux",     // Intel Homebrew
        "/opt/local/bin/tmux",     // MacPorts
        "/usr/bin/tmux",           // (macOS ships none, but cheap to check)
    ]

    private static func isExec(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    private static func resolve() -> String {
        // A tmux we can query the server with: a well-known one, or — when none
        // is installed where we look — any tmux that's currently running.
        let prober = knownPaths.first(where: isExec) ?? runningTmuxBinary()
        // Match the running server's own binary when there is a server.
        if let prober, let owner = serverBinary(askingWith: prober) { return owner }
        return prober ?? knownPaths[0]
    }

    /// Executable path of the tmux server on the default socket, or nil when no
    /// server is running. `prober` is any tmux able to talk to it.
    private static func serverBinary(askingWith prober: String) -> String? {
        // `list-sessions -F '#{pid}'` prints the server pid and succeeds against a
        // running server with no attached client; empty/failure ⇒ no server.
        guard let out = capture(prober, ["list-sessions", "-F", "#{pid}"], timeout: 3),
              let line = out.split(whereSeparator: \.isNewline).first,
              let pid = pid_t(line.trimmingCharacters(in: .whitespaces))
        else { return nil }
        // A long-lived server's on-disk binary may have been replaced by a package
        // upgrade — proc_pidpath then fails with ENOENT — so prefer the launch path
        // the kernel recorded (KERN_PROCARGS2), which is the tmux the server was
        // started from; fall back to proc_pidpath.
        for path in [processExecPath(pid), processPath(pid)] where path.map(isExec) == true {
            return path
        }
        return nil
    }

    /// The path a process was launched from, via KERN_PROCARGS2. Unlike
    /// proc_pidpath it survives the on-disk binary being unlinked out from under a
    /// running daemon. Nil if unavailable (e.g. another user's process).
    private static func processExecPath(_ pid: pid_t) -> String? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        // Layout: int argc; char exec_path[] (NUL-terminated); argv…
        return buf.withUnsafeBufferPointer { p -> String? in
            guard let base = p.baseAddress else { return nil }
            let start = UnsafeRawPointer(base).advanced(by: MemoryLayout<Int32>.size)
            let path = String(cString: start.assumingMemoryBound(to: CChar.self))
            return path.isEmpty ? nil : path
        }
    }

    /// Executable path of any currently-running tmux process (server or client),
    /// or nil. A running tmux is by definition compatible with its own server, so
    /// it makes a valid prober even when tmux isn't on any path we hardcode.
    private static func runningTmuxBinary() -> String? {
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard needed > 0 else { return nil }
        let capacity = Int(needed) / MemoryLayout<pid_t>.size + 16
        var pids = [pid_t](repeating: 0, count: capacity)
        let got = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids,
                                Int32(capacity * MemoryLayout<pid_t>.size))
        guard got > 0 else { return nil }
        let n = Int(got) / MemoryLayout<pid_t>.size
        for pid in pids.prefix(n) where pid > 0 {
            if let path = processPath(pid),
               (path as NSString).lastPathComponent == "tmux", isExec(path) {
                return path
            }
        }
        return nil
    }

    /// Absolute executable path of a pid via libproc, or nil.
    private static func processPath(_ pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN) is a function-like macro Swift
        // can't import, so spell the size out.
        var buf = [CChar](repeating: 0, count: 4 * 1024)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }

    /// Run `path args…`, return its stdout (bounded), or nil on spawn failure or
    /// timeout. Output is tiny (a pid line), so reading after exit can't deadlock.
    private static func capture(_ path: String, _ args: [String], timeout: TimeInterval) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning && Date() < deadline { usleep(50_000) }
        if proc.isRunning { proc.terminate(); return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}

/// How to reach a tmux server: locally, or over SSH to a host alias.
enum TmuxTransport: Hashable, Sendable {
    case local
    case ssh(alias: String)

    var isLocal: Bool {
        if case .local = self { return true }
        return false
    }

    var sshAlias: String? {
        if case .ssh(let alias) = self { return alias }
        return nil
    }

    /// A process spec that runs `tmux <args>` via this transport, inside a PTY.
    /// For SSH, `-t` forces a remote PTY (tmux control mode and attach both need
    /// one); our local side already runs in a forkpty, so ssh sees a tty.
    func tmuxProcessSpec(_ args: [String]) -> TerminiProcessSpec {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        switch self {
        case .local:
            return TerminiProcessSpec(
                executableURL: URL(fileURLWithPath: Tmux.executablePath),
                arguments: args,
                workingDirectoryURL: home
            )
        case .ssh(let alias):
            // The remote command goes through RemoteTmux: a bare `tmux` word
            // is invisible to the non-interactive remote shell's PATH when
            // tmux came from Homebrew (zsh:1: command not found: tmux).
            return TerminiProcessSpec(
                executableURL: URL(fileURLWithPath: "/usr/bin/ssh"),
                arguments: ["-t"] + SSHControl.options + [alias, RemoteTmux.command(argv: args)],
                environment: SSHControl.askpassEnvironment(),
                workingDirectoryURL: home
            )
        }
    }
}

/// Shared SSH connection-sharing configuration. The control plane and every
/// data-plane attach to a host reuse a single multiplexed connection (one auth,
/// fast subsequent attaches), and keepalives let us notice drops promptly.
enum SSHControl {
    /// Where the multiplexing sockets live. `%C` is a short stable hash of the
    /// connection (local host, remote host, port, user), so all links to a host
    /// share one socket.
    private static let controlPath = "~/.ssh/sockets/belfry-%C"

    static let options: [String] = [
        "-o", "ControlMaster=auto",
        "-o", "ControlPath=\(controlPath)",
        "-o", "ControlPersist=120",
        "-o", "ServerAliveInterval=20",
        "-o", "ServerAliveCountMax=3",
        // Ask about a brand-new host's key instead of silently trusting it
        // (was accept-new): the belfry-askpass helper renders ssh's yes/no
        // prompt — fingerprint included — as a dialog, so a first connect gets
        // a real decision rather than hanging headless. A *changed* key is
        // still refused outright.
        "-o", "StrictHostKeyChecking=ask",
    ]

    /// Create the sockets directory ssh needs (it won't create it itself).
    static func ensureSocketDir() {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh/sockets")
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    /// Close the shared SSH master for a host (`ssh -O exit`), so the next connect
    /// re-authenticates instead of silently reusing the cached connection — e.g.
    /// to let the user re-enter a mistyped password. Best-effort, off the main
    /// thread, bounded; `completion` runs on a background queue when done.
    static func closeMaster(alias: String, completion: @escaping () -> Void = {}) {
        DispatchQueue.global().async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            proc.arguments = options + ["-O", "exit", alias]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try? proc.run()
            let deadline = Date().addingTimeInterval(1.5)
            while proc.isRunning && Date() < deadline { usleep(50_000) }
            if proc.isRunning { proc.terminate() }
            completion()
        }
    }

    /// Point ssh at Belfry's GUI askpass helper so a password / passphrase prompt
    /// pops a native dialog instead of hanging the headless control connection.
    /// `force` makes ssh use it even though it's run under a PTY. Returns empty
    /// (ssh's default behaviour) if the helper can't be located.
    static func askpassEnvironment() -> [String: String] {
        guard let dir = Bundle.main.executableURL?.deletingLastPathComponent() else { return [:] }
        let helper = dir.appendingPathComponent("belfry-askpass")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { return [:] }
        return [
            "SSH_ASKPASS": helper.path,
            "SSH_ASKPASS_REQUIRE": "force",
        ]
    }
}
