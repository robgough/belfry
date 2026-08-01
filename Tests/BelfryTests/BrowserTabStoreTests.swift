import XCTest
@testable import Belfry

@MainActor
final class BrowserTabStoreTests: XCTestCase {
    private var tempDir: URL!
    private var persistence: BrowserTabPersistence!

    override func setUp() {
        super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("belfry-browser-tests-\(UUID().uuidString)", isDirectory: true)
        persistence = BrowserTabPersistence(directory: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func makeStore() -> BrowserTabStore {
        BrowserTabStore(persistence: persistence)
    }

    private func select(_ store: BrowserTabStore, host: String = "local",
                        session: String = "$1", name: String = "belfry") -> BrowserTabStore.SessionKey {
        store.sessionSelected(hostID: host, sessionID: session, sessionName: name,
                              snapToTerminal: true)
        return BrowserTabStore.SessionKey(hostID: host, sessionID: session)
    }

    // MARK: Persistence

    func testPersistenceRoundTrip() {
        let records = [SessionTabsRecord(
            hostID: "local", sessionName: "belfry",
            tabs: [.init(url: URL(string: "https://example.com"), profileID: nil)])]
        persistence.save(records)
        XCTAssertEqual(persistence.load(), records)
    }

    func testLoadMissingFileIsEmpty() {
        XCTAssertEqual(persistence.load(), [])
    }

    // MARK: Store basics

    func testOpenTabActivatesIt() {
        let store = makeStore()
        let key = select(store)
        XCTAssertTrue(store.isTerminalActive(for: key))
        let tab = store.openTab(for: key, url: URL(string: "https://example.com"))
        XCTAssertEqual(store.active(for: key), .web(tab.id))
        XCTAssertEqual(store.tabs(for: key).count, 1)
        XCTAssertEqual(store.activeWebTab?.id, tab.id)
    }

    func testCloseSelectsNeighborThenTerminal() {
        let store = makeStore()
        let key = select(store)
        let a = store.openTab(for: key, url: URL(string: "https://a.test"))
        let b = store.openTab(for: key, url: URL(string: "https://b.test"))
        let c = store.openTab(for: key, url: URL(string: "https://c.test"))

        // Close the active middle-position tab: the one that slides into its
        // slot becomes active.
        store.setActive(.web(b.id), for: key)
        store.close(b.id, for: key)
        XCTAssertEqual(store.active(for: key), .web(c.id))

        // Closing an inactive tab leaves the active one alone.
        store.close(a.id, for: key)
        XCTAssertEqual(store.active(for: key), .web(c.id))

        // Last tab out: back to the terminal.
        store.close(c.id, for: key)
        XCTAssertEqual(store.active(for: key), .terminal)
        XCTAssertTrue(store.tabs(for: key).isEmpty)
    }

    func testCycleWrapsThroughTerminal() {
        let store = makeStore()
        let key = select(store)
        let a = store.openTab(for: key, url: URL(string: "https://a.test"))
        let b = store.openTab(for: key, url: URL(string: "https://b.test"))

        store.setActive(.terminal, for: key)
        store.cycleCurrent(1)
        XCTAssertEqual(store.active(for: key), .web(a.id))
        store.cycleCurrent(1)
        XCTAssertEqual(store.active(for: key), .web(b.id))
        store.cycleCurrent(1)
        XCTAssertEqual(store.active(for: key), .terminal)
        store.cycleCurrent(-1)
        XCTAssertEqual(store.active(for: key), .web(b.id))
    }

    func testSidebarClickSnapsToTerminalButReconnectDoesNot() {
        let store = makeStore()
        let key = select(store)
        store.openTab(for: key, url: URL(string: "https://a.test"))
        XCTAssertFalse(store.isTerminalActive(for: key))

        // Reconnect re-arm: same session, no snap.
        store.sessionSelected(hostID: key.hostID, sessionID: key.sessionID,
                              sessionName: "belfry", snapToTerminal: false)
        XCTAssertFalse(store.isTerminalActive(for: key))

        // Sidebar click: snap.
        store.sessionSelected(hostID: key.hostID, sessionID: key.sessionID,
                              sessionName: "belfry", snapToTerminal: true)
        XCTAssertTrue(store.isTerminalActive(for: key))
    }

    // MARK: Restore by name

    func testTabsRestoreBySessionNameAcrossServerRestart() {
        let url = URL(string: "http://localhost:5173")!
        do {
            let store = makeStore()
            let key = select(store, session: "$1", name: "belfry")
            store.openTab(for: key, url: url)
        }

        // New launch, new tmux server: same name, different session id.
        let store = makeStore()
        let key = select(store, session: "$7", name: "belfry")
        XCTAssertEqual(store.tabs(for: key).map(\.url), [url])
        // Restored tabs open behind the terminal, never in front of it.
        XCTAssertTrue(store.isTerminalActive(for: key))
    }

    func testSessionDiedTearsDownLiveTabsButKeepsRecord() {
        let store = makeStore()
        let key = select(store, session: "$1", name: "belfry")
        store.openTab(for: key, url: URL(string: "https://a.test"))

        store.sessionDied(hostID: "local", livingSessionIDs: ["$9"])
        XCTAssertTrue(store.tabs(for: key).isEmpty)
        XCTAssertNil(store.currentKey)
        XCTAssertFalse(store.sessionOrder.contains(key))

        // Same name comes back (new id): the record re-resolves.
        let reborn = select(store, session: "$12", name: "belfry")
        XCTAssertEqual(store.tabs(for: reborn).map(\.url),
                       [URL(string: "https://a.test")])
    }

    func testSessionDiedIsScopedToHost() {
        let store = makeStore()
        let key = select(store, host: "mini", session: "$1", name: "belfry")
        store.openTab(for: key, url: URL(string: "https://a.test"))

        // Another host's living-sessions signal must not touch mini's tabs.
        store.sessionDied(hostID: "local", livingSessionIDs: [])
        XCTAssertEqual(store.tabs(for: key).count, 1)
    }

    func testClosingLastTabRemovesPersistedRecord() {
        let store = makeStore()
        let key = select(store)
        let tab = store.openTab(for: key, url: URL(string: "https://a.test"))
        XCTAssertEqual(persistence.load().count, 1)
        store.close(tab.id, for: key)
        XCTAssertEqual(persistence.load(), [])
    }

    // MARK: Address-bar normalisation

    func testBrowserURLNormalization() {
        XCTAssertEqual(BrowserURL.normalized(from: "https://example.com")?.absoluteString,
                       "https://example.com")
        XCTAssertEqual(BrowserURL.normalized(from: "example.com")?.absoluteString,
                       "https://example.com")
        XCTAssertEqual(BrowserURL.normalized(from: "localhost:5173")?.absoluteString,
                       "http://localhost:5173")
        XCTAssertEqual(BrowserURL.normalized(from: "127.0.0.1:8080/admin")?.absoluteString,
                       "http://127.0.0.1:8080/admin")
        XCTAssertNil(BrowserURL.normalized(from: "   "))
        // Non-host input becomes a search.
        let search = BrowserURL.normalized(from: "swift concurrency")
        XCTAssertEqual(search?.host(), "www.google.com")
        XCTAssertTrue(search?.query()?.contains("swift%20concurrency") ?? false)
    }
}
