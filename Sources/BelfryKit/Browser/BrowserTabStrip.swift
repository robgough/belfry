#if os(macOS)
import SwiftUI
import WebKit

/// The per-session tab strip along the top of the detail pane, drawn the way
/// macOS 26 draws a window's own tabs (Finder, Terminal): one full-width
/// capsule track straight under the toolbar, equal-width tabs that squeeze
/// (never scroll) with centred titles, the selected tab a raised glass pill
/// that slides between them, hairlines only between unselected neighbours,
/// and close-on-hover at the leading edge. Sitting flush under the toolbar on
/// the same surface, it reads as the toolbar's second row rather than a band
/// of its own. The terminal rides as the first tab. Rendered only when the
/// session has web tabs, so pure-terminal sessions pay zero chrome tax.
struct BrowserTabStrip: View {
    let store: BrowserTabStore
    let key: BrowserTabStore.SessionKey
    /// Refocus the terminal surface when its tab is chosen.
    let onSelectTerminal: () -> Void

    @Namespace private var pill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            tabRow
            if let tab = store.activeWebTab(for: key) {
                WebChromeRow(store: store, key: key, tab: tab)
            }
        }
        .background(AppTheme.windowBackground)
    }

    /// Position of the selected tab: 0 is the terminal, then the web tabs.
    private var activeIndex: Int {
        guard let active = store.activeWebTab(for: key)?.id else { return 0 }
        return (store.tabs(for: key).firstIndex { $0.id == active } ?? -1) + 1
    }

    private var tabRow: some View {
        let tabs = store.tabs(for: key)
        let active = activeIndex
        return HStack(spacing: 8) {
            HStack(spacing: 0) {
                TrackTab(
                    title: "Terminal",
                    systemImage: "terminal",
                    isActive: active == 0,
                    pill: pill,
                    onSelect: onSelectTerminal)
                ForEach(Array(tabs.enumerated()), id: \.element.id) { offset, tab in
                    // Between tabs `offset` and `offset + 1` (0 = terminal);
                    // the selected pill needs no line beside it.
                    TabSeparator(isHidden: active == offset || active == offset + 1)
                    TrackTab(
                        title: tab.displayTitle,
                        systemImage: "globe",
                        isLoading: tab.isLoading,
                        isActive: active == offset + 1,
                        badgeColor: tab.profileID.map { store.profiles.dotColor(for: $0) },
                        pill: pill,
                        onSelect: { store.setActive(.web(tab.id), for: key) },
                        onClose: { store.close(tab.id, for: key) })
                }
            }
            .padding(TabMetrics.inset)
            .background(TrackBackground())
            NewTabButton { store.openTab(for: key) }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85), value: active)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85), value: tabs.map(\.id))
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }
}

/// The native tab bar's proportions: a 28pt track whose pill sits 2pt in.
private enum TabMetrics {
    static let trackHeight: CGFloat = 28
    static let inset: CGFloat = 2
    static var pillHeight: CGFloat { trackHeight - 2 * inset }
}

/// The recessed capsule all the tabs share — a faint lift off the window
/// colour with a hairline along its top edge, as AppKit's tab bar has.
private struct TrackBackground: View {
    var body: some View {
        Capsule()
            .fill(Color.primary.opacity(0.085))
            .overlay(
                Capsule()
                    .strokeBorder(
                        LinearGradient(colors: [Color.primary.opacity(0.10), Color.primary.opacity(0.03)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 0.5)
            )
    }
}

/// The hairline between two unselected tabs.
private struct TabSeparator: View {
    let isHidden: Bool
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(isHidden ? 0 : 0.14))
            .frame(width: 1, height: 14)
    }
}

/// The selected tab's raised pill: Liquid Glass on macOS 26, where the
/// toolbar's buttons wear the same; a lit capsule before it.
private struct SelectedPill: View {
    var body: some View {
        if #available(macOS 26.0, *) {
            Capsule()
                .fill(.clear)
                .glassEffect(.regular, in: Capsule())
        } else {
            Capsule()
                .fill(Color.primary.opacity(0.10))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
        }
    }
}

/// One tab: centred icon and title, the close button fading in at the
/// leading edge on hover, a faint hover wash on unselected tabs.
private struct TrackTab: View {
    let title: String
    let systemImage: String
    var isLoading = false
    let isActive: Bool
    /// Profile tint dot; nil for the default profile (no dot).
    var badgeColor: Color? = nil
    let pill: Namespace.ID
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
                .font(.system(size: 12, weight: isActive ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 26)   // keeps the title clear of the close button
        .frame(maxWidth: .infinity)
        .frame(height: TabMetrics.pillHeight)
        .background {
            if isActive {
                SelectedPill()
                    .matchedGeometryEffect(id: "pill", in: pill)
            } else if hovering {
                Capsule().fill(Color.primary.opacity(0.05))
            }
        }
        .overlay(alignment: .leading) {
            if let onClose, hovering {
                CloseTabButton(action: onClose)
                    .padding(.leading, 5)
                    .transition(.opacity)
            }
        }
        .contentShape(Capsule())
        .onTapGesture(perform: onSelect)
        .onHover { over in withAnimation(.easeOut(duration: 0.12)) { hovering = over } }
        .foregroundStyle(isActive ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .help(title)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }
}

/// The tab's close "×": a small circle that lights up under the pointer.
private struct CloseTabButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.14 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Close tab (⌘W)")
        .accessibilityLabel("Close tab")
    }
}

/// "+" beside the track, in a capsule of the track's own colour so it reads
/// as part of the bar.
private struct NewTabButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: TabMetrics.trackHeight, height: TabMetrics.trackHeight)
                .background(TrackBackground())
                .overlay(Circle().fill(Color.primary.opacity(hovering ? 0.06 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("New browser tab (⌘T)")
        .accessibilityLabel("New browser tab")
    }
}

/// A borderless round chrome button the size of the tab track, lit only
/// under the pointer — tighter than `.accessoryBar`, whose own padding
/// spread back/forward/reload a thumb's width apart.
private struct ChromeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ChromeButton(configuration: configuration)
    }

    private struct ChromeButton: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(.secondary)
                .frame(width: TabMetrics.trackHeight, height: TabMetrics.trackHeight)
                .background(Circle().fill(Color.primary.opacity(
                    configuration.isPressed ? 0.14 : hovering && isEnabled ? 0.07 : 0)))
                .contentShape(Circle())
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hovering = $0 }
        }
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
            // The address field wears the tab track's capsule, so the two
            // rows of browser chrome read as one family.
            HStack(spacing: 6) {
                Image(systemName: urlFocused || tab.url == nil ? "magnifyingglass" : "globe")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                TextField("Search or enter website name", text: $urlText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($urlFocused)
                    .onSubmit(navigate)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: 640)
            .frame(height: TabMetrics.trackHeight)
            .background(TrackBackground())
            .overlay(
                Capsule()
                    .strokeBorder(AppTheme.accent.opacity(urlFocused ? 0.7 : 0), lineWidth: 1.5)
            )
            .contentShape(Capsule())
            .onTapGesture { urlFocused = true }
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
        }
        .buttonStyle(ChromeButtonStyle())
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
            .frame(height: TabMetrics.trackHeight)
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
