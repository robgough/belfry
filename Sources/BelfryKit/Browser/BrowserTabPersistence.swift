import Foundation

/// On-disk record of one session's browser tabs, keyed by host + session
/// *name* — the PinnedItem identity trick: tmux's stable ids die with the
/// server, names survive it. Records outlive their session (like a pin shown
/// dimmed), so a project restored after a reboot gets its tabs back the first
/// time a session with the same name is visited.
struct SessionTabsRecord: Codable, Equatable {
    struct TabRecord: Codable, Equatable {
        var url: URL?
        var profileID: UUID?
    }
    let hostID: String
    var sessionName: String
    var tabs: [TabRecord]
}

/// Reads/writes the browser-tab records as JSON under Application Support,
/// next to (and for the same reason as) `PinPersistence` — file-based because
/// this bare SPM executable has no bundle identifier for UserDefaults.
/// Instance-based (unlike PinPersistence) so tests can point it at a
/// temporary directory.
struct BrowserTabPersistence {
    let fileURL: URL

    init(directory: URL? = nil) {
        let base = directory ?? (FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support"))
            .appendingPathComponent("Belfry", isDirectory: true)
        self.fileURL = base.appendingPathComponent("browser-tabs.json")
    }

    func load() -> [SessionTabsRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([SessionTabsRecord].self, from: data)) ?? []
    }

    func save(_ records: [SessionTabsRecord]) {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
