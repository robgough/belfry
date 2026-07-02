import Foundation

/// A user-added SSH host, persisted across launches.
struct SavedHost: Codable, Hashable {
    let alias: String
    var displayName: String?
}

/// Reads/writes the saved SSH host list as JSON under Application Support.
/// File-based (not UserDefaults) so it persists reliably for this bare SPM
/// executable, which has no bundle identifier.
enum HostPersistence {
    private static func appSupportFile(_ folder: String) -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent(folder, isDirectory: true)
            .appendingPathComponent("hosts.json")
    }

    private static var fileURL: URL { appSupportFile("Belfry") }
    private static var legacyURL: URL { appSupportFile("Sessionator") }

    static func load() -> [SavedHost] {
        // One-time migration from the app's former name so saved hosts survive.
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path), fm.fileExists(atPath: legacyURL.path) {
            try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.copyItem(at: legacyURL, to: fileURL)
        }
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([SavedHost].self, from: data)) ?? []
    }

    static func save(_ hosts: [SavedHost]) {
        let url = fileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(hosts) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
