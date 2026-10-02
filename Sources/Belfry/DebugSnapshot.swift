#if DEBUG
import AppKit

/// Debug builds only: on request, Belfry renders each of its own windows to a
/// PNG, so UI work can be checked without granting anything Screen Recording
/// permission (an app drawing its own views needs none). Triggered by the
/// distributed notification `net.robgough.belfry.debug.snapshot`; files land in
/// `~/Library/Caches/Belfry/snapshots/<window>.png`, overwritten each time,
/// followed by a `done` marker file. Metal-backed views (the terminals) may
/// come out blank — the chrome is what this is for.
enum DebugSnapshot {
    static let notification = Notification.Name("net.robgough.belfry.debug.snapshot")

    static func install() {
        DistributedNotificationCenter.default().addObserver(
            forName: notification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { capture() }
        }
    }

    @MainActor
    private static func capture() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Belfry/snapshots/\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let marker = dir.appendingPathComponent("done")
        try? FileManager.default.removeItem(at: marker)
        var written: [String] = []
        for (index, window) in NSApp.windows.enumerated() where window.isVisible {
            // The theme frame (contentView's superview) includes the title bar
            // and toolbar, not just the content.
            guard let view = window.contentView?.superview ?? window.contentView else { continue }
            let bounds = view.bounds
            guard bounds.width > 1, bounds.height > 1,
                  let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { continue }
            view.cacheDisplay(in: bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { continue }
            let title = window.title.isEmpty ? "window-\(index)" : window.title
            let name = title.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
            let file = dir.appendingPathComponent(String(name.prefix(40)) + ".png")
            if (try? png.write(to: file)) != nil { written.append(file.lastPathComponent) }
        }
        try? SidebarLayoutKey.last.write(to: dir.appendingPathComponent("layout.txt"),
                                          atomically: true, encoding: .utf8)
        try? written.joined(separator: "\n").write(to: marker, atomically: true, encoding: .utf8)
    }
}
#endif
