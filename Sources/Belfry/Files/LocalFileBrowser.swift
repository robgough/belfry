import Foundation

/// `FileBrowsing` for the local Mac: FileManager for listings, a chunked
/// read/write loop for copies (FileManager.copyItem has no progress, and a
/// multi-GB "download" from ~/Movies deserves a real gauge like any other).
struct LocalFileBrowser: FileBrowsing {
    var isLocal: Bool { true }

    func list(directory: String) async throws -> DirectoryListing {
        let path = ((directory.isEmpty ? "~" : directory) as NSString).expandingTildeInPath
        let directoryURL = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { throw FileBrowsingError.notFound(path) }

        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: directoryURL, includingPropertiesForKeys: keys, options: [])
        } catch {
            throw FileBrowsingError.permissionDenied(directoryURL.path)
        }
        let entries = urls.map { url -> FileEntry in
            let values = try? url.resourceValues(forKeys: Set(keys))
            // fileExists(isDirectory:) follows symlinks — matching the remote
            // scripts, so a link to a directory browses as a directory.
            var entryIsDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &entryIsDirectory)
            return FileEntry(
                name: url.lastPathComponent,
                path: directoryURL.appendingPathComponent(url.lastPathComponent).path,
                isDirectory: entryIsDirectory.boolValue,
                isSymlink: values?.isSymbolicLink ?? false,
                size: Int64(values?.fileSize ?? 0),
                modified: values?.contentModificationDate ?? .distantPast)
        }
        return DirectoryListing(directory: directoryURL.path,
                                entries: RemoteFileBrowser.sorted(entries))
    }

    func download(_ entry: FileEntry, to localURL: URL, offset: Int64,
                  progress: @escaping TransferProgress) async throws {
        try await Self.copy(from: URL(fileURLWithPath: entry.path), to: localURL,
                            progress: progress)
    }

    func upload(localURL: URL, toDirectory directory: String,
                progress: @escaping TransferProgress) async throws -> String {
        let path = ((directory.isEmpty ? "~" : directory) as NSString).expandingTildeInPath
        let destination = URL(fileURLWithPath: path)
            .appendingPathComponent(localURL.lastPathComponent)
        try await Self.copy(from: localURL, to: destination, progress: progress)
        return destination.path
    }

    // Git: the shared scripts, run against this Mac's own /bin/sh — exactly
    // what a remote gets, minus the ssh.
    private var gitDelegate: RemoteFileBrowser {
        RemoteFileBrowser(runner: SubprocessScriptRunner.localShell())
    }

    func gitOverview(directory: String) async throws -> GitOverview? {
        try await gitDelegate.gitOverview(directory: directory)
    }

    func gitDiff(root: String, path: String?) async throws -> String {
        try await gitDelegate.gitDiff(root: root, path: path)
    }

    /// Chunked copy off the cooperative pool (these block for as long as the
    /// bytes take), via a `.part` sibling renamed on success — same contract
    /// as the remote implementations.
    private static func copy(from source: URL, to destination: URL,
                             progress: @escaping TransferProgress) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        try copyBlocking(from: source, to: destination, progress: progress)
                    })
                }
            }
        } onCancel: {
            // The blocking loop polls Task.isCancelled per chunk; nothing to
            // tear down here.
        }
    }

    private static func copyBlocking(from source: URL, to destination: URL,
                                     progress: TransferProgress) throws {
        guard let input = try? FileHandle(forReadingFrom: source) else {
            throw FileBrowsingError.notFound(source.path)
        }
        defer { try? input.close() }
        let total = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)

        let partURL = destination.appendingPathExtension("part")
        FileManager.default.createFile(atPath: partURL.path, contents: nil)
        guard let output = try? FileHandle(forWritingTo: partURL) else {
            throw FileBrowsingError.permissionDenied(destination.deletingLastPathComponent().path)
        }
        var written: Int64 = 0
        do {
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                if Task.isCancelled { throw CancellationError() }
                try output.write(contentsOf: chunk)
                written += Int64(chunk.count)
                progress(written, total)
            }
            try output.close()
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(at: partURL)
            throw error
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partURL, to: destination)
        progress(written, total ?? written)
    }
}
