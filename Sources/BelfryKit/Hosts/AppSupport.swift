import Foundation

/// Where Belfry keeps its files (saved hosts, pins, browser tabs, shortcuts,
/// generated theme snippets): the user's Application Support directory.
///
/// Debug builds honour `BELFRY_APP_SUPPORT=<dir>` instead, so a demo or test
/// instance (screenshots, the sidebar lab) runs against its own data and never
/// reads or rewrites the real app's — `NSHomeDirectory()` ignores `$HOME`, so a
/// fake home alone doesn't isolate it.
enum AppSupport {
    static var directory: URL? {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["BELFRY_APP_SUPPORT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }

    /// Debug builds: `BELFRY_DEMO=1` marks a staged demo/screenshot instance —
    /// it leaves agent-hook management alone (that writes the real
    /// ~/.claude/settings.json and friends).
    static var isDemo: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["BELFRY_DEMO"] != nil
        #else
        return false
        #endif
    }
}
