#if os(macOS)
import SwiftUI
import WebKit

/// The per-session tab strip along the top of the detail pane. Safari's
/// layout — equal-width tabs that squeeze (never scroll), centred titles,
/// close-on-hover at the leading edge — drawn in the app's ghostty-derived
/// theme so it reads as part of Belfry, not a foreign toolbar. The terminal
/// rides as a narrow pinned-style first tab. Rendered only when the session
/// has web tabs, so pure-terminal sessions pay zero chrome tax.
struct BrowserTabStrip: View {
    let store: BrowserTabStore
    let key: BrowserTabStore.SessionKey
    /// Refocus the terminal surface when its tab is chosen.
    let onSelectTerminal: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            tabRow
            if let tab = store.activeWebTab(for: key) {
                WebChromeRow(store: store, key: key, tab: tab)
            }
            Divider()
        }
        .background(AppTheme.windowBackground)
    }

    private var tabRow: some View {
        let tabs = store.tabs(for: key)
        return HStack(spacing: 4) {
            NativeTab(
                title: "Terminal",
                systemImage: "terminal",
                isActive: store.isTerminalActive(for: key),
                flexible: false,
                onSelect: onSelectTerminal)
            HStack(spacing: 4) {
                ForEach(tabs) { tab in
                    NativeTab(
                        title: tab.displayTitle,
                        systemImage: "globe",
                        isLoading: tab.isLoading,
                        isActive: store.activeWebTab(for: key)?.id == tab.id,
                        onSelect: { store.setActive(.web(tab.id), for: key) },
                        onClose: { store.close(tab.id, for: key) })
                }
            }
            // Safari sizing: tabs share the row equally up to a cap, and
            // compress together (titles truncate) instead of scrolling.
            .frame(maxWidth: CGFloat(tabs.count) * 200, alignment: .leading)
            Button {
                store.openTab(for: key)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.accessoryBar)
            .help("New browser tab (⌘T)")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

/// One tab: centred icon+title, themed hover/active background (the same
/// panel treatment as the title-bar readout), the close button fading in at
/// the leading edge on hover.
private struct NativeTab: View {
    let title: String
    let systemImage: String
    var isLoading = false
    let isActive: Bool
    var flexible = true
    let onSelect: () -> Void
    var onClose: (() -> Void)? = nil

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            if isLoading {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 22)   // keeps the title clear of the close button
        .frame(maxWidth: flexible ? .infinity : nil)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isActive ? AppTheme.sidebarPanel
                      : hovering ? AppTheme.sidebarPanel.opacity(0.5) : .clear)
        )
        .overlay(
            // The same hairline the title-bar readout wears, so active-tab
            // and readout read as one family of panels.
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isActive ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                              lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            if let onClose, hovering {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .padding(.leading, 7)
                .help("Close tab (⌘W)")
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .foregroundStyle(isActive ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .help(title)
    }
}

/// Back/forward/reload and the address field for the active web tab.
private struct WebChromeRow: View {
    let store: BrowserTabStore
    let key: BrowserTabStore.SessionKey
    let tab: BrowserTab

    @State private var urlText = ""
    @FocusState private var urlFocused: Bool

    var body: some View {
        HStack(spacing: 2) {
            Button { tab.webView?.goBack() } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!tab.canGoBack)
            .help("Back")
            Button { tab.webView?.goForward() } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!tab.canGoForward)
            .help("Forward")
            Button {
                if tab.isLoading { tab.webView?.stopLoading() } else { tab.webView?.reload() }
            } label: {
                Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise")
            }
            .disabled(tab.url == nil)
            .help(tab.isLoading ? "Stop" : "Reload")

            Spacer(minLength: 12)
            TextField("Search or enter website name", text: $urlText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .frame(maxWidth: 560)
                .focused($urlFocused)
                .onSubmit(navigate)
            Spacer(minLength: 12)
        }
        .buttonStyle(.accessoryBar)
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        .onAppear {
            urlText = tab.url?.absoluteString ?? ""
            if tab.url == nil { urlFocused = true }
        }
        // Switching tabs reuses this row; refresh the field for the new tab.
        .onChange(of: tab.id) { _, _ in
            urlText = tab.url?.absoluteString ?? ""
            if tab.url == nil { urlFocused = true }
        }
        // Follow in-page navigations, but never while the user is typing.
        .onChange(of: tab.url) { _, new in
            if !urlFocused { urlText = new?.absoluteString ?? "" }
        }
        .onChange(of: store.urlFocusToken) { _, _ in
            urlFocused = true
        }
    }

    private func navigate() {
        guard let url = BrowserURL.normalized(from: urlText) else { return }
        tab.url = url
        tab.webView?.load(URLRequest(url: url))
        urlFocused = false
    }
}
#endif
