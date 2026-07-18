import Foundation
import Testing
@testable import Belfry

/// The git layer is the same scripts-over-a-runner shape as the file
/// operations, so it gets the same treatment: parser units on synthetic
/// porcelain, plus a real `git init` round trip through /bin/sh.
struct GitOverviewParserTests {
    private func wire(root: String, records: [String]) -> Data {
        Data(root.utf8) + Data([0x0A])
            + records.map { Data($0.utf8) + Data([0]) }.reduce(Data(), +)
    }

    @Test func parsesBranchDivergenceAndEntries() throws {
        let data = wire(root: "/home/rob/code/bridge", records: [
            "## main...origin/main [ahead 2, behind 1]",
            " M lib/bridge/runner.ex",
            "A  docs/new.md",
            "?? scratch/",
            "D  old.txt",
        ])
        let overview = try GitScripts.parseOverview(data)
        #expect(overview.root == "/home/rob/code/bridge")
        #expect(overview.branch == "main")
        #expect(overview.ahead == 2)
        #expect(overview.behind == 1)
        #expect(overview.entries.count == 4)
        #expect(overview.entries[0].glyph == "M")
        #expect(overview.entries[1].glyph == "A")
        #expect(overview.entries[2].isUntracked)
        #expect(overview.entries[3].glyph == "D")
    }

    @Test func pairsRenameRecords() throws {
        let data = wire(root: "/r", records: [
            "## main",
            "R  new name.txt",
            "old name.txt",
            " M other.txt",
        ])
        let overview = try GitScripts.parseOverview(data)
        #expect(overview.entries.count == 2)
        #expect(overview.entries[0].glyph == "R")
        #expect(overview.entries[0].path == "new name.txt")
        #expect(overview.entries[0].renamedFrom == "old name.txt")
        #expect(overview.entries[1].path == "other.txt")
    }

    @Test func handlesFreshAndDetachedHeaders() throws {
        let fresh = try GitScripts.parseOverview(wire(root: "/r", records: [
            "## No commits yet on main",
            "?? a.txt",
        ]))
        #expect(fresh.branch == "main")
        #expect(fresh.entries.count == 1)

        let detached = try GitScripts.parseOverview(wire(root: "/r", records: [
            "## HEAD (no branch)",
        ]))
        #expect(detached.branch == "detached")
        #expect(detached.entries.isEmpty)
    }
}

struct SplitDiffTests {
    private let diff = """
    diff --git a/f.txt b/f.txt
    index 111..222 100644
    --- a/f.txt
    +++ b/f.txt
    @@ -1,4 +1,4 @@
     keep one
    -old two
    -old three
    +new two
     keep four
    @@ -10,2 +10,3 @@ section
     ctx
    +added tail
    """

    @Test func alignsRemovalsWithAdditions() {
        let rows = UnifiedDiff.splitRows(diff)
        // hunk, ctx, -/+ pair, -/nil pair, ctx, hunk, ctx, nil/+ pair
        #expect(rows.count == 8)
        guard case .hunk = rows[0] else { Issue.record("expected hunk header"); return }
        guard case .pair(let ctxL, let ctxR) = rows[1] else { Issue.record("expected pair"); return }
        #expect(ctxL?.text == "keep one" && ctxR?.text == "keep one")
        #expect(ctxL?.number == 1 && ctxR?.number == 1)
        guard case .pair(let removedA, let addedA) = rows[2] else { Issue.record("expected pair"); return }
        #expect(removedA?.text == "old two" && removedA?.kind == .removed)
        #expect(addedA?.text == "new two" && addedA?.kind == .added)
        guard case .pair(let removedB, let emptyB) = rows[3] else { Issue.record("expected pair"); return }
        #expect(removedB?.text == "old three")
        #expect(emptyB == nil)
        guard case .pair(let emptyC, let addedC) = rows[7] else { Issue.record("expected pair"); return }
        #expect(emptyC == nil)
        #expect(addedC?.text == "added tail" && addedC?.number == 11)
    }

    @Test func emptyDiffYieldsNoRows() {
        #expect(UnifiedDiff.splitRows("").isEmpty)
    }
}

struct GitScriptRoundTripTests {
    private let browser = RemoteFileBrowser(runner: SubprocessScriptRunner.localShell())

    /// A real repo with one commit, then a modification, an addition and an
    /// untracked file.
    private func makeRepo() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("belfry-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let git = { (args: String) throws in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.currentDirectoryURL = root
            process.arguments = ["-c", "git -c user.email=t@t -c user.name=T \(args)"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
        }
        try Data("one\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
        try git("init -q")
        try git("add -A")
        try git("commit -qm initial")
        try Data("one\ntwo\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
        try Data("new\n".utf8).write(to: root.appendingPathComponent("untracked file.txt"))
        return root
    }

    @Test func overviewSeesRealChanges() async throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }

        let overview = try await browser.gitOverview(directory: root.path)
        let git = try #require(overview)
        // /var/folders symlinks: compare canonical forms.
        #expect(URL(fileURLWithPath: git.root).resolvingSymlinksInPath().path
                == root.resolvingSymlinksInPath().path)
        #expect(!git.branch.isEmpty)
        let paths = Set(git.entries.map(\.path))
        #expect(paths == ["tracked.txt", "untracked file.txt"])
        let tracked = try #require(git.entries.first { $0.path == "tracked.txt" })
        #expect(tracked.glyph == "M")
    }

    @Test func diffShowsTheChange() async throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let git = try #require(try await browser.gitOverview(directory: root.path))

        let fileDiff = try await browser.gitDiff(root: git.root, path: "tracked.txt")
        #expect(fileDiff.contains("+two"))
        #expect(fileDiff.contains("tracked.txt"))

        let repoDiff = try await browser.gitDiff(root: git.root, path: nil)
        #expect(repoDiff.contains("+two"))
    }

    @Test func nonRepoAndPlainDirectoryReturnNil() async throws {
        let plain = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("belfry-plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: plain) }
        let overview = try await browser.gitOverview(directory: plain.path)
        #expect(overview == nil)
    }
}
