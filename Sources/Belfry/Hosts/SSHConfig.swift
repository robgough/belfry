import Foundation

/// A host candidate discovered in `~/.ssh/config`.
struct SSHConfigHost: Identifiable, Hashable {
    let alias: String         // the `Host` pattern (a concrete alias)
    let hostName: String?     // the resolved `HostName`, if specified
    var id: String { alias }

    /// What to show in a picker: "alias — hostname" when they differ.
    var label: String {
        if let hostName, hostName != alias { return "\(alias) — \(hostName)" }
        return alias
    }
}

/// Minimal `~/.ssh/config` reader: pulls concrete `Host` aliases (skipping
/// wildcard patterns and negations) and their `HostName`, so the Add-Host UI can
/// suggest real targets. Intentionally forgiving — unknown keywords are ignored.
enum SSHConfig {
    static func hosts(at path: String = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh/config")) -> [SSHConfigHost] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return parse(text)
    }

    static func parse(_ text: String) -> [SSHConfigHost] {
        var result: [SSHConfigHost] = []
        var seen = Set<String>()
        // Aliases of the current `Host` block, paired with the HostName once seen.
        var currentAliases: [String] = []
        var currentHostName: String?

        func flush() {
            for alias in currentAliases where seen.insert(alias).inserted {
                result.append(SSHConfigHost(alias: alias, hostName: currentHostName))
            }
            currentAliases = []
            currentHostName = nil
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            // Keyword and value are separated by whitespace or '='.
            let separated = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
            guard let keyword = separated.first?.lowercased() else { continue }
            let values = separated.dropFirst().map(String.init)

            switch keyword {
            case "host":
                flush()
                // Keep only concrete aliases: no wildcards (* ?) and no negations (!).
                currentAliases = values.filter { v in
                    !v.contains("*") && !v.contains("?") && !v.hasPrefix("!")
                }
            case "hostname":
                currentHostName = values.first
            default:
                break
            }
        }
        flush()
        return result.sorted { $0.alias.localizedCaseInsensitiveCompare($1.alias) == .orderedAscending }
    }
}
