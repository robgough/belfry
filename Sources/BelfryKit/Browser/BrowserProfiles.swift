import Foundation
import WebKit

/// The fixed palette for profile dots (Finder-tag style). Persisted by name,
/// so reordering or extending the palette never recolours existing profiles.
enum ProfileColor: String, Codable, CaseIterable {
    case red, orange, yellow, green, teal, blue, indigo, purple, pink, brown
}

/// A named cookie/localStorage silo. Tabs sharing a profile share logins;
/// tabs on different profiles are fully isolated — two tabs signed in as one
/// user and a third as another, for testing. `id` keys the on-disk WebKit
/// store via `WKWebsiteDataStore(forIdentifier:)`, so profiles survive
/// relaunches.
struct BrowserProfile: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    /// Optional so profiles saved before colours existed still decode;
    /// they fall back to the id-derived hue.
    var color: ProfileColor?
}

/// browser-profiles.json under Application Support — same file-based pattern
/// (and reason) as the other Belfry persistence: no bundle id for
/// UserDefaults in the bare SPM binary. Instance-based for test injection.
struct BrowserProfilePersistence {
    let fileURL: URL

    init(directory: URL? = nil) {
        let base = directory ?? (FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support"))
            .appendingPathComponent("Belfry", isDirectory: true)
        self.fileURL = base.appendingPathComponent("browser-profiles.json")
    }

    func load() -> [BrowserProfile] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([BrowserProfile].self, from: data)) ?? []
    }

    func save(_ profiles: [BrowserProfile]) {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

@MainActor
@Observable
final class BrowserProfileStore {
    private let persistence: BrowserProfilePersistence
    /// Deletes a profile's on-disk website data. Injectable so unit tests
    /// never touch real WebKit storage.
    private let removeData: (UUID) -> Void

    private(set) var profiles: [BrowserProfile]

    init(persistence: BrowserProfilePersistence = BrowserProfilePersistence(),
         removeData: ((UUID) -> Void)? = nil) {
        self.persistence = persistence
        self.profiles = persistence.load()
        self.removeData = removeData ?? { id in
            Task { try? await WKWebsiteDataStore.remove(forIdentifier: id) }
        }
    }

    func profile(for id: UUID) -> BrowserProfile? {
        profiles.first { $0.id == id }
    }

    func name(for id: UUID?) -> String {
        guard let id else { return "Default" }
        return profile(for: id)?.name ?? "Default"
    }

    /// The cookie/localStorage silo backing a profile. Same identifier →
    /// same persistent store across launches; nil → WebKit's default store.
    func dataStore(for id: UUID?) -> WKWebsiteDataStore {
        guard let id else { return .default() }
        return WKWebsiteDataStore(forIdentifier: id)
    }

    @discardableResult
    func create(name: String, color: ProfileColor? = nil) -> BrowserProfile {
        let profile = BrowserProfile(id: UUID(), name: name, color: color ?? nextColor())
        profiles.append(profile)
        persistence.save(profiles)
        return profile
    }

    /// Rename/recolour: replace the stored profile with the same id.
    func update(_ profile: BrowserProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
        persistence.save(profiles)
    }

    /// Default for a new profile: the first palette colour not in use, so
    /// Alice and Bob never come out looking alike by accident.
    func nextColor() -> ProfileColor {
        let used = Set(profiles.compactMap(\.color))
        return ProfileColor.allCases.first { !used.contains($0) }
            ?? ProfileColor.allCases[profiles.count % ProfileColor.allCases.count]
    }

    /// Forgets the profile and deletes its cookies/storage from disk.
    /// Callers must remap tabs first (BrowserTabStore.deleteProfile does).
    func delete(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        persistence.save(profiles)
        removeData(id)
    }

    /// Stable tint for a profile's dot, derived from the id (not the list
    /// position) so it never shifts as profiles come and go. Pure math —
    /// nonisolated so views can call it from any context.
    nonisolated static func hue(for id: UUID) -> Double {
        Double(id.uuid.0) / 255.0
    }
}
