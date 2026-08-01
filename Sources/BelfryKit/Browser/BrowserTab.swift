import Foundation
import WebKit

/// One browser tab in a session's tab strip. Owns its WKWebView — created
/// lazily by the first display (or adopted pre-made on the `target=_blank`
/// popup path, where WebKit dictates the configuration) — and mirrors the
/// chrome state the strip renders.
@MainActor
@Observable
final class BrowserTab: Identifiable {
    let id: UUID
    /// Last committed URL; nil for a fresh tab awaiting its first address.
    /// Also what persistence records, so restored tabs reload where they were.
    var url: URL?
    /// Reserved for multi-profile support; nil = the default profile.
    var profileID: UUID?

    // Chrome state, mirrored from the web view by its coordinator.
    var title = ""
    var isLoading = false
    var canGoBack = false
    var canGoForward = false

    var webView: WKWebView?

    init(id: UUID = UUID(), url: URL? = nil, profileID: UUID? = nil) {
        self.id = id
        self.url = url
        self.profileID = profileID
    }

    /// Chip label: page title, else the host it's pointed at, else a placeholder.
    var displayTitle: String {
        if !title.isEmpty { return title }
        if let host = url?.host() { return host }
        return "New Tab"
    }

    /// Drop the live web view (closing the tab / its session died). The tab
    /// object may outlive this — a restored record re-creates the view later.
    func teardown() {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView = nil
    }
}

/// Turns address-bar input into something loadable: explicit schemes pass
/// through, bare hosts get https:// (http:// for localhost — dev servers
/// don't speak TLS), and anything that doesn't look like a host becomes a
/// web search.
enum BrowserURL {
    static func normalized(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") { return URL(string: trimmed) }
        let hostPart = trimmed.prefix { $0 != "/" && $0 != ":" }
        let isLocal = hostPart == "localhost" || hostPart == "127.0.0.1"
        let looksLikeHost = !trimmed.contains(" ") && (hostPart.contains(".") || isLocal)
        guard looksLikeHost else {
            var components = URLComponents(string: "https://www.google.com/search")!
            components.queryItems = [URLQueryItem(name: "q", value: trimmed)]
            return components.url
        }
        return URL(string: (isLocal ? "http://" : "https://") + trimmed)
    }
}
