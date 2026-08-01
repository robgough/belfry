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
                        badgeColor: tab.profileID.map { store.profiles.dotColor(for: $0) },
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
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 24)
                    .contentShape(Rectangle())
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
    /// Profile tint dot; nil for the default profile (no dot).
    var badgeColor: Color? = nil
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
            if let badgeColor {
                Circle()
                    .fill(badgeColor)
                    .frame(width: 6, height: 6)
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
        HStack(spacing: 4) {
            navButton("chevron.left", help: "Back", disabled: !tab.canGoBack) {
                tab.webView?.goBack()
            }
            navButton("chevron.right", help: "Forward", disabled: !tab.canGoForward) {
                tab.webView?.goForward()
            }
            navButton(tab.isLoading ? "xmark" : "arrow.clockwise",
                      help: tab.isLoading ? "Stop" : "Reload",
                      disabled: tab.url == nil) {
                if tab.isLoading { tab.webView?.stopLoading() } else { tab.webView?.reload() }
            }
            ProfileMenu(store: store, key: key, tab: tab)
            Spacer(minLength: 12)
            TextField("Search or enter website name", text: $urlText)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .font(.system(size: 13))
                .frame(maxWidth: 640)
                .focused($urlFocused)
                .onSubmit(navigate)
            Spacer(minLength: 12)
            navButton("chevron.left.forwardslash.chevron.right",
                      help: "Open Web Inspector", disabled: tab.webView == nil) {
                tab.webView.map(openInspector)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
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

    /// There is no public API to summon the Web Inspector — only
    /// `isInspectable` plus Safari's Develop menu. `_inspector` (a
    /// `_WKInspector`) has been stable for years and this app is neither
    /// sandboxed nor App Store-bound, so use it — behind responds(to:)
    /// checks so a future WebKit merely lands in the fallback alert rather
    /// than crashing.
    private func openInspector(_ webView: WKWebView) {
        let getter = Selector(("_inspector"))
        let show = Selector(("show"))
        if webView.responds(to: getter),
           let inspector = webView.perform(getter)?.takeUnretainedValue() as? NSObject,
           inspector.responds(to: show) {
            // Opens in whichever mode WebKit last remembers, Safari-style.
            // Docked mode splits inside this tab's own container layer (see
            // WebTabLayer) so it follows the tab and hides with it; detached
            // is a window per tab. Both are safe — but never resurrect the
            // _setInspectorAttachmentView(nil) trick to force one mode: a
            // window opened with no attachment view crashes AppKit's window
            // ordering (uncaught ObjC exception in makeKeyAndOrderFront).
            inspector.perform(show)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Web Inspector couldn’t be opened directly"
        alert.informativeText = "Right-click the page and choose “Inspect Element”, "
            + "or use Safari’s Develop menu."
        alert.runModal()
    }

    /// A hover-highlighted bar button with a real click target, not just
    /// the glyph's own bounds.
    private func navButton(_ symbol: String, help: String, disabled: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.accessoryBar)
        .disabled(disabled)
        .help(help)
    }
}

private extension ProfileColor {
    var swatch: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .teal: .teal
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .brown: .brown
        }
    }
}

private extension BrowserProfileStore {
    /// A profile's dot tint: its chosen palette colour, or (for profiles
    /// saved before colours existed) the stable id-derived hue.
    func dotColor(for id: UUID) -> Color {
        if let color = profile(for: id)?.color { return color.swatch }
        return Color(hue: Self.hue(for: id), saturation: 0.65, brightness: 0.85)
    }

    /// AppKit twin of `dotColor` for menu-item swatch images.
    func dotNSColor(for profile: BrowserProfile) -> NSColor {
        switch profile.color {
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .teal: .systemTeal
        case .blue: .systemBlue
        case .indigo: .systemIndigo
        case .purple: .systemPurple
        case .pink: .systemPink
        case .brown: .systemBrown
        case nil: NSColor(calibratedHue: Self.hue(for: profile.id),
                          saturation: 0.65, brightness: 0.85, alpha: 1)
        }
    }
}

/// Menu items flatten SwiftUI foreground styles to template images, so the
/// profile dropdown's dots are pre-tinted NSImages — the Finder-tags
/// technique. `isTemplate` stays false so AppKit keeps the colour.
private func swatchImage(_ color: NSColor?) -> NSImage {
    let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
        let dot = NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2))
        if let color {
            color.setFill()
            dot.fill()
        } else {
            // "Default" gets a hollow ring: aligned with the others, but
            // clearly not a silo of its own.
            NSColor.secondaryLabelColor.setStroke()
            dot.lineWidth = 1
            dot.stroke()
        }
        return true
    }
    image.isTemplate = false
    return image
}

/// The active tab's profile switcher: pick a silo, create/edit/delete
/// profiles, and toggle the Safari user-agent masquerade.
private struct ProfileMenu: View {
    let store: BrowserTabStore
    let key: BrowserTabStore.SessionKey
    let tab: BrowserTab

    /// Sheet target: nil profile = create a new one.
    private struct EditorTarget: Identifiable {
        let id = UUID()
        let profile: BrowserProfile?
    }
    @State private var editorTarget: EditorTarget?

    var body: some View {
        Menu {
            Picker("Profile", selection: Binding(
                get: { tab.profileID },
                set: { store.setProfile($0, for: tab.id, in: key) })) {
                Label {
                    Text("Default")
                } icon: {
                    Image(nsImage: swatchImage(nil))
                }
                .tag(UUID?.none)
                ForEach(store.profiles.profiles) { profile in
                    Label {
                        Text(profile.name)
                    } icon: {
                        Image(nsImage: swatchImage(store.profiles.dotNSColor(for: profile)))
                    }
                    .tag(Optional(profile.id))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Button("New Profile…") { editorTarget = EditorTarget(profile: nil) }
            if let id = tab.profileID, let profile = store.profiles.profile(for: id) {
                Button("Edit “\(profile.name)”…") { editorTarget = EditorTarget(profile: profile) }
                Button("Delete “\(profile.name)”…", role: .destructive) {
                    confirmDelete(id)
                }
            }
            Divider()
            Toggle("Use Safari User Agent", isOn: Binding(
                get: { tab.usesSafariUserAgent },
                set: { store.setSafariUserAgent($0, for: tab.id, in: key) }))
        } label: {
            // The full profile name, not an inscrutable icon: whose cookies
            // this tab is browsing with is exactly the thing you need to
            // glance at when testing as two users.
            HStack(spacing: 6) {
                if let id = tab.profileID {
                    Circle()
                        .fill(store.profiles.dotColor(for: id))
                        .frame(width: 8, height: 8)
                } else {
                    Circle()
                        .strokeBorder(.secondary, lineWidth: 1)
                        .frame(width: 8, height: 8)
                }
                Text(store.profiles.name(for: tab.profileID))
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 6)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.accessoryBar)
        .fixedSize()
        .help("Tabs on the same profile share cookies and logins")
        .sheet(item: $editorTarget) { target in
            ProfileEditorSheet(store: store, key: key, tab: tab, existing: target.profile)
        }
    }

    private func confirmDelete(_ id: UUID) {
        let alert = NSAlert()
        alert.messageText = "Delete profile “\(store.profiles.name(for: id))”?"
        alert.informativeText = "Its cookies and logins are removed from disk. "
            + "Tabs using it revert to the Default profile."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.deleteProfile(id)
    }
}

/// Create/edit a profile: name plus a Finder-tag-style swatch row. Creating
/// from here also moves the current tab into the new profile.
private struct ProfileEditorSheet: View {
    let store: BrowserTabStore
    let key: BrowserTabStore.SessionKey
    let tab: BrowserTab
    let existing: BrowserProfile?

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var color: ProfileColor
    @FocusState private var nameFocused: Bool

    init(store: BrowserTabStore, key: BrowserTabStore.SessionKey,
         tab: BrowserTab, existing: BrowserProfile?) {
        self.store = store
        self.key = key
        self.tab = tab
        self.existing = existing
        _name = State(initialValue: existing?.name ?? "")
        _color = State(initialValue: existing?.color ?? store.profiles.nextColor())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(existing == nil ? "New Profile" : "Edit Profile")
                .font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onSubmit(save)
            HStack(spacing: 10) {
                ForEach(ProfileColor.allCases, id: \.self) { candidate in
                    Circle()
                        .fill(candidate.swatch)
                        .frame(width: 18, height: 18)
                        .overlay(
                            Circle()
                                .strokeBorder(.primary.opacity(candidate == color ? 0.8 : 0),
                                              lineWidth: 2)
                                .padding(-3)
                        )
                        .contentShape(Circle().inset(by: -4))
                        .onTapGesture { color = candidate }
                        .accessibilityLabel(candidate.rawValue)
                }
            }
            if existing == nil {
                Text("Tabs on the same profile share cookies and logins; different profiles are isolated.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(existing == nil ? "Create" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear { nameFocused = true }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if var profile = existing {
            profile.name = trimmed
            profile.color = color
            store.profiles.update(profile)
        } else {
            let profile = store.profiles.create(name: trimmed, color: color)
            store.setProfile(profile.id, for: tab.id, in: key)
        }
        dismiss()
    }
}
#endif
