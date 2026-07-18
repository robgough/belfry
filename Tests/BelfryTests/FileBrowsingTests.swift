import Foundation
import Testing
@testable import Belfry

/// The remote file-browsing scripts are plain POSIX sh, so they can be tested
/// for real without ssh: `SubprocessScriptRunner.localShell()` runs the exact
/// bytes a remote host would receive against this Mac's /bin/sh — which also
/// exercises the BSD branch of the stat-dialect probe. The parser tests feed
/// synthetic GNU records so the Linux branch's shape is covered too.
struct RemoteFileBrowserScriptTests {
    private let browser = RemoteFileBrowser(runner: SubprocessScriptRunner.localShell())

    /// A scratch directory populated with deliberately hostile names.
    private func makeFixture() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("belfry-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let write: (String, String) throws -> Void = { name, contents in
            try Data(contents.utf8).write(to: root.appendingPathComponent(name))
        }
        try write("plain.txt", "12345")
        try write("with space.txt", "x")
        try write("héllo😀.txt", "unicode")
        try write(".hidden", "shh")
        try write("tab\there.txt", "t")
        try write("nl\nline.txt", "n")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sub dir"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link"),
            withDestinationURL: root.appendingPathComponent("plain.txt"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("dirlink"),
            withDestinationURL: root.appendingPathComponent("sub dir"))
        return root
    }

    @Test func listingSurvivesHostileNames() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let listing = try await browser.list(directory: root.path)
        #expect(listing.directory == root.path)

        let byName = Dictionary(uniqueKeysWithValues: listing.entries.map { ($0.name, $0) })
        #expect(Set(byName.keys) == [
            "plain.txt", "with space.txt", "héllo😀.txt", ".hidden",
            "tab\there.txt", "nl\nline.txt", "sub dir", "link", "dirlink",
        ])
        #expect(byName["plain.txt"]?.size == 5)
        #expect(byName["plain.txt"]?.isDirectory == false)
        #expect(byName["sub dir"]?.isDirectory == true)
        #expect(byName["link"]?.isSymlink == true)
        #expect(byName["link"]?.isDirectory == false)
        // A link to a directory must browse as a directory but badge as a link.
        #expect(byName["dirlink"]?.isSymlink == true)
        #expect(byName["dirlink"]?.isDirectory == true)
        #expect(byName["plain.txt"]?.path == root.appendingPathComponent("plain.txt").path)
        // Directories sort first.
        let firstTwoAreDirectories = listing.entries.prefix(2).allSatisfy { $0.isDirectory }
        #expect(firstTwoAreDirectories)
        // Fresh fixture: mtimes are recent, not epoch garbage.
        let age = abs(byName["plain.txt"]!.modified.timeIntervalSinceNow)
        #expect(age < 120)
    }

    @Test func listingMissingDirectoryThrowsNotFound() async throws {
        await #expect(throws: FileBrowsingError.self) {
            _ = try await browser.list(directory: "/nonexistent-\(UUID().uuidString)")
        }
    }

    @Test func downloadRoundTrip() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data((0..<(2 << 20)).map { _ in UInt8.random(in: 0...255) })
        try payload.write(to: root.appendingPathComponent("blob.bin"))

        let listing = try await browser.list(directory: root.path)
        let entry = try #require(listing.entries.first { $0.name == "blob.bin" })
        #expect(entry.size == Int64(payload.count))

        let dest = root.appendingPathComponent("fetched.bin")
        let seen = LockedBox<(last: Int64, total: Int64?)>((0, nil))
        try await browser.download(entry, to: dest, offset: 0) { bytes, total in
            seen.value = (bytes, total)
        }
        #expect(try Data(contentsOf: dest) == payload)
        #expect(seen.value.total == Int64(payload.count))
        #expect(seen.value.last == Int64(payload.count))
        // No stray .part left behind.
        #expect(!FileManager.default.fileExists(atPath: dest.path + ".part"))
    }

    @Test func downloadHonoursOffset() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = FileEntry(name: "plain.txt", path: root.appendingPathComponent("plain.txt").path,
                              isDirectory: false, isSymlink: false, size: 5, modified: .now)
        let dest = root.appendingPathComponent("tail.txt")
        try await browser.download(entry, to: dest, offset: 2) { _, _ in }
        #expect(try String(contentsOf: dest, encoding: .utf8) == "345")
    }

    @Test func uploadRoundTripAndOverwrite() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data((0..<300_000).map { _ in UInt8.random(in: 0...255) })
        let source = root.appendingPathComponent("out going.bin")
        try payload.write(to: source)
        let destDir = root.appendingPathComponent("dest dir")

        let remotePath = try await browser.upload(
            localURL: source, toDirectory: destDir.path) { _, _ in }
        #expect(remotePath == destDir.appendingPathComponent("out going.bin").path)
        #expect(try Data(contentsOf: URL(fileURLWithPath: remotePath)) == payload)

        // Second upload with the same name replaces, not duplicates or errors.
        let second = try await browser.upload(
            localURL: source, toDirectory: destDir.path) { _, _ in }
        #expect(second == remotePath)
        let names = try FileManager.default.contentsOfDirectory(atPath: destDir.path)
        #expect(names == ["out going.bin"])
    }

    @Test func tildeExpandsToRemoteHome() async throws {
        let listing = try await browser.list(directory: "~")
        #expect(listing.directory == NSHomeDirectory())
    }

    /// ssh runs remote commands through the user's *login* shell. zsh aborts
    /// on unmatched globs, so the scripts re-exec themselves under POSIX sh —
    /// this proves that wrap by using zsh as the outer shell, as on any host
    /// whose login shell is zsh (regression: "no matches found: ..?*").
    @Test func scriptsSurviveAZshLoginShell() async throws {
        let zshBrowser = RemoteFileBrowser(
            runner: SubprocessScriptRunner(argv: ["/bin/zsh", "-c"], environment: nil))
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let listing = try await zshBrowser.list(directory: root.path)
        #expect(listing.entries.contains { $0.name == "plain.txt" })
        #expect(listing.entries.contains { $0.name == ".hidden" })
    }
}

struct ListingParserTests {
    private func record(_ meta: String, _ dir: String, _ name: String) -> Data {
        Data("\(meta)\t\(dir)\t\(name)".utf8) + Data([0])
    }

    @Test func parsesGNURecords() throws {
        var wire = Data("/home/rob".utf8) + Data([0])
        wire += record("regular file:1234:1700000000", "0", "notes.txt")
        wire += record("directory:4096:1700000001", "1", "src")
        wire += record("symbolic link:11:1700000002", "0", "cfg")
        let listing = try RemoteFileBrowser.parseListing(wire)
        #expect(listing.directory == "/home/rob")
        let byName = Dictionary(uniqueKeysWithValues: listing.entries.map { ($0.name, $0) })
        #expect(byName["notes.txt"]?.size == 1234)
        #expect(byName["notes.txt"]?.modified == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(byName["src"]?.isDirectory == true)
        #expect(byName["cfg"]?.isSymlink == true)
        #expect(byName["notes.txt"]?.path == "/home/rob/notes.txt")
    }

    @Test func parsesBSDRecordsAndHostileNames() throws {
        var wire = Data("/".utf8) + Data([0])
        wire += record("Regular File:7:1700000000", "0", "a\tb")     // tab in name
        wire += record("Symbolic Link:9:1700000000", "1", "x:y")     // colon in name
        wire += record("Directory:64:1700000000", "1", "new\nline")  // newline in name
        let listing = try RemoteFileBrowser.parseListing(wire)
        let names = Set(listing.entries.map(\.name))
        #expect(names == ["a\tb", "x:y", "new\nline"])
        let link = try #require(listing.entries.first { $0.name == "x:y" })
        #expect(link.isSymlink && link.isDirectory)
        // Root join must not produce "//x:y".
        #expect(link.path == "/x:y")
    }

    @Test func rejectsGarbage() {
        #expect(throws: FileBrowsingError.self) {
            _ = try RemoteFileBrowser.parseListing(
                Data("/d".utf8) + Data([0]) + Data("no tabs here".utf8) + Data([0]))
        }
    }

    @Test func shellPathForms() {
        #expect(RemoteFileBrowser.shellPath("") == "\"$HOME\"")
        #expect(RemoteFileBrowser.shellPath("~") == "\"$HOME\"")
        #expect(RemoteFileBrowser.shellPath("~/a b") == "\"$HOME\"/'a b'")
        #expect(RemoteFileBrowser.shellPath("/x's") == "'/x'\\''s'")
    }
}

struct LocalFileBrowserTests {
    @Test func listingMatchesFileManagerTruth() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("belfry-local-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("abc".utf8).write(to: root.appendingPathComponent("f.txt"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("d"), withIntermediateDirectories: true)

        let listing = try await LocalFileBrowser().list(directory: root.path)
        #expect(listing.entries.map(\.name) == ["d", "f.txt"])   // dirs first
        #expect(listing.entries[1].size == 3)
    }

    @Test func copyRoundTripWithProgress() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("belfry-local-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data((0..<(3 << 20)).map { _ in UInt8.random(in: 0...255) })
        try payload.write(to: root.appendingPathComponent("big.bin"))

        let browser = LocalFileBrowser()
        let dest = root.appendingPathComponent("copy.bin")
        let entry = FileEntry(name: "big.bin", path: root.appendingPathComponent("big.bin").path,
                              isDirectory: false, isSymlink: false,
                              size: Int64(payload.count), modified: .now)
        let last = LockedBox<Int64>(0)
        try await browser.download(entry, to: dest, offset: 0) { bytes, _ in last.value = bytes }
        #expect(try Data(contentsOf: dest) == payload)
        #expect(last.value == Int64(payload.count))
    }
}

/// Progress callbacks arrive off-actor; tests record them through a lock.
private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ initial: T) { stored = initial }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}

/// TransferCenter scheduling and state transitions, against a stub browser.
@MainActor
struct TransferCenterTests {
    private struct StubBrowser: FileBrowsing {
        var isLocal: Bool { false }
        var delayMs = 20
        var shouldFail = false

        func list(directory: String) async throws -> DirectoryListing {
            DirectoryListing(directory: directory, entries: [])
        }
        func download(_ entry: FileEntry, to localURL: URL, offset: Int64,
                      progress: @escaping TransferProgress) async throws {
            try await Task.sleep(for: .milliseconds(delayMs))
            if shouldFail { throw FileBrowsingError.remoteFailed(status: 1, detail: "boom") }
            progress(entry.size, entry.size)
        }
        func upload(localURL: URL, toDirectory directory: String,
                    progress: @escaping TransferProgress) async throws -> String {
            try await Task.sleep(for: .milliseconds(delayMs))
            return directory + "/" + localURL.lastPathComponent
        }
    }

    private func waitUntil(_ condition: @autoclosure () -> Bool) async {
        for _ in 0..<500 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private var entry: FileEntry {
        FileEntry(name: "f", path: "/r/f", isDirectory: false, isSymlink: false,
                  size: 10, modified: .now)
    }

    @Test func downloadRunsToFinished() async throws {
        let center = TransferCenter()
        let dest = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tc-\(UUID().uuidString)")
        let transfer = center.download(entry: entry, hostID: "h",
                                       browser: StubBrowser(), to: dest)
        #expect(!transfer.state.isTerminal)
        await waitUntil(transfer.state.isTerminal)
        #expect(transfer.state == .finished)
        #expect(!center.hasActive)
    }

    @Test func failureThenRetry() async throws {
        let center = TransferCenter()
        let dest = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tc-\(UUID().uuidString)")
        let transfer = center.download(entry: entry, hostID: "h",
                                       browser: StubBrowser(shouldFail: true), to: dest)
        await waitUntil(transfer.state.isTerminal)
        guard case .failed = transfer.state else {
            Issue.record("expected failure, got \(transfer.state)")
            return
        }
        // Retry re-queues and re-runs the same work (still failing here).
        center.retry(transfer)
        #expect(transfer.state == .queued || transfer.state == .running)
        await waitUntil(transfer.state.isTerminal)
        guard case .failed = transfer.state else {
            Issue.record("expected second failure, got \(transfer.state)")
            return
        }
    }

    @Test func perHostConcurrencyCap() async throws {
        let center = TransferCenter()
        let browser = StubBrowser(delayMs: 150)
        let transfers = (0..<5).map { index in
            center.download(entry: entry, hostID: "h", browser: browser,
                            to: URL(fileURLWithPath: NSTemporaryDirectory())
                                .appendingPathComponent("cap-\(index)-\(UUID().uuidString)"))
        }
        // Give the pump a beat: exactly 3 may run, 2 must still be queued.
        try await Task.sleep(for: .milliseconds(50))
        #expect(transfers.filter { $0.state == .running }.count == 3)
        #expect(transfers.filter { $0.state == .queued }.count == 2)
        await waitUntil(transfers.allSatisfy { $0.state.isTerminal })
        #expect(transfers.allSatisfy { $0.state == .finished })
    }

    @Test func cancelQueuedAndRunning() async throws {
        let center = TransferCenter()
        let browser = StubBrowser(delayMs: 500)
        let running = center.download(entry: entry, hostID: "h", browser: browser,
                                      to: URL(fileURLWithPath: NSTemporaryDirectory())
                                          .appendingPathComponent("c1-\(UUID().uuidString)"))
        await waitUntil(running.state == .running)
        center.cancel(running)
        await waitUntil(running.state.isTerminal)
        #expect(running.state == .cancelled)
    }
}
