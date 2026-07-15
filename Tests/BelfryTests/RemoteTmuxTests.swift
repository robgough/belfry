import Foundation
import Testing
@testable import Belfry

/// `RemoteTmux.prelude` is the shell that runs on the far side of ssh before tmux
/// is exec'd. Its job is to hand the server an environment equivalent to the one
/// you'd get by typing `ssh host` and running tmux yourself — above all a PATH in
/// which a bare `tmux` resolves, because the server passes this environment to
/// every `run-shell`, and that's how tmux.conf's plugin lines (TPM, catppuccin)
/// execute. Under sshd's default PATH they'd fail with "command not found" and
/// the config would load its options but none of its plugin UI.
///
/// These run the real fragment under a simulated sshd environment: a fake login
/// shell we control, and a fake `tmux` on disk, so nothing depends on the host's
/// dotfiles or where tmux happens to be installed.
struct RemoteTmuxPreludeTests {
    /// Runs `prelude; echo "$PATH"` under `env -i` with the given SHELL/PATH,
    /// returning the PATH the prelude built for the tmux server.
    private func resolvedPath(shell: String, incomingPath: String) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = [
            "-i", "HOME=\(NSTemporaryDirectory())", "SHELL=\(shell)", "PATH=\(incomingPath)",
            "/bin/sh", "-c", RemoteTmux.prelude + "echo \"$PATH\"",
        ]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A directory containing an executable named `tmux`, so `command -v tmux`
    /// resolves without depending on a real install.
    private func makeFakeTmuxDir(_ name: String) throws -> String {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("belfry-\(name)")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let tmux = (dir as NSString).appendingPathComponent("tmux")
        try "#!/bin/sh\nexit 0\n".write(toFile: tmux, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmux)
        return dir
    }

    /// A stand-in login shell: ignores `-lc` and prints `body` on stdout.
    private func makeFakeShell(_ name: String, body: String) throws -> String {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("belfry-\(name).sh")
        try "#!/bin/sh\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    @Test func adoptsTheLoginShellPath() throws {
        // The whole point: a Homebrew-style dir that only the *login* shell knows
        // about must end up on the server's PATH.
        let tmuxDir = try makeFakeTmuxDir("adopt-tmux")
        let loginOnly = try makeFakeTmuxDir("adopt-loginonly")
        let shell = try makeFakeShell(
            "adopt", body: "printf '\\n__belfry_path__%s\\n' '\(loginOnly):\(tmuxDir):/usr/bin:/bin'")

        let path = try resolvedPath(shell: shell, incomingPath: "\(tmuxDir):/usr/bin:/bin")

        // The login-only dir is present — that's the parity we were missing.
        #expect(path.contains(loginOnly))
        // And $TB's own directory leads, so a plugin's bare `tmux` is the server's binary.
        #expect(path.hasPrefix("\(tmuxDir):"))
    }

    @Test func bareTmuxResolvesInTheResultingPath() throws {
        // The failure this whole change exists to prevent: TPM/catppuccin shell
        // out to a bare `tmux`, so it must resolve in the PATH we hand the server.
        let tmuxDir = try makeFakeTmuxDir("resolve-tmux")
        let shell = try makeFakeShell(
            "resolve", body: "printf '\\n__belfry_path__%s\\n' '/usr/bin:/bin'")

        let path = try resolvedPath(shell: shell, incomingPath: "\(tmuxDir):/usr/bin:/bin")
        let found = path.split(separator: ":").contains {
            FileManager.default.isExecutableFile(atPath: "\($0)/tmux")
        }
        #expect(found, "a bare `tmux` must resolve for run-shell plugins to work")
    }

    @Test func chattyProfileCannotCorruptThePath() throws {
        // Login profiles print banners, version managers, motd… The marker exists
        // so that noise can't end up spliced into PATH.
        let tmuxDir = try makeFakeTmuxDir("chatty-tmux")
        let shell = try makeFakeShell("chatty", body: """
            echo 'Welcome to the machine'
            echo 'nvm: loaded'
            printf '\\n__belfry_path__%s\\n' '\(tmuxDir):/usr/bin:/bin'
            """)

        let path = try resolvedPath(shell: shell, incomingPath: "\(tmuxDir):/usr/bin:/bin")

        #expect(!path.contains("Welcome"))
        #expect(!path.contains("nvm"))
        #expect(path.hasPrefix("\(tmuxDir):"))
    }

    @Test func rejectsAPathThatIsNotColonSeparated() throws {
        // fish joins $PATH (a list) with spaces, so the captured value is junk.
        // It must be rejected rather than exported, and tmux must still resolve.
        let tmuxDir = try makeFakeTmuxDir("fishy-tmux")
        let shell = try makeFakeShell(
            "fishy", body: "printf '\\n__belfry_path__%s\\n' '/opt/homebrew/bin /usr/bin /bin'")

        let path = try resolvedPath(shell: shell, incomingPath: "\(tmuxDir):/usr/bin:/bin")

        #expect(!path.contains("/opt/homebrew/bin /usr/bin"), "space-joined value must not be adopted")
        #expect(path.hasPrefix("\(tmuxDir):"), "fallback must still make the server's tmux reachable")
    }

    @Test func survivesALoginShellThatFailsEntirely() throws {
        // A shell that errors out (or has no profile) must not break the connect:
        // fall back to making $TB reachable.
        let tmuxDir = try makeFakeTmuxDir("broken-tmux")
        let shell = try makeFakeShell("broken", body: "echo 'boom' >&2; exit 1")

        let path = try resolvedPath(shell: shell, incomingPath: "\(tmuxDir):/usr/bin:/bin")

        #expect(path.hasPrefix("\(tmuxDir):"))
        #expect(!path.contains("boom"))
    }
}
