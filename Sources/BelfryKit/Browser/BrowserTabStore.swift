import Foundation
import WebKit

/// App-level owner of every session's browser tabs. The sidebar stays pure
/// tmux; this store carries the orthogonal axis — which tab (terminal, or one
/// of the session's web tabs) the detail pane shows for each session.
///
/// Live tabs are keyed by host + tmux session id; persistence is keyed by
/// host + session *name* (see SessionTabsRecord). Like warm surfaces, tabs
/// materialise on first visit and are torn down when their session dies —
/// but their records survive, so they re-resolve by name.
@MainActor
@Observable
final class BrowserTabStore {
    struct SessionKey: Hashable {
        let hostID: String
        let sessionID: String
    }

    enum ActiveTab: Hashable {
        case terminal
        case web(UUID)
    }

    private let persistence: BrowserTabPersistence
    private var records: [SessionTabsRecord]

    /// Ordered keys of sessions whose tabs have been materialised, for a
    /// stable ForEach in the detail (mirror of `activatedSessionIDs`).
    private(set) var sessionOrder: [SessionKey] = []
    private var tabsByKey: [SessionKey: [BrowserTab]] = [:]
    private var activeByKey: [SessionKey: ActiveTab] = [:]
    private var nameByKey: [SessionKey: String] = [:]

    /// The session the detail pane currently shows — kept in sync by
    /// TerminalDetailView so menu commands (⌘T/⌘W/⌃Tab) know which strip
    /// they act on.
    private(set) var currentKey: SessionKey?

    /// Bumped by ⌘L (and by opening a blank tab); the chrome row focuses its
    /// URL field when it changes.
    private(set) var urlFocusToken = 0

    init(persistence: BrowserTabPersistence = BrowserTabPersistence()) {
        self.persistence = persistence
        self.records = persistence.load()
    }

    // MARK: Lookup

    func tabs(for key: SessionKey) -> [BrowserTab] { tabsByKey[key] ?? [] }

    func active(for key: SessionKey) -> ActiveTab { activeByKey[key] ?? .terminal }

    func isTerminalActive(for key: SessionKey) -> Bool { active(for: key) == .terminal }

    func activeWebTab(for key: SessionKey) -> BrowserTab? {
        guard case .web(let id) = active(for: key) else { return nil }
        return tabs(for: key).first { $0.id == id }
    }

    /// The web tab the user is looking at right now, if the current session's
    /// strip has one active — drives the title readout and menu commands.
    var activeWebTab: BrowserTab? {
        currentKey.flatMap { activeWebTab(for: $0) }
    }
    // MARK: Selection plumbing

    /// The detail pane resolved a selection. Materialises any persisted tabs
    /// for the session (matched by name) on first visit. `snapToTerminal` is
    /// true for a real selection change — a sidebar click means "show me that
    /// window" — and false for the reconnect re-arm, which must not yank the
    /// user off a web tab they were reading.
    func sessionSelected(hostID: String, sessionID: String, sessionName: String,
                         snapToTerminal: Bool) {
        let key = SessionKey(hostID: hostID, sessionID: sessionID)
        currentKey = key
        nameByKey[key] = sessionName
        if tabsByKey[key] == nil {
            let record = records.first { $0.hostID == hostID && $0.sessionName == sessionName }
            tabsByKey[key] = (record?.tabs ?? []).map {
                BrowserTab(url: $0.url, profileID: $0.profileID)
            }
            if !sessionOrder.contains(key) { sessionOrder.append(key) }
        }
        if snapToTerminal { activeByKey[key] = .terminal }
    }

    func selectionCleared() { currentKey = nil }

    // MARK: Mutations

    @discardableResult
    func openTab(for key: SessionKey, url: URL? = nil) -> BrowserTab {
        let tab = BrowserTab(url: url)
        tabsByKey[key, default: []].append(tab)
        if !sessionOrder.contains(key) { sessionOrder.append(key) }
        activeByKey[key] = .web(tab.id)
        persist(key)
        if url == nil { urlFocusToken += 1 }
        return tab
    }

    /// `target=_blank` / window.open: WebKit hands us the configuration the
    /// popup must be built from, so the tab adopts a pre-made web view.
    @discardableResult
    func openPopup(for key: SessionKey, webView: WKWebView) -> BrowserTab {
        let tab = BrowserTab()
        tab.webView = webView
        tabsByKey[key, default: []].append(tab)
        if !sessionOrder.contains(key) { sessionOrder.append(key) }
        activeByKey[key] = .web(tab.id)
        persist(key)
        return tab
    }

    func close(_ tabID: UUID, for key: SessionKey) {
        guard var list = tabsByKey[key],
              let index = list.firstIndex(where: { $0.id == tabID }) else { return }
        let tab = list.remove(at: index)
        tab.teardown()
        tabsByKey[key] = list
        if case .web(let activeID) = active(for: key), activeID == tabID {
            // Land on the neighbour that slid into this slot, else the last
            // tab, else back to the terminal.
            if list.isEmpty {
                activeByKey[key] = .terminal
            } else {
                activeByKey[key] = .web(list[min(index, list.count - 1)].id)
            }
        }
        persist(key)
    }

    func setActive(_ active: ActiveTab, for key: SessionKey) {
        activeByKey[key] = active
    }

    // MARK: Menu-command entry points (act on the current session)

    func openTabInCurrent() {
        guard let key = currentKey else { return }
        openTab(for: key)
    }

    func closeActiveTab() {
        guard let key = currentKey, case .web(let id) = active(for: key) else { return }
        close(id, for: key)
    }

    /// ⌃Tab / ⌃⇧Tab: cycle through [terminal, web tabs…], wrapping.
    func cycleCurrent(_ delta: Int) {
        guard let key = currentKey else { return }
        let list = tabs(for: key)
        guard !list.isEmpty else { return }
        let count = list.count + 1
        let position: Int
        switch active(for: key) {
        case .terminal:
            position = 0
        case .web(let id):
            position = (list.firstIndex { $0.id == id }.map { $0 + 1 }) ?? 0
        }
        let next = ((position + delta) % count + count) % count
        activeByKey[key] = next == 0 ? .terminal : .web(list[next - 1].id)
    }

    func focusURLField() { urlFocusToken += 1 }

    /// A tab committed a navigation — its URL is part of the persisted record.
    func noteNavigation(for key: SessionKey) { persist(key) }

    // MARK: Lifecycle

    /// Mirror of `SessionSurfaceStore.prune`: tear down live web views whose
    /// session no longer exists on this host. Their records stay — like a pin
    /// re-resolving by name, the tabs come back if the session name reappears.
    func sessionDied(hostID: String, livingSessionIDs: Set<String>) {
        let dead = sessionOrder.filter {
            $0.hostID == hostID && !livingSessionIDs.contains($0.sessionID)
        }
        guard !dead.isEmpty else { return }
        for key in dead {
            tabsByKey[key]?.forEach { $0.teardown() }
            tabsByKey[key] = nil
            activeByKey[key] = nil
            nameByKey[key] = nil
            if currentKey == key { currentKey = nil }
        }
        sessionOrder.removeAll { dead.contains($0) }
    }

    private func persist(_ key: SessionKey) {
        guard let name = nameByKey[key] else { return }
        records.removeAll { $0.hostID == key.hostID && $0.sessionName == name }
        let list = tabs(for: key)
        if !list.isEmpty {
            records.append(SessionTabsRecord(
                hostID: key.hostID, sessionName: name,
                tabs: list.map { .init(url: $0.url, profileID: $0.profileID) }))
        }
        persistence.save(records)
    }
}
