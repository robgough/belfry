import Foundation

/// Detects and installs the hooks that drive Belfry's live agent status (see
/// docs/agent-status.md), for Claude Code, Codex, OpenCode, pi and oh-my-pi.
/// Works for the local machine and for SSH hosts; JSON merges happen here in
/// Swift, so a remote host needs nothing but `ssh` + a shell (no `jq`/`python`).
///
/// Every integration calls one shared script, `~/.belfry/bin/belfry-agent-hook`
/// (`AgentHookFiles`), which stamps tmux pane options the control connection
/// already watches. The per-harness pieces are thin:
/// - Claude Code: hook entries merged into `~/.claude/settings.json`.
/// - Codex: hook entries merged into `~/.codex/hooks.json` (same JSON shape).
/// - OpenCode: a plugin file in `~/.config/opencode/plugin/`.
/// - pi / oh-my-pi: an extension file in `~/.pi/agent/extensions/` /
///   `~/.omp/agent/extensions/`.
/// Harnesses other than Claude are only touched when their config directory
/// already exists on the host (i.e. the tool is actually installed).
///
/// JSON entries are tagged with a marker so we can detect them and reinstall
/// idempotently without disturbing the user's other settings or hooks; each
/// JSON file is backed up to `<file>.belfry-bak` before it's rewritten.
enum AgentHooks {
    static let marker = "belfry-status"

    /// Bumped whenever the hook script or any hook command changes. Claude
    /// commands and the script header carry `belfry-status-v<N>`; `check()`
    /// reports an older (or bare) marker as installed-but-outdated, and
    /// `HostModel` silently reinstalls to roll the change out.
    static let version = 6
    static var versionedMarker: String { "\(marker)-v\(version)" }

    private struct HookError: Error { let message: String }

    enum Outcome {
        case status(installed: Bool, current: Bool)
        case failure(String)
    }

    // MARK: Hook specs

    /// A harness whose hooks live in a Claude-Code-shaped JSON file:
    /// `{"hooks": {"<Event>": [{"matcher": …, "hooks": [{"type": "command", …}]}]}}`.
    struct JSONHookTarget {
        let agent: String
        let relPath: String
        /// Host directory that must already exist for us to install (nil: always).
        let requiredDir: String?
        /// Whether commands carry the *versioned* marker. Codex asks the user to
        /// review hooks whose command text changed (trust is hash-based), so its
        /// commands stay constant across Belfry versions — the logic that does
        /// change lives in the script, which `check()` versions separately.
        let versionedCommands: Bool
        let events: [(event: String, matcher: String?)]
    }

    /// Claude Code. UserPromptSubmit/PreToolUse → working; PermissionRequest →
    /// waiting *immediately* (the Notification permission_prompt only fires after
    /// ~6s); PostToolUse → working again once an approved tool finishes (without
    /// it the pane sat on "waiting" for the whole run); Notification → waiting,
    /// or idle for the ~60s idle nudge (which also heals a missed Stop — Claude
    /// fires no Stop when you interrupt with Esc); Stop → idle/background;
    /// StopFailure → error (API errors skip Stop and left "working" stuck);
    /// SessionEnd clears everything.
    static let claude = JSONHookTarget(
        agent: "claude", relPath: ".claude/settings.json", requiredDir: nil, versionedCommands: true,
        events: [
            ("SessionStart", nil),
            ("UserPromptSubmit", nil),
            ("PreToolUse", "*"),
            ("PermissionRequest", "*"),
            ("PostToolUse", "*"),
            ("SubagentStart", nil),
            ("SubagentStop", nil),
            ("Notification", nil),
            ("Stop", nil),
            ("StopFailure", nil),
            ("SessionEnd", nil),
        ])

    /// Codex CLI hooks (`~/.codex/hooks.json`). Codex also has an Interrupt
    /// event, so Esc lands on idle straight away.
    static let codex = JSONHookTarget(
        agent: "codex", relPath: ".codex/hooks.json", requiredDir: ".codex", versionedCommands: false,
        events: [
            ("SessionStart", nil),
            ("UserPromptSubmit", nil),
            ("PreToolUse", nil),
            ("PermissionRequest", nil),
            ("PostToolUse", nil),
            ("SubagentStart", nil),
            ("SubagentStop", nil),
            ("Stop", nil),
            ("Interrupt", nil),
            ("SessionEnd", nil),
        ])

    /// Plugin-style harnesses: a file we own outright, written when the
    /// harness's config directory exists.
    private static var pluginFiles: [(requiredDir: String, relPath: String, contents: String)] {
        [
            (".config/opencode", AgentHookFiles.openCodePluginRelPath,
             AgentHookFiles.openCodePlugin(marker: versionedMarker)),
            (".pi/agent", AgentHookFiles.piExtensionRelPath,
             AgentHookFiles.piExtension(agent: "pi", marker: versionedMarker)),
            (".omp/agent", AgentHookFiles.ompExtensionRelPath,
             AgentHookFiles.piExtension(agent: "omp", marker: versionedMarker)),
        ]
    }

    /// The hook command for one event. Bails out immediately outside tmux, and
    /// exits 0 if the script has gone missing — a hook must never fail or stall
    /// the agent.
    static func command(agent: String, event: String, versioned: Bool) -> String {
        "[ -n \"$TMUX\" ] || exit 0; h=\"$HOME/\(AgentHookFiles.scriptRelPath)\"; "
        + "[ -x \"$h\" ] && exec \"$h\" \(agent) \(event); exit 0 "
        + "# \(versioned ? versionedMarker : marker)"
    }

    // MARK: Public API

    /// Report whether our hooks are present on the host, and whether they're
    /// current: Claude commands carrying the current versioned marker (when
    /// Claude hooks are installed at all) and the shared script up to date.
    static func check(_ transport: TmuxTransport) -> Outcome {
        let claudeText: String?, codexText: String?, scriptText: String?
        switch readFile(transport, claude.relPath) {
        case .failure(let error): return .failure(error.message)
        case .success(let text): claudeText = text
        }
        switch readFile(transport, codex.relPath) {
        case .failure(let error): return .failure(error.message)
        case .success(let text): codexText = text
        }
        switch readFile(transport, AgentHookFiles.scriptRelPath) {
        case .failure(let error): return .failure(error.message)
        case .success(let text): scriptText = text
        }
        let claudeInstalled = claudeText?.contains(marker) ?? false
        let codexInstalled = codexText?.contains(marker) ?? false
        let installed = claudeInstalled || codexInstalled
        return .status(installed: installed,
                       current: isCurrent(claude: claudeText, script: scriptText, claudeInstalled: claudeInstalled))
    }

    /// Versions named by `belfry-status-v<N>` markers in `text` (a bare,
    /// unversioned marker counts as 0).
    static func markerVersions(in text: String) -> Set<Int> {
        var versions = Set<Int>()
        var rest = Substring(text)
        while let range = rest.range(of: marker) {
            rest = rest[range.upperBound...]
            if rest.hasPrefix("-v") {
                let digits = rest.dropFirst(2).prefix { $0.isNumber }
                versions.insert(Int(digits) ?? 0)
            } else {
                versions.insert(0)
            }
        }
        return versions
    }

    /// Whether the installed hooks need no reinstall. Never downgrade: hooks
    /// from a *newer* Belfry are left alone (an older copy reinstalling its
    /// own version over them broke the newer one's status). A mix of versions
    /// — what that downgrade left behind — gets one clean reinstall.
    static func isCurrent(claude: String?, script: String?, claudeInstalled: Bool) -> Bool {
        let claudeVersions = markerVersions(in: claude ?? "")
        let scriptVersions = markerVersions(in: script ?? "")
        let all = claudeVersions.union(scriptVersions)
        if let newest = all.max(), newest > version { return true }
        let claudeOK = !claudeInstalled || claudeVersions == [version]
        return claudeOK && scriptVersions.contains(version)
    }

    /// Install the script, merge Claude's hooks (idempotent; backs up first),
    /// and set up every other harness present on the host. The script and the
    /// Claude merge must succeed; a problem with an optional harness (say, a
    /// hand-broken hooks.json) is logged and skipped rather than failing the lot.
    static func install(_ transport: TmuxTransport) -> Outcome {
        let present: Set<String>
        switch existingDirs(transport, [codex.requiredDir!] + pluginFiles.map(\.requiredDir)) {
        case .failure(let error): return .failure(error.message)
        case .success(let dirs): present = dirs
        }
        if case .failure(let error) = writeFile(
            transport, AgentHookFiles.scriptRelPath,
            contents: AgentHookFiles.script(marker: versionedMarker), executable: true, backup: false) {
            return .failure(error.message)
        }
        if case .failure(let message) = installJSON(claude, transport) {
            return .failure(message)
        }
        if present.contains(codex.requiredDir!), case .failure(let message) = installJSON(codex, transport) {
            clog("agent hooks: skipped Codex — \(message)")
        }
        for plugin in pluginFiles where present.contains(plugin.requiredDir) {
            if case .failure(let error) = writeFile(transport, plugin.relPath, contents: plugin.contents,
                                                    executable: false, backup: false) {
                clog("agent hooks: skipped \(plugin.relPath) — \(error.message)")
            }
        }
        return .status(installed: true, current: true)
    }

    /// Remove only our tagged hooks (leaving the user's other settings and hooks
    /// intact, backed up first), our plugin/extension files, and the script.
    static func remove(_ transport: TmuxTransport) -> Outcome {
        for target in [claude, codex] {
            if case .failure(let message) = removeJSON(target, transport) {
                return .failure(message)
            }
        }
        let files = pluginFiles.map(\.relPath) + [AgentHookFiles.scriptRelPath]
        if case .failure(let error) = removeFiles(transport, files) {
            return .failure(error.message)
        }
        return .status(installed: false, current: false)
    }

    private enum StepResult { case ok, failure(String) }

    private static func installJSON(_ target: JSONHookTarget, _ transport: TmuxTransport) -> StepResult {
        let existing: String?
        switch readFile(transport, target.relPath) {
        case .failure(let error): return .failure(error.message)
        case .success(let text): existing = text
        }
        guard let merged = merged(into: existing, target: target) else {
            return .failure("existing \(target.relPath) isn’t valid JSON — not modifying it")
        }
        if case .failure(let error) = writeFile(transport, target.relPath, contents: merged,
                                                executable: false, backup: true) {
            return .failure(error.message)
        }
        return .ok
    }

    private static func removeJSON(_ target: JSONHookTarget, _ transport: TmuxTransport) -> StepResult {
        let existing: String?
        switch readFile(transport, target.relPath) {
        case .failure(let error): return .failure(error.message)
        case .success(let text): existing = text
        }
        guard (existing ?? "").contains(marker) else { return .ok }
        guard let stripped = stripped(from: existing) else {
            return .failure("existing \(target.relPath) isn’t valid JSON — not modifying it")
        }
        if case .failure(let error) = writeFile(transport, target.relPath, contents: stripped,
                                                executable: false, backup: true) {
            return .failure(error.message)
        }
        return .ok
    }

    // MARK: JSON merge (pure, unit-tested)

    /// Returns the merged hooks JSON, or nil if `existing` is non-empty but not
    /// valid JSON (caller must not overwrite in that case).
    static func merged(into existing: String?, target: JSONHookTarget = claude) -> String? {
        var root: [String: Any] = [:]
        if let existing,
           !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let data = existing.data(using: .utf8) {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            root = object
        }
        // A present-but-non-object `hooks` is malformed; refuse rather than clobber.
        if root["hooks"] != nil, root["hooks"] as? [String: Any] == nil { return nil }

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        // Drop every prior Belfry entry first — including events this version no
        // longer hooks — so upgrades never leave a stale command behind.
        for event in Array(hooks.keys) {
            guard var groups = hooks[event] as? [Any] else { continue }
            groups.removeAll { isBelfryGroup($0) }
            hooks[event] = groups.isEmpty ? nil : groups
        }
        for item in target.events {
            var groups = (hooks[item.event] as? [Any]) ?? []
            let handler: [String: Any] = [
                "type": "command",
                "command": command(agent: target.agent, event: item.event, versioned: target.versionedCommands),
                "timeout": 10,
            ]
            var entry: [String: Any] = ["hooks": [handler]]
            if let matcher = item.matcher { entry["matcher"] = matcher }
            groups.append(entry)
            hooks[item.event] = groups
        }
        root["hooks"] = hooks

        guard let out = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: out, encoding: .utf8) else { return nil }
        return string + "\n"
    }

    /// Returns hooks JSON with our tagged hooks removed (and any now-empty
    /// event arrays / empty `hooks` object pruned), or nil if `existing` is
    /// non-empty but not valid JSON.
    static func stripped(from existing: String?) -> String? {
        guard let existing,
              !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = existing.data(using: .utf8),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if root["hooks"] != nil, root["hooks"] as? [String: Any] == nil { return nil }

        if var hooks = root["hooks"] as? [String: Any] {
            for event in Array(hooks.keys) {
                guard var groups = hooks[event] as? [Any] else { continue }
                groups.removeAll { isBelfryGroup($0) }
                if groups.isEmpty { hooks[event] = nil } else { hooks[event] = groups }
            }
            if hooks.isEmpty { root["hooks"] = nil } else { root["hooks"] = hooks }
        }

        guard let out = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: out, encoding: .utf8) else { return nil }
        return string + "\n"
    }

    private static func isBelfryGroup(_ item: Any) -> Bool {
        guard let group = item as? [String: Any],
              let inner = group["hooks"] as? [Any] else { return false }
        return inner.contains { hook in
            ((hook as? [String: Any])?["command"] as? String)?.contains(marker) ?? false
        }
    }

    // MARK: I/O  (run off the main thread by callers)
    //
    // All paths are home-relative constants from this file (no spaces or shell
    // metacharacters), so they're interpolated into remote scripts directly.

    private static func localPath(_ relPath: String) -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(relPath)
    }

    /// `.success(nil)` = file absent; `.success(text)` = file contents;
    /// `.failure` = couldn't reach the host.
    private static func readFile(_ transport: TmuxTransport, _ relPath: String) -> Result<String?, HookError> {
        switch transport {
        case .local:
            return .success(try? String(contentsOfFile: localPath(relPath), encoding: .utf8))
        case .ssh(let alias):
            // `|| true` ⇒ absent file is empty output at exit 0; ssh failing to
            // connect is exit 255.
            let (out, code) = run("/usr/bin/ssh",
                SSHControl.options + ["-o", "ConnectTimeout=10", alias,
                                      "cat \"$HOME/\(relPath)\" 2>/dev/null || true"])
            if code == 255 { return .failure(HookError(message: "couldn’t reach \(alias) over SSH")) }
            return .success(out.isEmpty ? nil : out)
        }
    }

    /// Which of the home-relative `dirs` exist on the host.
    private static func existingDirs(_ transport: TmuxTransport, _ dirs: [String]) -> Result<Set<String>, HookError> {
        switch transport {
        case .local:
            var isDir: ObjCBool = false
            return .success(Set(dirs.filter {
                FileManager.default.fileExists(atPath: localPath($0), isDirectory: &isDir) && isDir.boolValue
            }))
        case .ssh(let alias):
            let script = "for d in \(dirs.joined(separator: " ")); do [ -d \"$HOME/$d\" ] && echo \"$d\"; done; true"
            let (out, code) = run("/usr/bin/ssh", SSHControl.options + ["-o", "ConnectTimeout=10", alias, script])
            if code == 255 { return .failure(HookError(message: "couldn’t reach \(alias) over SSH")) }
            return .success(Set(out.split(separator: "\n").map(String.init)).intersection(dirs))
        }
    }

    /// Write `contents` to a home-relative path, creating parent directories,
    /// optionally backing up an existing file to `<path>.belfry-bak` first. The
    /// write is atomic (temp file + rename) so a dropped connection can't leave a
    /// truncated settings file.
    private static func writeFile(_ transport: TmuxTransport, _ relPath: String, contents: String,
                                  executable: Bool, backup: Bool) -> Result<Void, HookError> {
        switch transport {
        case .local:
            let path = localPath(relPath)
            let dir = (path as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            if backup, FileManager.default.fileExists(atPath: path) {
                let backupPath = path + ".belfry-bak"
                try? FileManager.default.removeItem(atPath: backupPath)
                try? FileManager.default.copyItem(atPath: path, toPath: backupPath)
            }
            do {
                try contents.write(toFile: path, atomically: true, encoding: .utf8)
                if executable {
                    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
                }
                return .success(())
            } catch {
                return .failure(HookError(message: "couldn’t write ~/\(relPath): \(error.localizedDescription)"))
            }
        case .ssh(let alias):
            let file = "\"$HOME/\(relPath)\""
            let tmp = "\"$HOME/\(relPath).belfry-tmp\""
            var steps = ["mkdir -p \"$(dirname \(file))\""]
            if backup { steps.append("{ [ -f \(file) ] && cp \(file) \"$HOME/\(relPath).belfry-bak\" || true; }") }
            steps.append("cat > \(tmp)")
            if executable { steps.append("chmod 755 \(tmp)") }
            steps.append("mv \(tmp) \(file)")
            let (_, code) = run("/usr/bin/ssh",
                SSHControl.options + ["-o", "ConnectTimeout=10", alias, steps.joined(separator: " && ")],
                stdin: contents)
            if code == 0 { return .success(()) }
            return .failure(HookError(message: code == 255 ? "couldn’t reach \(alias) over SSH"
                                                           : "remote write of ~/\(relPath) failed (exit \(code))"))
        }
    }

    private static func removeFiles(_ transport: TmuxTransport, _ relPaths: [String]) -> Result<Void, HookError> {
        switch transport {
        case .local:
            for relPath in relPaths { try? FileManager.default.removeItem(atPath: localPath(relPath)) }
            return .success(())
        case .ssh(let alias):
            let script = "rm -f " + relPaths.map { "\"$HOME/\($0)\"" }.joined(separator: " ")
            let (_, code) = run("/usr/bin/ssh", SSHControl.options + ["-o", "ConnectTimeout=10", alias, script])
            return code == 255 ? .failure(HookError(message: "couldn’t reach \(alias) over SSH")) : .success(())
        }
    }

    private static func run(_ launch: String, _ args: [String], stdin: String? = nil) -> (out: String, code: Int32) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launch)
        proc.arguments = args
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        var inPipe: Pipe?
        if stdin != nil { let pipe = Pipe(); proc.standardInput = pipe; inPipe = pipe }
        do { try proc.run() } catch { return ("", -1) }
        if let stdin, let inPipe {
            inPipe.fileHandleForWriting.write(Data(stdin.utf8))
            inPipe.fileHandleForWriting.closeFile()
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (String(decoding: data, as: UTF8.self), proc.terminationStatus)
    }
}
