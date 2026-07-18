import SwiftUI
import WebKit
import UniformTypeIdentifiers

/// Rendered HTML preview. Local files load directly with read access to
/// their directory, so relative assets resolve off disk. Remote files load
/// through a custom URL scheme: WebKit resolves every relative `src`/`href`
/// against the page itself and asks our handler for the bytes, which are
/// fetched over the host's file connection on demand (and cached) — images,
/// stylesheets and scripts next to the page come along for free, with no
/// HTML parsing on our side.
struct WebPreviewContext {
    let browser: any FileBrowsing
    let hostID: String
    /// Absolute remote path of the HTML file; nil when it lives on this Mac.
    let remotePath: String?
    /// The page itself: the real path locally, the cached copy remotely.
    let localURL: URL
}

private let previewScheme = "belfry-preview"

#if os(macOS)
struct HTMLPreviewView: NSViewRepresentable {
    let web: WebPreviewContext

    func makeCoordinator() -> WebCoordinator { WebCoordinator() }

    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.makeWebView(for: web)
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.loadIfNeeded(web, in: view)
    }
}
#else
struct HTMLPreviewView: UIViewRepresentable {
    let web: WebPreviewContext

    func makeCoordinator() -> WebCoordinator { WebCoordinator() }

    func makeUIView(context: Context) -> WKWebView {
        context.coordinator.makeWebView(for: web)
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.loadIfNeeded(web, in: view)
    }
}
#endif

final class WebCoordinator {
    private var loadedKey: String?

    func makeWebView(for web: WebPreviewContext) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        if web.remotePath != nil {
            configuration.setURLSchemeHandler(
                RemoteAssetSchemeHandler(browser: web.browser, hostID: web.hostID),
                forURLScheme: previewScheme)
        }
        let view = WKWebView(frame: .zero, configuration: configuration)
        loadIfNeeded(web, in: view)
        return view
    }

    func loadIfNeeded(_ web: WebPreviewContext, in view: WKWebView) {
        let key = web.remotePath ?? web.localURL.path
        guard key != loadedKey else { return }
        loadedKey = key
        if let remotePath = web.remotePath {
            var components = URLComponents()
            components.scheme = previewScheme
            components.host = "host"
            components.path = remotePath
            if let url = components.url {
                view.load(URLRequest(url: url))
            }
        } else {
            view.loadFileURL(web.localURL,
                             allowingReadAccessTo: web.localURL.deletingLastPathComponent())
        }
    }
}

/// Serves `belfry-preview://host/<absolute remote path>` requests by pulling
/// the file from the remote host into the preview cache. Called by WebKit on
/// the main thread; replies must also arrive there, and never after `stop`.
private final class RemoteAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    private let browser: any FileBrowsing
    private let hostID: String
    private let lock = NSLock()
    private var inflight: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(browser: any FileBrowsing, hostID: String) {
        self.browser = browser
        self.hostID = hostID
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let remotePath = url.path.removingPercentEncoding ?? url.path
        let key = ObjectIdentifier(urlSchemeTask)
        let task = Task { [browser, hostID] in
            do {
                let data = try await Self.fetch(remotePath, browser: browser, hostID: hostID)
                let response = URLResponse(
                    url: url,
                    mimeType: Self.mimeType(for: remotePath),
                    expectedContentLength: data.count,
                    textEncodingName: nil)
                await MainActor.run {
                    guard self.finish(key) else { return }
                    urlSchemeTask.didReceive(response)
                    urlSchemeTask.didReceive(data)
                    urlSchemeTask.didFinish()
                }
            } catch {
                await MainActor.run {
                    guard self.finish(key) else { return }
                    urlSchemeTask.didFailWithError(error)
                }
            }
        }
        lock.lock()
        inflight[key] = task
        lock.unlock()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)
        lock.lock()
        let task = inflight.removeValue(forKey: key)
        lock.unlock()
        task?.cancel()
    }

    /// True if the task was still live (and is now consumed) — replying to a
    /// stopped task is a WebKit crash.
    private func finish(_ key: ObjectIdentifier) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return inflight.removeValue(forKey: key) != nil
    }

    private static func fetch(_ remotePath: String, browser: any FileBrowsing,
                              hostID: String) async throws -> Data {
        let entry = FileEntry(
            name: (remotePath as NSString).lastPathComponent, path: remotePath,
            isDirectory: false, isSymlink: false, size: 0, modified: .now)
        let cached = FileDestinations.previewCacheURL(hostID: hostID, entry: entry)
        if !FileManager.default.fileExists(atPath: cached.path) {
            // Straight through the browser, not TransferCenter — a page's
            // assets shouldn't flood the transfers UI.
            try await browser.download(entry, to: cached, offset: 0) { _, _ in }
        }
        return try Data(contentsOf: cached)
    }

    private static func mimeType(for path: String) -> String {
        let ext = (path as NSString).pathExtension
        return UTType(filenameExtension: ext)?.preferredMIMEType
            ?? "application/octet-stream"
    }
}
