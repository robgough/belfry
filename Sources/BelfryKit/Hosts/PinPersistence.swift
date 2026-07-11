import Foundation

/// A sidebar pin: a session (or a single window) the user wants surfaced in the
/// dedicated Pinned section at the top of the sidebar, persisted across launches.
///
/// Identity is the host plus tmux's stable ids (`$5` / `@10`). Those ids only
/// survive as long as the tmux *server* runs, so the user-visible names are
/// cached alongside: a pin whose session id has vanished re-resolves by session
/// name (names survive server restarts), and a pin that can't resolve at all
/// still knows what to call itself while shown dimmed.
struct PinnedItem: Codable, Hashable, Identifiable {
    let hostID: String
    let sessionID: String
    /// nil pins the whole session; otherwise the tmux window id.
    var windowID: String?
    /// Cached labels for display while the pin is unresolved.
    var sessionName: String
    var windowName: String?
    var windowIndex: Int?

    var id: String { "\(hostID)|\(sessionID)|\(windowID ?? "")" }
}

/// Reads/writes the pinned-item list as JSON under Application Support, next to
/// (and for the same reason as) `HostPersistence` — file-based because this bare
/// SPM executable has no bundle identifier for UserDefaults.
enum PinPersistence {
    private static var fileURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("Belfry", isDirectory: true)
            .appendingPathComponent("pins.json")
    }

    static func load() -> [PinnedItem] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([PinnedItem].self, from: data)) ?? []
    }

    static func save(_ pins: [PinnedItem]) {
        let url = fileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(pins) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
