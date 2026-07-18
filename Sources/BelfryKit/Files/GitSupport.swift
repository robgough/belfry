import Foundation

/// Git awareness for the file pane: is this directory inside a repo, what's
/// changed, and what does a change look like. All of it is three small POSIX
/// scripts riding the same seam as the file operations, so it works
/// identically for the local Mac, ssh-subprocess remotes, and iOS exec
/// channels — and degrades to plain browsing wherever git is absent.

/// One repo's worth of "what's going on": branch, divergence, and the
/// working-tree changes.
struct GitOverview: Sendable, Equatable {
    /// Absolute repo root on the host.
    let root: String
    /// Branch name, or a short detached-HEAD description.
    let branch: String
    let ahead: Int
    let behind: Int
    let entries: [GitStatusEntry]
}

struct GitStatusEntry: Identifiable, Sendable, Hashable {
    /// The raw two-character porcelain XY code (e.g. " M", "??", "A ").
    let code: String
    /// Repo-relative path (the new name, for renames).
    let path: String
    /// Repo-relative original path when the entry is a rename/copy.
    let renamedFrom: String?

    var id: String { code + path }

    var isUntracked: Bool { code == "??" }

    /// Single display glyph, editor-style.
    var glyph: String {
        if isUntracked { return "?" }
        if code.contains("U") || code == "AA" || code == "DD" { return "!" }
        if code.contains("R") || code.contains("C") { return "R" }
        if code.contains("D") { return "D" }
        if code.contains("A") { return "A" }
        return "M"
    }
}

/// The scripts + parser, shared by every `FileBrowsing` implementation.
enum GitScripts {
    /// Exit codes the overview script uses to mean "cleanly not applicable".
    static let notARepoStatus: Int32 = 86
    static let noGitStatus: Int32 = 87

    /// Repo root on line 1, then `git status --porcelain -b -z` (NUL-framed,
    /// so hostile filenames survive; `-b` puts branch + divergence in the
    /// first record). git can be missing from a non-interactive shell's PATH
    /// even where it's installed (Homebrew on Mac remotes — the same trap
    /// RemoteTmux solves for tmux), so probe the usual fallback locations
    /// before giving up.
    static func overviewScript(directory: String) -> String {
        "cd -- \(RemoteFileBrowser.shellPath(directory)) 2>/dev/null || exit \(notARepoStatus); "
            + "G=$(command -v git || echo /opt/homebrew/bin/git); "
            + "[ -x \"$G\" ] || G=/usr/local/bin/git; "
            + "[ -x \"$G\" ] || exit \(noGitStatus); "
            + "t=$(\"$G\" rev-parse --show-toplevel 2>/dev/null) || exit \(notARepoStatus); "
            + "printf '%s\\n' \"$t\"; "
            + "\"$G\" status --porcelain -b -z 2>/dev/null"
    }

    /// Unified diff for one path (or the whole repo when nil), vs HEAD so
    /// staged and unstaged changes both show — that's the "what am I
    /// changing" answer. `--no-ext-diff` matters: a host whose gitconfig
    /// routes diffs through difftastic & co. would otherwise hand us
    /// unparseable side-by-side output. Fresh repos with no commits fall
    /// back to the index diff. Output capped host-side; the client caps again.
    static func diffScript(root: String, path: String?) -> String {
        let target = path.map { " -- \(RemoteTmux.quoted($0))" } ?? ""
        let flags = "--no-color --no-ext-diff"
        return "cd -- \(RemoteFileBrowser.shellPath(root)) 2>/dev/null || exit \(notARepoStatus); "
            + "G=$(command -v git || echo /opt/homebrew/bin/git); "
            + "[ -x \"$G\" ] || G=/usr/local/bin/git; "
            + "[ -x \"$G\" ] || exit \(noGitStatus); "
            + "{ \"$G\" diff HEAD \(flags)\(target) 2>/dev/null "
            + "|| \"$G\" diff \(flags)\(target); } | head -c 1048576"
    }

    /// Parse the overview script's output. Internal for tests.
    static func parseOverview(_ data: Data) throws -> GitOverview {
        guard let newline = data.firstIndex(of: 0x0A) else {
            throw FileBrowsingError.corrupt("git overview")
        }
        let root = String(decoding: data[..<newline], as: UTF8.self)
        guard !root.isEmpty else { throw FileBrowsingError.corrupt("git root") }

        var records = Array(data[(newline + 1)...]).split(separator: 0).makeIterator()
        var branch = ""
        var ahead = 0
        var behind = 0
        var entries: [GitStatusEntry] = []

        while let record = records.next() {
            let text = String(decoding: record, as: UTF8.self)
            if text.hasPrefix("## ") {
                (branch, ahead, behind) = parseBranchHeader(String(text.dropFirst(3)))
                continue
            }
            guard text.count >= 4 else { continue }
            let code = String(text.prefix(2))
            let path = String(text.dropFirst(3))
            // Renames/copies carry the original name as the *next* record.
            var renamedFrom: String?
            if code.contains("R") || code.contains("C"), let origin = records.next() {
                renamedFrom = String(decoding: origin, as: UTF8.self)
            }
            entries.append(GitStatusEntry(code: code, path: path, renamedFrom: renamedFrom))
        }
        return GitOverview(root: root, branch: branch, ahead: ahead, behind: behind,
                           entries: entries)
    }

    /// "main...origin/main [ahead 2, behind 1]" / "main" / "HEAD (no branch)"
    /// / "No commits yet on main".
    private static func parseBranchHeader(_ header: String) -> (String, Int, Int) {
        var name = header
        var ahead = 0
        var behind = 0
        if let bracket = name.range(of: " [") {
            let stats = name[bracket.upperBound...].dropLast(name.hasSuffix("]") ? 1 : 0)
            for part in stats.split(separator: ",") {
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("ahead "), let n = Int(trimmed.dropFirst(6)) { ahead = n }
                if trimmed.hasPrefix("behind "), let n = Int(trimmed.dropFirst(7)) { behind = n }
            }
            name = String(name[..<bracket.lowerBound])
        }
        if let dots = name.range(of: "...") {
            name = String(name[..<dots.lowerBound])
        }
        if name.hasPrefix("No commits yet on ") {
            name = String(name.dropFirst("No commits yet on ".count))
        }
        if name.hasPrefix("HEAD") { name = "detached" }
        return (name, ahead, behind)
    }
}

// MARK: - Split (side-by-side) diff

/// A unified diff re-aligned into before/after columns for the split view:
/// context lines pair with themselves, a run of removals pairs with the run
/// of additions that follows it, and the leftovers pair with empty cells.
enum UnifiedDiff {
    struct Cell: Sendable, Hashable {
        enum Kind: Sendable { case context, removed, added }
        let number: Int
        let text: String
        let kind: Kind
    }

    enum Row: Sendable, Hashable, Identifiable {
        case hunk(String)
        case pair(left: Cell?, right: Cell?)

        // Rows are only built once per parse; identity by position is fine.
        var id: Int {
            var hasher = Hasher()
            hasher.combine(self)
            return hasher.finalize()
        }
    }

    static func splitRows(_ diff: String) -> [Row] {
        var rows: [Row] = []
        var oldNumber = 0
        var newNumber = 0
        var pendingOld: [Cell] = []
        var pendingNew: [Cell] = []

        func flushPending() {
            for index in 0..<max(pendingOld.count, pendingNew.count) {
                rows.append(.pair(
                    left: index < pendingOld.count ? pendingOld[index] : nil,
                    right: index < pendingNew.count ? pendingNew[index] : nil))
            }
            pendingOld = []
            pendingNew = []
        }

        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@") {
                flushPending()
                // "@@ -12,7 +12,9 @@ optional section heading"
                let numbers = line.split(separator: " ")
                oldNumber = numbers.dropFirst().first
                    .flatMap { Int($0.dropFirst().prefix(while: { $0 != "," })) } ?? 0
                newNumber = numbers.dropFirst(2).first
                    .flatMap { Int($0.dropFirst().prefix(while: { $0 != "," })) } ?? 0
                rows.append(.hunk(String(line)))
            } else if line.hasPrefix("diff ") || line.hasPrefix("index ")
                || line.hasPrefix("--- ") || line.hasPrefix("+++ ")
                || line.hasPrefix("new file") || line.hasPrefix("deleted file")
                || line.hasPrefix("similarity") || line.hasPrefix("rename ")
                || line.hasPrefix("Binary files") || line.hasPrefix("\\") {
                flushPending()
            } else if line.hasPrefix("-") {
                pendingOld.append(Cell(number: oldNumber, text: String(line.dropFirst()), kind: .removed))
                oldNumber += 1
            } else if line.hasPrefix("+") {
                pendingNew.append(Cell(number: newNumber, text: String(line.dropFirst()), kind: .added))
                newNumber += 1
            } else {
                flushPending()
                // Context (leading space stripped); tolerate bare empty lines.
                let text = line.hasPrefix(" ") ? String(line.dropFirst()) : String(line)
                guard oldNumber > 0 || newNumber > 0 else { continue }
                rows.append(.pair(
                    left: Cell(number: oldNumber, text: text, kind: .context),
                    right: Cell(number: newNumber, text: text, kind: .context)))
                oldNumber += 1
                newNumber += 1
            }
        }
        flushPending()
        return rows
    }
}

extension FileBrowsing {
    /// Default: no git awareness (the stub/test browsers).
    func gitOverview(directory: String) async throws -> GitOverview? { nil }
    func gitDiff(root: String, path: String?) async throws -> String { "" }
}

extension RemoteFileBrowser {
    /// nil (not an error) when the directory isn't in a repo or the host has
    /// no git — the pane silently stays a plain file browser.
    func gitOverview(directory: String) async throws -> GitOverview? {
        do {
            let data = try await runCollectingForGit(
                GitScripts.overviewScript(directory: directory), context: directory)
            return try GitScripts.parseOverview(data)
        } catch FileBrowsingError.remoteFailed(let status, _)
            where status == GitScripts.notARepoStatus || status == GitScripts.noGitStatus {
            return nil
        }
    }

    func gitDiff(root: String, path: String?) async throws -> String {
        let data = try await runCollectingForGit(
            GitScripts.diffScript(root: root, path: path), context: root)
        return String(decoding: data, as: UTF8.self)
    }
}
