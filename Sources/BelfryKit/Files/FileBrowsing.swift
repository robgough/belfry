import Foundation

/// One entry in a directory listing on some host (local or remote).
struct FileEntry: Identifiable, Hashable, Sendable {
    let name: String
    /// Absolute path on the host the entry lives on.
    let path: String
    /// Whether navigation should descend into it (follows symlinks, so a link
    /// to a directory browses like a directory).
    let isDirectory: Bool
    /// Whether the entry itself is a symlink (drives the badge; independent of
    /// `isDirectory`, which reports the link *target*).
    let isSymlink: Bool
    /// lstat size in bytes. Not meaningful for directories.
    let size: Int64
    let modified: Date
    var id: String { path }
}

/// A directory listing plus the resolved absolute path it came from — the
/// input path may be "~" or relative-ish, and only the host can resolve it,
/// so resolution rides along rather than costing a second round trip.
struct DirectoryListing: Sendable {
    let directory: String
    let entries: [FileEntry]
}

enum FileBrowsingError: LocalizedError, Equatable {
    case notFound(String)
    case permissionDenied(String)
    case remoteFailed(status: Int32?, detail: String)
    case listingTooLarge(String)
    case corrupt(String)
    case incomplete(expected: Int64, got: Int64)

    var errorDescription: String? {
        switch self {
        case .notFound(let path):
            return "“\(abbreviated(path))” doesn't exist on this host."
        case .permissionDenied(let path):
            return "No permission to access “\(abbreviated(path))”."
        case .remoteFailed(_, let detail):
            return detail.isEmpty ? "The operation failed on the host." : detail
        case .listingTooLarge(let path):
            return "“\(abbreviated(path))” has too many entries to list."
        case .corrupt(let what):
            return "Unreadable reply from the host (\(what))."
        case .incomplete(let expected, let got):
            return "Transfer ended early (\(got) of \(expected) bytes)."
        }
    }

    private func abbreviated(_ path: String) -> String {
        path.count > 60 ? "…" + path.suffix(57) : path
    }
}

/// Byte-progress callback: (bytes done so far, total when known). For resumed
/// downloads "done" includes the offset, so the fraction is of the whole file.
typealias TransferProgress = @Sendable (Int64, Int64?) -> Void

/// One host's file operations, behind which local-vs-remote (and macOS-vs-iOS
/// remote plumbing) disappears. All methods are safe to call from any task;
/// cancellation is structured — cancel the calling task and the underlying
/// channel/subprocess is torn down.
protocol FileBrowsing: Sendable {
    /// True when paths are on this machine (enables Open / Reveal in Finder).
    var isLocal: Bool { get }

    /// List `directory` ("" or "~" means the remote $HOME). Entries come back
    /// sorted: directories first, then localized name order.
    func list(directory: String) async throws -> DirectoryListing

    /// Stream the file into `localURL` (written via a `.part` sibling, renamed
    /// into place on success — a torn download never masquerades as the file).
    /// `offset` skips already-transferred bytes; v1 callers always pass 0, but
    /// the wire command is resume-shaped so resuming later costs nothing.
    func download(_ entry: FileEntry, to localURL: URL, offset: Int64,
                  progress: @escaping TransferProgress) async throws

    /// Stream a local file into `directory` on the host, keeping its filename
    /// (an existing file with that name is replaced). Returns the final
    /// absolute remote path.
    func upload(localURL: URL, toDirectory directory: String,
                progress: @escaping TransferProgress) async throws -> String

    /// Git awareness (see GitSupport.swift). nil when the directory isn't in
    /// a repo, or the host has no git — never an error for "not applicable".
    func gitOverview(directory: String) async throws -> GitOverview?
    /// Unified diff vs HEAD for one repo-relative path (whole repo when nil).
    func gitDiff(root: String, path: String?) async throws -> String
}

// MARK: - Remote script seam

/// The one platform-specific piece of remote browsing: run a shell script on
/// the host with streaming stdio. macOS backs this with an `ssh` subprocess
/// over the shared ControlMaster socket; iOS with an extra exec channel on the
/// host's NIOSSH connection.
protocol RemoteScriptRunning: Sendable {
    func run(script: String) async throws -> any RemoteScriptProcess
}

/// A running remote script. `stdout` is single-consumer: iterate it exactly
/// once. `write` applies backpressure by awaiting the underlying flush.
protocol RemoteScriptProcess: Sendable {
    var stdout: AsyncThrowingStream<Data, Error> { get }
    func write(_ data: Data) async throws
    /// Half-close stdin (EOF) so a remote `cat > file` completes.
    func finishInput() async throws
    /// Hard-stop the script. Idempotent.
    func cancel()
    /// Wait for completion. nil when the exit status is unknowable (signal).
    func exitStatus() async throws -> Int32?
    /// Trailing stderr for diagnostics; meaningful after exit.
    func stderrTail() async -> String
}

// MARK: - Remote implementation (shared scripts + parser)

/// `FileBrowsing` over any `RemoteScriptRunning`. The scripts speak plain
/// POSIX sh and probe the stat dialect (GNU vs BSD) at runtime, so the same
/// bytes work against Linux and macOS hosts from either platform.
struct RemoteFileBrowser: FileBrowsing {
    let runner: any RemoteScriptRunning
    var isLocal: Bool { false }

    /// Errors deliberately produced by our scripts ride stderr as sentinels so
    /// they survive the exit-status-only channel with their meaning intact.
    private static let notFoundSentinel = "BELFRY:ENOENT"
    private static let permissionSentinel = "BELFRY:EACCES"

    /// The remote side runs commands through the user's *login* shell — zsh
    /// aborts scripts on unmatched globs ("no matches found: ..?*"), fish
    /// can't parse them at all. Re-exec under POSIX sh so the scripts mean
    /// the same thing everywhere.
    private func run(_ script: String) async throws -> any RemoteScriptProcess {
        try await runner.run(script: "exec sh -c " + RemoteTmux.quoted(script))
    }

    // MARK: Listing

    func list(directory: String) async throws -> DirectoryListing {
        // Wire format, one NUL-terminated record per entry with the name LAST
        // (`type:size:mtime \t isDir \t name NUL`): filenames containing
        // newlines or tabs can't corrupt the framing, which is why `ls -la`
        // (locale-dependent, column-ambiguous) is not used. The first record
        // is the resolved directory itself.
        let script =
            "cd -- \(Self.shellPath(directory)) 2>/dev/null || { echo '\(Self.notFoundSentinel)' >&2; exit 2; }; "
            + "printf '%s\\0' \"$PWD\"; "
            + "if stat -c %s . >/dev/null 2>&1; then g=1; else g=; fi; "
            + "for f in * .[!.]* ..?*; do "
            + "[ -e \"$f\" ] || [ -h \"$f\" ] || continue; "
            + "if [ -n \"$g\" ]; then m=$(stat -c '%F:%s:%Y' -- \"$f\" 2>/dev/null); "
            + "else m=$(stat -f '%HT:%z:%m' -- \"$f\" 2>/dev/null); fi; "
            + "[ -n \"$m\" ] || continue; "
            + "if [ -d \"$f\" ]; then dd=1; else dd=0; fi; "
            + "printf '%s\\t%s\\t%s\\0' \"$m\" \"$dd\" \"$f\"; "
            + "done"
        let result = try await runCollecting(script, context: directory,
                                             limit: 16 << 20,
                                             overflow: .listingTooLarge(directory))
        return try Self.parseListing(result)
    }

    /// Parse the NUL-framed listing produced by the script above. Internal
    /// (not private) so tests can feed it synthetic GNU/BSD records.
    static func parseListing(_ data: Data) throws -> DirectoryListing {
        var records = data.split(separator: 0)
        guard !records.isEmpty else { throw FileBrowsingError.corrupt("empty listing") }
        let directory = String(decoding: records.removeFirst(), as: UTF8.self)
        var entries: [FileEntry] = []
        for record in records {
            let text = String(decoding: record, as: UTF8.self)
            // Name is everything after the second tab — tabs *in* the name survive.
            let fields = text.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { throw FileBrowsingError.corrupt("listing record") }
            // meta is type:size:mtime, parsed right-to-left because the type
            // ("symbolic link", "Regular File", …) contains no colons but is
            // the only free-text field.
            let meta = fields[0].split(separator: ":", omittingEmptySubsequences: false)
            guard meta.count >= 3,
                  let size = Int64(meta[meta.count - 2]),
                  let mtime = TimeInterval(meta[meta.count - 1])
            else { throw FileBrowsingError.corrupt("stat fields") }
            let type = meta.dropLast(2).joined(separator: ":").lowercased()
            let name = String(fields[2])
            entries.append(FileEntry(
                name: name,
                path: directory == "/" ? "/" + name : directory + "/" + name,
                isDirectory: fields[1] == "1",
                isSymlink: type.contains("symbolic link"),
                size: size,
                modified: Date(timeIntervalSince1970: mtime)))
        }
        return DirectoryListing(directory: directory, entries: Self.sorted(entries))
    }

    static func sorted(_ entries: [FileEntry]) -> [FileEntry] {
        entries.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    // MARK: Download

    func download(_ entry: FileEntry, to localURL: URL, offset: Int64,
                  progress: @escaping TransferProgress) async throws {
        // Size rides ahead of the bytes as one newline-terminated line (the
        // progress denominator isn't trusted from the possibly-stale listing).
        // `tail -c +N < file` instead of `cat` purely so a future resume is a
        // parameter change, not a protocol change.
        let script =
            "f=\(RemoteTmux.quoted(entry.path)); "
            + "[ -e \"$f\" ] || [ -h \"$f\" ] || { echo '\(Self.notFoundSentinel)' >&2; exit 2; }; "
            + "[ -r \"$f\" ] || { echo '\(Self.permissionSentinel)' >&2; exit 3; }; "
            + "sz=$(stat -c %s -- \"$f\" 2>/dev/null || stat -f %z -- \"$f\") || exit 4; "
            + "printf '%s\\n' \"$sz\"; "
            + "exec tail -c +\(offset + 1) < \"$f\""

        let process = try await run(script)
        try await withTaskCancellationHandler {
            let partURL = localURL.appendingPathExtension("part")
            FileManager.default.createFile(atPath: partURL.path, contents: nil)
            guard let handle = try? FileHandle(forWritingTo: partURL) else {
                process.cancel()
                throw FileBrowsingError.remoteFailed(status: nil, detail: "Couldn't create “\(partURL.lastPathComponent)”.")
            }
            var total: Int64?
            var written: Int64 = 0
            var sizeLine = Data()
            var sawSize = false
            do {
                for try await chunk in process.stdout {
                    var payload = Data(chunk)
                    if !sawSize {
                        if let newline = payload.firstIndex(of: 0x0A) {
                            sizeLine.append(payload[..<newline])
                            total = Int64(String(decoding: sizeLine, as: UTF8.self)
                                .trimmingCharacters(in: .whitespaces))
                            sawSize = true
                            payload = Data(payload[(newline + 1)...])
                        } else {
                            sizeLine.append(payload)
                            continue
                        }
                    }
                    guard !payload.isEmpty else { continue }
                    try handle.write(contentsOf: payload)
                    written += Int64(payload.count)
                    progress(offset + written, total)
                }
            } catch {
                try? handle.close()
                throw error
            }
            try handle.close()
            let status = try await process.exitStatus()
            guard status == 0 else {
                throw await Self.failure(status: status, process: process, path: entry.path)
            }
            if let total, offset + written != total {
                throw FileBrowsingError.incomplete(expected: total, got: offset + written)
            }
            try? FileManager.default.removeItem(at: localURL)
            try FileManager.default.moveItem(at: partURL, to: localURL)
            progress(offset + written, total ?? (offset + written))
        } onCancel: {
            process.cancel()
        }
    }

    // MARK: Upload

    func upload(localURL: URL, toDirectory directory: String,
                progress: @escaping TransferProgress) async throws -> String {
        let name = localURL.lastPathComponent
        let quotedPart = RemoteTmux.quoted(name + ".part")
        let quotedName = RemoteTmux.quoted(name)
        // Stream into `name.part`, rename on success — a dropped connection
        // never leaves a truncated file wearing the real name. The remote
        // prints the final absolute path back ($HOME isn't known client-side).
        let script =
            "d=\(Self.shellPath(directory)); mkdir -p -- \"$d\" 2>/dev/null; "
            + "cd -- \"$d\" 2>/dev/null || { echo '\(Self.permissionSentinel)' >&2; exit 3; }; "
            + "cat > \(quotedPart) && mv -f -- \(quotedPart) \(quotedName) "
            + "&& printf '%s/%s' \"$PWD\" \(quotedName)"

        guard let input = try? FileHandle(forReadingFrom: localURL) else {
            throw FileBrowsingError.notFound(localURL.path)
        }
        defer { try? input.close() }
        let total = (try? localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .map(Int64.init)

        let process = try await run(script)
        return try await withTaskCancellationHandler {
            // Drain stdout concurrently (it only ever carries the final path,
            // but draining while writing means no pipe can deadlock on us).
            let collector = Task<Data, Error> {
                var collected = Data()
                for try await chunk in process.stdout { collected.append(chunk) }
                return collected
            }
            var sent: Int64 = 0
            while let chunk = try input.read(upToCount: 128 << 10), !chunk.isEmpty {
                try await process.write(chunk)
                sent += Int64(chunk.count)
                progress(sent, total)
            }
            try await process.finishInput()
            let status = try await process.exitStatus()
            let remotePath = String(decoding: (try? await collector.value) ?? Data(), as: UTF8.self)
            guard status == 0, !remotePath.isEmpty else {
                collector.cancel()
                throw await Self.failure(status: status, process: process, path: directory)
            }
            progress(sent, total ?? sent)
            return remotePath
        } onCancel: {
            process.cancel()
        }
    }

    // MARK: Helpers

    /// A shell word for a user-facing path: "~"-forms expand against the
    /// *remote* $HOME; everything else is quoted literally.
    static func shellPath(_ path: String) -> String {
        if path.isEmpty || path == "~" { return "\"$HOME\"" }
        if path.hasPrefix("~/") {
            return "\"$HOME\"/" + RemoteTmux.quoted(String(path.dropFirst(2)))
        }
        return RemoteTmux.quoted(path)
    }

    /// Small-output run for the git layer (GitSupport.swift) — same semantics
    /// as `runCollecting`, internal so the extension there can reach it.
    func runCollectingForGit(_ script: String, context: String) async throws -> Data {
        try await runCollecting(script, context: context, limit: 4 << 20,
                                overflow: .remoteFailed(status: nil, detail: "git output too large"))
    }

    /// Run a script whose stdout is small and wanted whole (listings).
    private func runCollecting(_ script: String, context: String, limit: Int,
                               overflow: FileBrowsingError) async throws -> Data {
        let process = try await run(script)
        return try await withTaskCancellationHandler {
            var collected = Data()
            for try await chunk in process.stdout {
                collected.append(chunk)
                guard collected.count <= limit else {
                    process.cancel()
                    throw overflow
                }
            }
            let status = try await process.exitStatus()
            guard status == 0 else {
                throw await Self.failure(status: status, process: process, path: context)
            }
            return collected
        } onCancel: {
            process.cancel()
        }
    }

    /// Map a failed script to a friendly error via the stderr sentinels.
    private static func failure(status: Int32?, process: any RemoteScriptProcess,
                                path: String) async -> FileBrowsingError {
        let stderr = await process.stderrTail()
        if stderr.contains(notFoundSentinel) { return .notFound(path) }
        if stderr.contains(permissionSentinel) { return .permissionDenied(path) }
        let detail = stderr.split(separator: "\n").last.map(String.init) ?? ""
        return .remoteFailed(status: status, detail: detail)
    }
}
