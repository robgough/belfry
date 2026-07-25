import Foundation
import Observation

// Saved commands ("shortcuts"): tap-to-send sequences for the touch UI,
// grouped into collections shown as tabs in the palette. Starter collections
// ship with the app; the store reseeds them on upgrade without resurrecting
// anything the user deleted (deletions are remembered by id, Remux-style).

/// One step of a shortcut. Multi-step shortcuts run in order.
enum ShortcutStep: Codable, Hashable, Sendable {
    /// Type text; `submit` sends Enter after a short settle delay (TUIs need
    /// the text and the Enter as separate events).
    case text(String, submit: Bool)
    /// A control chord in caret notation ("^C") or bare letter ("c" = Ctrl-C).
    case control(String)
    /// A special key, synthesized through the renderer's key path.
    case key(TerminalKey)
}

struct Shortcut: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var title: String
    var steps: [ShortcutStep]

    init(id: UUID = UUID(), title: String, steps: [ShortcutStep]) {
        self.id = id
        self.title = title
        self.steps = steps
    }

    /// Single-line preview of what the shortcut sends (for editors/tiles).
    var preview: String {
        steps.map { step in
            switch step {
            case .text(let text, let submit): submit ? "\(text)⏎" : text
            case .control(let spec): spec.hasPrefix("^") ? spec : "^" + spec.uppercased()
            case .key(let key): key.rawValue
            }
        }.joined(separator: " ")
    }
}

struct ShortcutCollection: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var title: String
    /// SF Symbol shown on the palette tab.
    var symbol: String
    var shortcuts: [Shortcut]
}

// MARK: - Starters

enum StarterShortcuts {
    // Fixed ids so deletions and upgrades are stable across launches.
    private static func uuid(_ suffix: String) -> UUID {
        UUID(uuidString: "B31F0000-0000-4000-8000-\(suffix)")!
    }

    static let shell = ShortcutCollection(
        id: uuid("000000000001"),
        title: "Shell",
        symbol: "terminal",
        shortcuts: [
            Shortcut(id: uuid("000000000101"), title: "Stop ^C", steps: [.control("^C")]),
            Shortcut(id: uuid("000000000102"), title: "Clear ^L", steps: [.control("^L")]),
            Shortcut(id: uuid("000000000103"), title: "History ^R", steps: [.control("^R")]),
            Shortcut(id: uuid("000000000104"), title: "EOF ^D", steps: [.control("^D")]),
            Shortcut(id: uuid("000000000105"), title: "Suspend ^Z", steps: [.control("^Z")]),
        ])

    static let claude = ShortcutCollection(
        id: uuid("000000000002"),
        title: "Claude",
        symbol: "sparkle",
        shortcuts: [
            Shortcut(id: uuid("000000000201"), title: "Resume", steps: [.text("/resume", submit: true)]),
            Shortcut(id: uuid("000000000202"), title: "Compact", steps: [.text("/compact", submit: true)]),
            Shortcut(id: uuid("000000000203"), title: "Clear", steps: [.text("/clear", submit: true)]),
            Shortcut(id: uuid("000000000204"), title: "Model", steps: [.text("/model", submit: true)]),
            Shortcut(id: uuid("000000000205"), title: "Interrupt", steps: [.key(.escape)]),
        ])

    static let git = ShortcutCollection(
        id: uuid("000000000003"),
        title: "Git",
        symbol: "arrow.triangle.branch",
        shortcuts: [
            Shortcut(id: uuid("000000000301"), title: "Status", steps: [.text("git status", submit: true)]),
            Shortcut(id: uuid("000000000302"), title: "Diff", steps: [.text("git diff", submit: true)]),
            Shortcut(id: uuid("000000000303"), title: "Log", steps: [.text("git log --oneline -20", submit: true)]),
        ])

    static let all: [ShortcutCollection] = [shell, claude, git]
}

// MARK: - Store

/// Persisted shortcut state. Versioned JSON in Application Support; starter
/// content is seeded by id, so upgrades can add new starters while deletions
/// stay deleted.
struct ShortcutStoreSnapshot: Codable {
    var schemaVersion: Int = 1
    var collections: [ShortcutCollection] = []
    var installedStarterIDs: Set<UUID> = []
    var deletedStarterIDs: Set<UUID> = []
}

@MainActor
@Observable
final class ShortcutStore {
    private(set) var collections: [ShortcutCollection] = []
    @ObservationIgnored private var installedStarterIDs: Set<UUID> = []
    @ObservationIgnored private var deletedStarterIDs: Set<UUID> = []
    @ObservationIgnored private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultURL()
        load()
        seedStarters()
    }

    private static func defaultURL() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Belfry/shortcuts.json")
    }

    // MARK: Mutations (all persist immediately)

    func addShortcut(_ shortcut: Shortcut, to collectionID: UUID) {
        guard let index = collections.firstIndex(where: { $0.id == collectionID }) else { return }
        collections[index].shortcuts.append(shortcut)
        save()
    }

    func updateShortcut(_ shortcut: Shortcut, in collectionID: UUID) {
        guard let ci = collections.firstIndex(where: { $0.id == collectionID }),
              let si = collections[ci].shortcuts.firstIndex(where: { $0.id == shortcut.id }) else { return }
        collections[ci].shortcuts[si] = shortcut
        save()
    }

    func removeShortcut(id: UUID, from collectionID: UUID) {
        guard let ci = collections.firstIndex(where: { $0.id == collectionID }) else { return }
        collections[ci].shortcuts.removeAll { $0.id == id }
        // Remember starter deletions so reseeding doesn't resurrect them.
        if installedStarterIDs.contains(id) { deletedStarterIDs.insert(id) }
        save()
    }

    func addCollection(title: String, symbol: String = "folder") {
        collections.append(ShortcutCollection(id: UUID(), title: title, symbol: symbol, shortcuts: []))
        save()
    }

    func removeCollection(id: UUID) {
        guard let collection = collections.first(where: { $0.id == id }) else { return }
        for shortcut in collection.shortcuts where installedStarterIDs.contains(shortcut.id) {
            deletedStarterIDs.insert(shortcut.id)
        }
        if installedStarterIDs.contains(id) { deletedStarterIDs.insert(id) }
        collections.removeAll { $0.id == id }
        save()
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(ShortcutStoreSnapshot.self, from: data)
        else { return }
        collections = snapshot.collections
        installedStarterIDs = snapshot.installedStarterIDs
        deletedStarterIDs = snapshot.deletedStarterIDs
    }

    private func save() {
        let snapshot = ShortcutStoreSnapshot(
            collections: collections,
            installedStarterIDs: installedStarterIDs,
            deletedStarterIDs: deletedStarterIDs)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Install any starter (collection or shortcut) the user hasn't seen and
    /// hasn't deleted. New starters in an app update appear on next launch.
    private func seedStarters() {
        var changed = false
        for starter in StarterShortcuts.all {
            if deletedStarterIDs.contains(starter.id) { continue }
            if var existing = collections.first(where: { $0.id == starter.id }) {
                // Collection exists: add only never-installed, never-deleted shortcuts.
                for shortcut in starter.shortcuts
                where !installedStarterIDs.contains(shortcut.id)
                    && !deletedStarterIDs.contains(shortcut.id)
                    && !existing.shortcuts.contains(where: { $0.id == shortcut.id }) {
                    existing.shortcuts.append(shortcut)
                    installedStarterIDs.insert(shortcut.id)
                    changed = true
                }
                if let index = collections.firstIndex(where: { $0.id == starter.id }) {
                    collections[index] = existing
                }
            } else if !installedStarterIDs.contains(starter.id) {
                var seeded = starter
                seeded.shortcuts = starter.shortcuts.filter { !deletedStarterIDs.contains($0.id) }
                collections.append(seeded)
                installedStarterIDs.insert(starter.id)
                installedStarterIDs.formUnion(seeded.shortcuts.map(\.id))
                changed = true
            }
        }
        if changed { save() }
    }
}

// MARK: - Executor

@MainActor
enum ShortcutExecutor {
    /// Run the shortcut against a live workspace. The 75 ms settle between
    /// text and Enter matters for TUIs that treat paste-then-return in one
    /// event batch differently from typed input (Claude Code among them).
    static func run(_ shortcut: Shortcut, on workspace: any TerminalWorkspace) async {
        for step in shortcut.steps {
            switch step {
            case .text(let text, let submit):
                workspace.sendInput(Data(text.utf8))
                if submit {
                    try? await Task.sleep(for: .milliseconds(75))
                    workspace.sendKey(.enter)
                }
            case .control(let spec):
                if let data = ControlSequences.data(forControl: spec) {
                    workspace.sendInput(data)
                }
            case .key(let key):
                workspace.sendKey(key)
            }
        }
    }
}
