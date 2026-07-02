import Foundation

/// Detects and installs the Claude Code hooks that drive Belfry's per-window
/// status badges (see docs/claude-status-hooks.md). Works for the local machine
/// and for SSH hosts; the JSON merge happens here in Swift, so a remote host needs
/// nothing but `ssh` + a shell (no `jq`/`python`).
///
/// Hooks are merged into `~/.claude/settings.json`, tagged with a marker so we can
/// detect them and reinstall idempotently without disturbing the user's other
/// settings or hooks. A backup is written to `settings.json.belfry-bak`.
enum ClaudeHooks {
    static let marker = "belfry-status"

    private struct HookError: Error { let message: String }

    /// event → (command, optional tool matcher). UserPromptSubmit/PreToolUse mean
    /// "working"; Notification means "waiting for you"; Stop means "waiting" *unless*
    /// background tasks/agents are still running (then "background"); SessionEnd clears it.
    private static var spec: [(event: String, command: String, matcher: String?)] {
        [
            ("UserPromptSubmit", set("working"), nil),
            ("PreToolUse",       set("working"), "*"),
            ("Notification",     set("waiting"), nil),
            ("Stop",             stopCommand(),  nil),
            ("SessionEnd",       unset(),        nil),
        ]
    }

    private static func set(_ state: String) -> String {
        "[ -n \"$TMUX\" ] && tmux set -w @claude_state \(state) # \(marker)"
    }
    private static func unset() -> String {
        "[ -n \"$TMUX\" ] && tmux set -uw @claude_state # \(marker)"
    }

    /// The Stop hook fires at every turn end. Its stdin JSON carries a `background_tasks`
    /// array that's non-empty exactly when background bash/agents are still in flight (and
    /// will auto-resume Claude). We string-match that array in pure POSIX sh — no jq/python
    /// — so remote hosts still need nothing but a shell: strip whitespace, then a non-empty
    /// `"background_tasks":[…]` ⇒ "background" (not your turn), else "waiting" (your turn).
    private static func stopCommand() -> String {
        "[ -n \"$TMUX\" ] || exit 0; s=$(cat); c=$(printf '%s' \"$s\" | tr -d '[:space:]'); "
        + "case \"$c\" in "
        + "*'\"background_tasks\":[]'*) st=waiting;; "
        + "*'\"background_tasks\":['*) st=background;; "
        + "*) st=waiting;; esac; "
        + "tmux set -w @claude_state \"$st\" # \(marker)"
    }

    // MARK: Public API

    enum Outcome {
        case status(installed: Bool)
        case failure(String)
    }

    /// Read settings.json for the host and report whether our hooks are present.
    static func check(_ transport: TmuxTransport) -> Outcome {
        switch readSettings(transport) {
        case .failure(let error): return .failure(error.message)
        case .success(let text): return .status(installed: (text ?? "").contains(marker))
        }
    }

    /// Merge our hooks into the host's settings.json (idempotent; backs up first).
    static func install(_ transport: TmuxTransport) -> Outcome {
        let existing: String?
        switch readSettings(transport) {
        case .failure(let error): return .failure(error.message)
        case .success(let text): existing = text
        }
        guard let merged = merged(into: existing) else {
            return .failure("existing settings.json isn't valid JSON — not modifying it")
        }
        switch writeSettings(transport, contents: merged) {
        case .failure(let error): return .failure(error.message)
        case .success: return .status(installed: true)
        }
    }

    /// Remove only our tagged hooks from the host's settings.json, leaving the
    /// user's other settings and hooks intact (backs up first). A no-op if ours
    /// aren't present.
    static func remove(_ transport: TmuxTransport) -> Outcome {
        let existing: String?
        switch readSettings(transport) {
        case .failure(let error): return .failure(error.message)
        case .success(let text): existing = text
        }
        guard (existing ?? "").contains(marker) else { return .status(installed: false) }
        guard let stripped = stripped(from: existing) else {
            return .failure("existing settings.json isn't valid JSON — not modifying it")
        }
        switch writeSettings(transport, contents: stripped) {
        case .failure(let error): return .failure(error.message)
        case .success: return .status(installed: false)
        }
    }

    // MARK: JSON merge (pure, unit-tested)

    /// Returns the merged settings JSON, or nil if `existing` is non-empty but not
    /// valid JSON (caller must not overwrite in that case).
    static func merged(into existing: String?) -> String? {
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
        for item in spec {
            var groups = (hooks[item.event] as? [Any]) ?? []
            groups.removeAll { isBelfryGroup($0) }   // idempotent: drop our prior entry
            var entry: [String: Any] = ["hooks": [["type": "command", "command": item.command]]]
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

    /// Returns settings JSON with our tagged hooks removed (and any now-empty
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

    private static let relPath = ".claude/settings.json"

    /// `.success(nil)` = file absent; `.success(text)` = file contents;
    /// `.failure` = couldn't reach the host.
    private static func readSettings(_ transport: TmuxTransport) -> Result<String?, HookError> {
        switch transport {
        case .local:
            let path = (NSHomeDirectory() as NSString).appendingPathComponent(relPath)
            return .success(try? String(contentsOfFile: path, encoding: .utf8))
        case .ssh(let alias):
            // `|| true` ⇒ absent file is empty output at exit 0; ssh failing to
            // connect is exit 255.
            let (out, code) = run("/usr/bin/ssh",
                SSHControl.options + ["-o", "ConnectTimeout=10", alias,
                                      "cat ~/\(relPath) 2>/dev/null || true"])
            if code == 255 { return .failure(HookError(message: "couldn’t reach \(alias) over SSH")) }
            return .success(out.isEmpty ? nil : out)
        }
    }

    private static func writeSettings(_ transport: TmuxTransport, contents: String) -> Result<Void, HookError> {
        switch transport {
        case .local:
            let path = (NSHomeDirectory() as NSString).appendingPathComponent(relPath)
            let dir = (path as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: path) {
                let backup = path + ".belfry-bak"
                try? FileManager.default.removeItem(atPath: backup)
                try? FileManager.default.copyItem(atPath: path, toPath: backup)
            }
            do {
                try contents.write(toFile: path, atomically: true, encoding: .utf8)
                return .success(())
            } catch {
                return .failure(HookError(message: "couldn’t write settings.json: \(error.localizedDescription)"))
            }
        case .ssh(let alias):
            // Stream into a temp file and rename only once the write completed,
            // so a connection dropped mid-transfer can't leave settings.json
            // truncated (the backup still exists either way).
            let script = """
                mkdir -p ~/.claude && \
                { [ -f ~/\(relPath) ] && cp ~/\(relPath) ~/\(relPath).belfry-bak || true; } && \
                cat > ~/\(relPath).belfry-tmp && mv ~/\(relPath).belfry-tmp ~/\(relPath)
                """
            let (_, code) = run("/usr/bin/ssh",
                SSHControl.options + ["-o", "ConnectTimeout=10", alias, script],
                stdin: contents)
            if code == 0 { return .success(()) }
            return .failure(HookError(message: code == 255 ? "couldn’t reach \(alias) over SSH"
                                                           : "remote write failed (exit \(code))"))
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
