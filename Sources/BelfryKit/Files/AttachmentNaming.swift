import Foundation

/// Naming rules for terminal attachments (photos/files sent to the host and
/// referenced at the prompt). Pure helpers — tested without I/O.
enum AttachmentNaming {
    /// Remote directory one transfer's files land in. Grouped per session so
    /// `rm -rf ~/.cache/belfry/attachments/<session>` is a sane cleanup, with
    /// a per-transfer component so repeated sends never collide.
    static func remoteDirectory(sessionName: String, transferID: UUID) -> String {
        "~/.cache/belfry/attachments/\(sanitized(sessionName))/\(transferID.uuidString.lowercased().prefix(8))"
    }

    /// Make a filename safe to quote into a shell and pleasant at a prompt:
    /// control chars, separators and quotes become `_`, leading dots and
    /// dashes are trimmed (no hidden files, nothing that parses as a flag),
    /// and the whole thing is capped at 180 chars preserving the extension.
    static func sanitized(_ name: String) -> String {
        var cleaned = String(name.map { char in
            if char.isNewline || char.asciiValue.map({ $0 < 0x20 || $0 == 0x7F }) == true { return "_" }
            if "/\\'\"`$&|;<>*?~".contains(char) { return "_" }
            return char
        })
        while let first = cleaned.first, first == "." || first == "-" || first == "_" {
            cleaned.removeFirst()
        }
        if cleaned.isEmpty { cleaned = "attachment" }
        if cleaned.count > 180 {
            let ext = (cleaned as NSString).pathExtension
            let stem = String(((cleaned as NSString).deletingPathExtension).prefix(160))
            cleaned = ext.isEmpty ? stem : "\(stem).\(ext)"
        }
        return cleaned
    }

    /// De-duplicate within one transfer: "photo.png", "photo-2.png", …
    static func deduplicated(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for name in names {
            var candidate = name
            var counter = 2
            while seen.contains(candidate.lowercased()) {
                let ext = (name as NSString).pathExtension
                let stem = (name as NSString).deletingPathExtension
                candidate = ext.isEmpty ? "\(stem)-\(counter)" : "\(stem)-\(counter).\(ext)"
                counter += 1
            }
            seen.insert(candidate.lowercased())
            result.append(candidate)
        }
        return result
    }

    /// A path as typed at the prompt: bare when every character is shell-safe,
    /// single-quoted (with `'"'"'` splicing) otherwise.
    static func promptQuoted(_ path: String) -> String {
        let safe = path.allSatisfy { char in
            char.isASCII && (char.isLetter || char.isNumber || "/._-+=:@%".contains(char))
        }
        return safe && !path.isEmpty ? path : RemoteTmux.quoted(path)
    }
}
