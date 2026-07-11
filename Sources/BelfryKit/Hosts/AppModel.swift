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

    /// Sessions/windows pinned to the top of the sidebar. New pins append;
    /// the user can rearrange by dragging.
    private(set) var pins: [PinnedItem]

    /// Terminal font size in points; nil = libghostty's default. Applied to all
    /// session surfaces.
    var fontSize: Double?

    init(hosts: [HostModel]) {
        self.hosts = hosts
        self.pins = PinPersistence.load()
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
        // The host is gone for good; its pins can never resolve again.
        if pins.contains(where: { $0.hostID == host.id }) {
            pins.removeAll { $0.hostID == host.id }
            PinPersistence.save(pins)
        }
    }

    // MARK: Pins

    func isSessionPinned(hostID: String, sessionID: String) -> Bool {
        pins.contains { $0.hostID == hostID && $0.sessionID == sessionID && $0.windowID == nil }
    }

    func isWindowPinned(hostID: String, windowID: String) -> Bool {
        pins.contains { $0.hostID == hostID && $0.windowID == windowID }
    }

    /// Pin the session (or remove its existing pin). New pins append, so the
    /// Pinned section keeps the order things were pinned in.
    func togglePin(host: HostModel, session: TmuxSession) {
        if isSessionPinned(hostID: host.id, sessionID: session.id) {
            pins.removeAll { $0.hostID == host.id && $0.sessionID == session.id && $0.windowID == nil }
        } else {
            pins.append(PinnedItem(
                hostID: host.id, sessionID: session.id, windowID: nil,
                sessionName: session.name, windowName: nil, windowIndex: nil))
        }
        PinPersistence.save(pins)
    }

    /// Pin the window (or remove its existing pin).
    func togglePin(host: HostModel, session: TmuxSession, window: TmuxWindow) {
        if isWindowPinned(hostID: host.id, windowID: window.id) {
            pins.removeAll { $0.hostID == host.id && $0.windowID == window.id }
        } else {
            pins.append(PinnedItem(
                hostID: host.id, sessionID: session.id, windowID: window.id,
                sessionName: session.name, windowName: window.name, windowIndex: window.index))
        }
        PinPersistence.save(pins)
    }

    func unpin(_ pin: PinnedItem) {
        pins.removeAll { $0.id == pin.id }
        PinPersistence.save(pins)
    }

    /// Reorder the Pinned section (sidebar drag-to-reorder).
    func movePins(fromOffsets source: IndexSet, toOffset destination: Int) {
        pins.move(fromOffsets: source, toOffset: destination)
        PinPersistence.save(pins)
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
