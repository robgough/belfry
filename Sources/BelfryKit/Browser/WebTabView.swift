#if os(macOS)
import SwiftUI
import WebKit

/// Hosts one BrowserTab's WKWebView as a layer in the detail ZStack. Like the
/// warm terminal surfaces it stays mounted while other tabs are shown — dev
/// servers keep their websockets — but web content is hidden with `isHidden`
/// rather than opacity: hidden is what makes WebKit throttle rendering and
/// rAF in background tabs while the network stays alive.
///
/// The web view sits inside a plain container view rather than being the
/// representable's view itself: the attached Web Inspector does frame
/// surgery on the inspected view and inserts its own pane beside it, and
/// the container gives that surgery a home WebKit fully owns. The inspector
/// therefore splits the tab's own layer (and hides with it on tab switches)
/// instead of colliding with SwiftUI layout. Forcing a detached window is
/// not an option — inspector window ordering throws (and kills the app) on
/// this WebKit build.
struct WebTabLayer: NSViewRepresentable {
    let tab: BrowserTab
    let store: BrowserTabStore
    let key: BrowserTabStore.SessionKey
    let isVisible: Bool

    func makeCoordinator() -> WebTabCoordinator {
        WebTabCoordinator(tab: tab, store: store, key: key)
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let isNew = tab.webView == nil
        let web = tab.webView ?? Self.makeWebView(configuration: configuration())
        context.coordinator.attach(to: web)
        if isNew {
            tab.webView = web
            if let url = tab.url { web.load(URLRequest(url: url)) }
        }
        // Config changes rebuild the layer around the same webView object —
        // re-parent it into the fresh container.
        web.removeFromSuperview()
        web.frame = container.bounds
        web.autoresizingMask = [.width, .height]
        container.addSubview(web)
        return container
    }

    /// Profile and user-agent are configuration-time; a change to either
    /// bumps the tab's configIdentity, which recreates this whole layer and
    /// lands back here with a fresh configuration.
    private func configuration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store.profiles.dataStore(for: tab.profileID)
        if tab.usesSafariUserAgent {
            configuration.applicationNameForUserAgent = Self.safariApplicationName
        }
        return configuration
    }

    /// Appended to WebKit's stock UA so the result matches Safari's. The
    /// version may need a bump when a site starts sniffing for newer.
    static let safariApplicationName = "Version/26.0 Safari/605.1.15"

    func updateNSView(_ container: NSView, context: Context) {
        container.isHidden = !isVisible
    }

    /// One place builds every web view (fresh tabs here, popups in the
    /// coordinator with WebKit's configuration): inspectable from Safari's
    /// Develop menu, swipe navigation, pinch zoom.
    static func makeWebView(
        configuration: WKWebViewConfiguration = WKWebViewConfiguration()
    ) -> WKWebView {
        // isInspectable only advertises the page to Safari's Develop menu;
        // the in-process inspector (the </> button, "Inspect Element" in the
        // context menu) needs developer extras too. KVC onto a private but
        // decades-stable WKPreferences key — the standard recipe.
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.isInspectable = true
        web.allowsBackForwardNavigationGestures = true
        web.allowsMagnification = true
        return web
    }
}

/// Navigation + UI delegate for one tab. Nonisolated NSObject; WebKit calls
/// every delegate method and KVO change on the main thread, so each hops in
/// with `MainActor.assumeIsolated`.
final class WebTabCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    private let tab: BrowserTab
    private let store: BrowserTabStore
    private let key: BrowserTabStore.SessionKey
    private var observations: [NSKeyValueObservation] = []

    init(tab: BrowserTab, store: BrowserTabStore, key: BrowserTabStore.SessionKey) {
        self.tab = tab
        self.store = store
        self.key = key
    }

    func attach(to web: WKWebView) {
        guard web.navigationDelegate !== self else { return }
        web.navigationDelegate = self
        web.uiDelegate = self
        observations = [
            web.observe(\.title) { [weak self] web, _ in
                self?.onMain { $0.tab.title = web.title ?? "" }
            },
            web.observe(\.isLoading) { [weak self] web, _ in
                self?.onMain { $0.tab.isLoading = web.isLoading }
            },
            web.observe(\.canGoBack) { [weak self] web, _ in
                self?.onMain { $0.tab.canGoBack = web.canGoBack }
            },
            web.observe(\.canGoForward) { [weak self] web, _ in
                self?.onMain { $0.tab.canGoForward = web.canGoForward }
            },
        ]
    }

    /// KVO fires on the main thread here (WKWebView's properties change on
    /// main), but the observation API is nonisolated — assert our way in.
    private func onMain(_ body: @escaping @MainActor (WebTabCoordinator) -> Void) {
        MainActor.assumeIsolated { body(self) }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            tab.url = webView.url
            store.noteNavigation(for: key)
        }
    }

    // MARK: WKUIDelegate

    /// target=_blank / window.open: open as a new tab in the same session
    /// (and, later, the same profile — the configuration carries it). The
    /// view must be built from the configuration WebKit hands us and must
    /// not load anything itself.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        MainActor.assumeIsolated {
            let popup = WebTabLayer.makeWebView(configuration: configuration)
            store.openPopup(for: key, webView: popup)
            return popup
        }
    }

    /// window.close() from a page we opened as a popup.
    func webViewDidClose(_ webView: WKWebView) {
        MainActor.assumeIsolated {
            if let closing = store.tabs(for: key).first(where: { $0.webView === webView }) {
                store.close(closing.id, for: key)
            }
        }
    }

    // JS dialogs: without these WebKit silently drops alert/confirm/prompt.
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        completionHandler(response == .alertFirstButtonReturn ? field.stringValue : nil)
    }
}
#endif
