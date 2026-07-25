import QuickLook
import SwiftUI
import TerminiSSH
import UIKit
import WebKit

// Long-press previews for terminal output: `localhost:5173` opens through a
// real SSH local forward in an embedded web view (WebSockets/HMR work — it's
// `ssh -L` under the hood); file paths download and open in Quick Look.

/// Identifiable wrapper so a parsed candidate can drive `.sheet(item:)`.
struct PresentedPreview: Identifiable {
    let id = UUID()
    let candidate: PreviewCandidate
}

struct TerminalPreviewSheet: View {
    let candidate: PreviewCandidate
    let context: DockContext

    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .loading
    @State private var forward: TerminiSSHLocalForward?

    enum Phase {
        case loading
        case web(URL)
        case file(URL)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    if case .web(let url) = phase {
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                UIApplication.shared.open(url)
                            } label: {
                                Image(systemName: "safari")
                            }
                        }
                    }
                }
        }
        .task { await load() }
        .onDisappear { forward?.close() }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .loading:
            ProgressView("Connecting…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .web(let url):
            ForwardedWebView(url: url)
                .ignoresSafeArea(edges: .bottom)
        case .file(let url):
            QuickLookPreview(url: url)
                .ignoresSafeArea(edges: .bottom)
        case .failed(let message):
            ContentUnavailableView {
                Label("Can't Preview", systemImage: "eye.slash")
            } description: {
                Text(message)
            }
        }
    }

    private var title: String {
        switch candidate {
        case .localhost(_, let port, _, _): "localhost:\(port)"
        case .remoteFile(let path): (path as NSString).lastPathComponent
        case .webURL(let url): url.host() ?? "Link"
        }
    }

    private func load() async {
        switch candidate {
        case .localhost(let targetHost, let port, _, let pathQuery):
            do {
                let forward = try await context.openForward(targetHost, port)
                self.forward = forward
                // The page is always fetched over plain http through the
                // tunnel — TLS-terminating dev servers are rare, and the SSH
                // leg provides the transport security that matters here.
                guard let url = URL(string: "http://127.0.0.1:\(forward.localPort)\(pathQuery)") else {
                    phase = .failed("Bad URL.")
                    return
                }
                phase = .web(url)
            } catch {
                phase = .failed("Couldn't open a tunnel: \(error.localizedDescription)")
            }
        case .remoteFile(let path):
            do {
                let name = (path as NSString).lastPathComponent
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("belfry-preview/\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let local = dir.appendingPathComponent(name)
                let entry = FileEntry(name: name, path: path, isDirectory: false,
                                      isSymlink: false, size: 0, modified: .now)
                try await context.browser.download(entry, to: local, offset: 0) { _, _ in }
                phase = .file(Self.retypedForQuickLook(local))
            } catch {
                phase = .failed(error.localizedDescription)
            }
        case .webURL(let url):
            // Normally opened externally before presenting; cover the direct case.
            phase = .web(url)
        }
    }

    /// Quick Look refuses extensionless files it can't sniff; probe for text
    /// and give it a `.txt` suffix so logs/configs render.
    private static func retypedForQuickLook(_ url: URL) -> URL {
        guard url.pathExtension.isEmpty,
              let handle = try? FileHandle(forReadingFrom: url) else { return url }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4096), !head.isEmpty,
              !head.contains(0),
              String(data: head, encoding: .utf8) != nil else { return url }
        let retyped = url.appendingPathExtension("txt")
        return (try? FileManager.default.moveItem(at: url, to: retyped)) != nil ? retyped : url
    }
}

// MARK: - Web view over the forward

private struct ForwardedWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(origin: url) }

    /// Same-origin loads stay in the preview; a deliberate tap on an external
    /// http(s) link opens Safari (it wouldn't resolve through the tunnel).
    final class Coordinator: NSObject, WKNavigationDelegate {
        private let origin: URL
        init(origin: URL) { self.origin = origin }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let target = navigationAction.request.url else { return .cancel }
            if target.host() == origin.host(), target.port == origin.port {
                return .allow
            }
            if navigationAction.navigationType == .linkActivated,
               let scheme = target.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                await UIApplication.shared.open(target)
            }
            return .cancel
        }
    }
}

// MARK: - Quick Look

private struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        private let url: URL
        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
