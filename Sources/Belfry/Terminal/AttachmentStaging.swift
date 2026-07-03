import Foundation

/// Puts a file where the selected session's host can read it, and produces the
/// path to paste into the terminal. Claude Code (and most CLIs) take images and
/// documents as plain paths typed into the prompt, so "sending a file" is:
/// stage it on the host, then paste its escaped path.
///
/// - Local host: the file is already readable — its path is used as-is.
/// - SSH host: the bytes are streamed over the existing multiplexed connection
///   (`ssh <alias> 'cat > …'` reuses the ControlMaster socket, so no re-auth)
///   into `~/.cache/belfry/drops/` on the remote, and the remote path is used.
enum AttachmentStaging {
    enum StagingError: LocalizedError {
        case unreadable(String)
        case uploadFailed(name: String, detail: String)
        case timedOut(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name):
                return "Couldn't read “\(name)”."
            case .uploadFailed(let name, let detail):
                let suffix = detail.isEmpty ? "" : " — \(detail)"
                return "Upload of “\(name)” failed\(suffix)"
            case .timedOut(let name):
                return "Upload of “\(name)” timed out."
            }
        }
    }

    /// Stage one file for `transport`; returns the absolute path to paste.
    static func stage(fileURL: URL, transport: TmuxTransport) async throws -> String {
        switch transport {
        case .local:
            return fileURL.path
        case .ssh(let alias):
            return try await upload(fileURL, alias: alias)
        }
    }

    /// Escape a path for pasting into a shell-ish prompt the way terminals do
    /// on file drop: backslash before spaces/metacharacters. Claude Code
    /// understands these escapes, and a shell prompt gets a valid word too.
    static func shellEscaped(_ path: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in path.unicodeScalars {
            switch scalar {
            case let s where s.value < 0x20 || s.value == 0x7f:
                continue    // control characters can't be pasted meaningfully
            case let s where s.value > 0x7f || safeScalars.contains(s):
                out.append(scalar)
            default:
                out.append("\\")
                out.append(scalar)
            }
        }
        return String(out)
    }

    private static let safeScalars = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "._-/+"))

    // MARK: SSH upload

    private static func upload(_ fileURL: URL, alias: String) async throws -> String {
        let remoteName = Self.remoteName(for: fileURL.lastPathComponent)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    try runUpload(fileURL: fileURL, alias: alias, remoteName: remoteName)
                })
            }
        }
    }

    /// Blocking; runs on a background queue. Streams the file to the remote's
    /// drops directory and returns the resolved absolute remote path (printed
    /// by the remote shell, since $HOME isn't known client-side). Files older
    /// than a week are reaped on each upload so the directory self-cleans.
    private static func runUpload(fileURL: URL, alias: String, remoteName: String) throws -> String {
        guard let input = try? FileHandle(forReadingFrom: fileURL) else {
            throw StagingError.unreadable(fileURL.lastPathComponent)
        }
        // remoteName is sanitized to [A-Za-z0-9._-], safe inside double quotes.
        let script = "d=\"$HOME/.cache/belfry/drops\" && mkdir -p \"$d\" && "
            + "find \"$d\" -type f -mtime +7 -delete 2>/dev/null; "
            + "f=\"$d/\(remoteName)\" && cat > \"$f\" && printf %s \"$f\""

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = SSHControl.options + [alias, script]
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in SSHControl.askpassEnvironment() {
            environment[key] = value
        }
        process.environment = environment
        process.standardInput = input
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        // Watchdog: the master socket should make this instant, but a dead
        // connection must not hang the send forever.
        let timeout: TimeInterval = 120
        var timedOut = false
        let watchdog = DispatchWorkItem {
            if process.isRunning {
                timedOut = true
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        try? input.close()

        if timedOut {
            throw StagingError.timedOut(fileURL.lastPathComponent)
        }
        let remotePath = String(decoding: outData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, !remotePath.isEmpty else {
            let detail = String(decoding: errData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n").last.map(String.init) ?? ""
            throw StagingError.uploadFailed(name: fileURL.lastPathComponent, detail: detail)
        }
        return remotePath
    }

    /// Collision-proof remote filename: short unique prefix + the original name
    /// squeezed to characters that need no quoting anywhere.
    private static func remoteName(for original: String) -> String {
        let sanitized = String(original.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-"
                ? Character(scalar) : "_"
        })
        let trimmed = sanitized.isEmpty ? "file" : String(sanitized.suffix(80))
        return "\(UUID().uuidString.prefix(8).lowercased())-\(trimmed)"
    }
}
