import Foundation
import Termini

/// Resolves the tmux binary once.
enum Tmux {
    static let executablePath: String = {
        let candidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? "/opt/homebrew/bin/tmux"
    }()
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
