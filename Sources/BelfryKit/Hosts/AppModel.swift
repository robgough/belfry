import Foundation

/// Owns the hosts (each with its own control-mode connection) + UI prefs, plus
/// host add/remove and persistence. Platform bootstrap code decides which
/// hosts exist at launch (macOS seeds Local + saved ssh aliases; iOS loads
/// saved library-SSH hosts) and extends this with its own add-host entry point.
@MainActor
@Observable
final class AppModel {
    /// For the app delegate's quit-time cleanup hook (macOS).
    static private(set) weak var current: AppModel?

    private(set) var hosts: [HostModel]

    /// Terminal font size in points; nil = libghostty's default. Applied to all
    /// session surfaces.
    var fontSize: Double?

    init(hosts: [HostModel]) {
        self.hosts = hosts
        AppModel.current = self
    }

    func startAll() { hosts.forEach { $0.start() } }

    /// Background/foreground lifecycle (iOS): connections are torn down while
    /// suspended — the tmux servers keep the sessions — and rebuilt on resume.
    /// Guarded so the scene-activation that follows launch (or a resume that
    /// never suspended) doesn't churn in-flight connects.
    private var isSuspended = false
    func suspendAll() {
        guard !isSuspended else { return }
        isSuspended = true
        hosts.forEach { $0.suspend() }
    }
    func resumeAll() {
        guard isSuspended else { return }
        isSuspended = false
        hosts.forEach { $0.resumeIfWanted() }
    }

    /// Hosts that can currently host a new session (their link is live).
    var connectedHosts: [HostModel] { hosts.filter { $0.store.status.isLive } }

    /// Number of windows across all hosts where Claude is waiting for you — drives
    /// the Dock badge so you notice while Belfry is in the background.
    var attentionCount: Int {
        hosts.reduce(0) { total, host in
            total + host.store.sessions.reduce(0) { sum, session in
                sum + session.windows.filter { $0.claudeState.needsAttention }.count
            }
        }
    }

    // MARK: Host management

    /// The alias is passed to ssh as its own argv element, so reject anything
    /// ssh would parse as an *option* (leading "-", e.g. "-oProxyCommand=…")
    /// or that can't be a real alias/user@host (whitespace, quotes, non-ASCII
    /// control forms). ssh has no "--" end-of-options marker, so validating
    /// here is the only guard.
    static func isValidSSHAlias(_ alias: String) -> Bool {
        guard !alias.isEmpty, !alias.hasPrefix("-") else { return false }
        return alias.allSatisfy { char in
            char.isASCII && !char.isWhitespace && char != "'" && char != "\"" && char != "\\"
        }
    }

    /// Adopt a fully-built host: append, persist, connect. Platform add-host
    /// forms construct the HostModel (they know their transport) and call this.
    @discardableResult
    func adopt(_ host: HostModel) -> HostModel? {
        guard !hosts.contains(where: { $0.id == host.id }) else { return nil }
        hosts.append(host)
        persist()
        host.start()
        return host
    }

    func removeHost(_ host: HostModel) {
        guard host.canDisconnect else { return }   // never remove Local
        host.shutdown()
        host.transport.cleanUpOnRemoval()
        hosts.removeAll { $0.id == host.id }
        persist()
    }

    private func persist() {
        let saved = hosts.compactMap { host -> SavedHost? in
            guard var entry = host.transport.savedHost else { return nil }
            entry.displayName = host.displayName
            return entry
        }
        HostPersistence.save(saved)
    }

    /// Tear down every host (called at quit / final cleanup). macOS wraps this
    /// with server-side control-session reaping (QuitCleanup).
    func shutdownAll() {
        hosts.forEach { $0.shutdown() }
    }

    // MARK: Font

    private let baseFontSize: Double = 13
    func increaseFont() { fontSize = min((fontSize ?? baseFontSize) + 1, 36) }
    func decreaseFont() { fontSize = max((fontSize ?? baseFontSize) - 1, 8) }
    // Reset to an explicit base (not nil): the nil → `reset_font_size` path in
    // Termini doesn't reliably re-apply, whereas `set_font_size` does.
    func resetFont() { fontSize = baseFontSize }
}
