import SwiftUI

/// `.help()` tooltips exist on macOS only; elsewhere this is a no-op.
extension View {
    @ViewBuilder
    func hoverHint(_ text: String) -> some View {
        #if os(macOS)
        help(text)
        #else
        self
        #endif
    }
}

/// A small inline text button (`.link` style on macOS, plain elsewhere).
private struct InlineLinkButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        #if os(macOS)
        Button(title, action: action).buttonStyle(.link).font(.caption)
        #else
        Button(title, action: action).font(.caption)
        #endif
    }
}

/// Left sidebar: a Host → Session → Window tree. Each host is a collapsible
/// section; sessions list their windows beneath. Window rows are the selectable
/// leaves (tagged with their host + window id). Right-click rows for actions;
/// text-entry actions raise a `SidebarPrompt`, destructive ones a `ConfirmAction`.
struct SessionTreeView: View {
    let hosts: [HostModel]
    let model: AppModel
    @Binding var selection: WindowSelection?
    @Binding var prompt: SidebarPrompt?
    @Binding var confirm: ConfirmAction?

    var body: some View {
        List(selection: $selection) {
            ForEach(hosts) { host in
                Section {
                    HostBody(host: host, model: model, prompt: $prompt, confirm: $confirm)
                } header: {
                    HostHeader(host: host, model: model, prompt: $prompt, confirm: $confirm)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(AppTheme.sidebarBackground)
        .environment(\.defaultMinListRowHeight, 26)
    }
}

private struct HostHeader: View {
    let host: HostModel
    let model: AppModel
    @Binding var prompt: SidebarPrompt?
    @Binding var confirm: ConfirmAction?

    var body: some View {
        HStack(spacing: 9) {
            HostIconChip(systemName: host.transport.isLocal ? "desktopcomputer" : "globe",
                         status: host.store.status)
            Text(host.displayName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .textCase(nil)
            Spacer(minLength: 0)
            #if os(iOS)
            // Section headers don't get long-press context menus on iOS, so the
            // host actions (Disconnect/Connect, Remove…) need a visible button.
            Menu {
                menu
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            #endif
        }
        .padding(.vertical, 4)
        .contextMenu { menu }
    }

    @ViewBuilder private var menu: some View {
        Button("New Session…") { prompt = .newSession(host: host) }
        Divider()
        claudeHooksItems
        if host.canDisconnect {
            Divider()
            switch host.store.status {
            case .connected, .connecting, .reconnecting:
                Button("Disconnect") { host.disconnect() }
            case .disconnected, .offline:
                Button("Connect") { host.reconnect() }
            }
            Button("Remove Host", role: .destructive) {
                confirm = ConfirmAction(
                    title: "Remove “\(host.displayName)”?",
                    message: "Removes the host from Belfry. Its remote sessions keep running.",
                    confirmLabel: "Remove") { model.removeHost(host) }
            }
        }
    }

    /// Claude-status-hook state + install action for this host.
    @ViewBuilder private var claudeHooksItems: some View {
        // Transports without a hooks manager (iOS, for now) hide this entirely.
        if !host.supportsHooksManagement {
            EmptyView()
        // Managing remote hooks needs the SSH link; local always works.
        } else if !(host.transport.isLocal || host.store.status.isLive) {
            Button("Claude status hooks (connect to manage)") {}.disabled(true)
        } else {
            switch host.hooksStatus {
            case .installed:
                Button { } label: { Label("Claude status hooks installed", systemImage: "checkmark.circle") }
                    .disabled(true)
                Button("Reinstall Claude Status Hooks") { host.installHooks() }
                Button("Remove Claude Status Hooks", role: .destructive) { host.removeHooks() }
            case .notInstalled:
                Button("Install Claude Status Hooks…") { host.installHooks() }
            case .checking:
                Button("Checking Claude hooks…") {}.disabled(true)
            case .installing:
                Button("Installing Claude hooks…") {}.disabled(true)
            case .removing:
                Button("Removing Claude hooks…") {}.disabled(true)
            case .error(let message):
                Button { } label: { Label(message, systemImage: "exclamationmark.triangle") }
                    .disabled(true)
                Button("Re-check Claude Hooks") { host.checkHooks() }
            case .unknown:
                Button("Check for Claude Status Hooks") { host.checkHooks() }
            }
        }
    }
}

private struct HostBody: View {
    let host: HostModel
    let model: AppModel
    @Binding var prompt: SidebarPrompt?
    @Binding var confirm: ConfirmAction?

    var body: some View {
        ForEach(host.store.sessions) { session in
            SessionHeader(session: session)
                .contextMenu { sessionMenu(session) }
            ForEach(session.windows) { window in
                WindowRow(window: window)
                    .tag(WindowSelection(hostID: host.id, windowID: window.id))
                    .contextMenu { windowMenu(session, window) }
            }
        }
        if host.store.sessions.isEmpty {
            HostStatusRow(host: host)
        }
    }

    @ViewBuilder private func sessionMenu(_ session: TmuxSession) -> some View {
        Button("New Window") { host.client.newWindow(inSession: session.id) }
        Button("Rename Session…") { prompt = .renameSession(host: host, session: session) }
        Divider()
        Button("Kill Session", role: .destructive) {
            confirm = ConfirmAction(
                title: "Kill session “\(session.name)”?",
                message: "Ends the session and all its windows on \(host.displayName).",
                confirmLabel: "Kill") { host.client.killSession(id: session.id) }
        }
    }

    @ViewBuilder private func windowMenu(_ session: TmuxSession, _ window: TmuxWindow) -> some View {
        Button("Rename Window…") { prompt = .renameWindow(host: host, window: window) }
        Button("New Window") { host.client.newWindow(inSession: session.id) }
        Divider()
        Button("Kill Window", role: .destructive) {
            confirm = ConfirmAction(
                title: "Kill window “\(window.name.isEmpty ? "window \(window.index)" : window.name)”?",
                message: "Closes the window on \(host.displayName).",
                confirmLabel: "Kill") { host.client.killWindow(id: window.id) }
        }
    }
}

/// Host icon in a status-tinted chip — anchors each host group on the left and
/// shows the connection state by colour (hover for the exact status). Replaces
/// the old far-right status dot.
private struct HostIconChip: View {
    let systemName: String
    let status: ConnectionStatus
    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(tint.opacity(0.16))
            .frame(width: 22, height: 22)
            .overlay(
                Image(systemName: systemName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
            )
            .hoverHint(statusText)
    }
    private var tint: Color {
        switch status {
        case .connected: return .green
        case .connecting, .reconnecting: return .orange
        case .disconnected: return .orange
        case .offline: return Color.secondary
        }
    }
    private var statusText: String {
        switch status {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .reconnecting(let n): return "Reconnecting… (attempt \(n))"
        case .disconnected: return "Connection lost"
        case .offline: return "Disconnected"
        }
    }
}

/// Session presence marker: solid when a client is attached, hollow when not.
private struct AttachDot: View {
    let isAttached: Bool
    var body: some View {
        Circle()
            .fill(isAttached ? Color.green : Color.clear)
            .overlay(
                Circle().strokeBorder(
                    isAttached ? Color.clear : Color.secondary.opacity(0.5),
                    lineWidth: 1.2)
            )
            .frame(width: 7, height: 7)
            .hoverHint(isAttached ? "Attached (a client is on this session)" : "Not attached")
    }
}


private struct HostStatusRow: View {
    let host: HostModel
    var body: some View {
        switch host.store.status {
        case .connecting:
            Label("Connecting…", systemImage: "ellipsis.circle")
                .font(.caption).foregroundStyle(.secondary)
        case .reconnecting(let attempt):
            Label("Reconnecting… (\(attempt))", systemImage: "arrow.clockwise")
                .font(.caption).foregroundStyle(.secondary)
        case .connected:
            Text("No sessions").font(.caption).foregroundStyle(.secondary)
        case .disconnected(let reason):
            HStack(spacing: 6) {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                InlineLinkButton(title: "Reconnect") { host.reconnect() }
            }
        case .offline:
            HStack(spacing: 6) {
                Text("Disconnected").font(.caption).foregroundStyle(.secondary)
                InlineLinkButton(title: "Connect") { host.reconnect() }
            }
        }
    }
}

private struct SessionHeader: View {
    let session: TmuxSession
    var body: some View {
        HStack(spacing: 8) {
            AttachDot(isAttached: session.isAttached)
            Text(session.name)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
        .padding(.bottom, 1)
    }
}

private struct WindowRow: View {
    let window: TmuxWindow
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: window.isActive ? "terminal.fill" : "terminal")
                .font(.system(size: 11))
                .foregroundStyle(window.isActive ? Color.accentColor : .secondary)
                .frame(width: 16)
            Text(window.name.isEmpty ? "window \(window.index)" : window.name)
                .font(.system(size: 12, weight: window.isActive ? .medium : .regular))
                .foregroundStyle(window.isActive ? .primary : .secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                if window.hasBell {
                    Image(systemName: "bell.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.yellow)
                        .hoverHint("Bell rang in this window")
                }
                if window.claudeState != .none {
                    ClaudeBadge(state: window.claudeState)
                } else if window.hasActivity {
                    Circle().fill(Color.orange).frame(width: 5, height: 5)
                        .hoverHint("Unseen activity")
                }
            }
        }
        .padding(.leading, 18)
        .padding(.vertical, 1)
    }
}

/// Per-window Claude Code status chip: an indicator plus a word, so states are legible
/// at a glance. `.working` shows a braille "processing" spinner; `.background` (Claude's
/// turn ended but background tasks/agents are still running) pulses purple as "Agents";
/// `.waiting` is an amber question mark — Claude handed the turn back and needs input.
private struct ClaudeBadge: View {
    let state: ClaudeState
    var body: some View {
        switch state {
        case .none:
            EmptyView()
        case .running:
            chip(text: "Idle", color: .secondary, weight: .regular,
                 help: "Claude is running here — install status hooks for live Working / Waiting status") {
                Image(systemName: "sparkle")
            }
        case .working:
            chip(text: "Working", color: .accentColor, weight: .medium,
                 help: "Claude is working") {
                BrailleSpinner(color: .accentColor)
            }
        case .background:
            chip(text: "Agents", color: .purple, weight: .medium,
                 help: "Claude's turn ended, but background tasks or agents are still running — it will resume on its own") {
                BrailleSpinner(color: .purple)
            }
        case .waiting:
            chip(text: "Waiting", color: .orange, weight: .semibold,
                 help: "Claude is waiting for your input") {
                PulsingIcon(systemName: "questionmark.circle.fill", color: .orange)
            }
        }
    }

    private func chip<Glyph: View>(
        text: String, color: Color, weight: Font.Weight, help: String,
        @ViewBuilder glyph: () -> Glyph
    ) -> some View {
        HStack(spacing: 3) {
            glyph()
            Text(text)
        }
        .font(.system(size: 10, weight: weight))
        .foregroundStyle(color)
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(Capsule().fill(color.opacity(0.14)))
        .hoverHint(help)
    }
}

/// The repeating badge animation, shared by both platforms: a CABasicAnimation
/// breathing a layer's opacity between 1 and 0.35.
private func makePulseAnimation() -> CABasicAnimation {
    let animation = CABasicAnimation(keyPath: "opacity")
    animation.fromValue = 1.0
    animation.toValue = 0.35
    animation.duration = 0.7
    animation.autoreverses = true
    animation.repeatCount = .infinity
    return animation
}

#if canImport(AppKit)

/// A pulsing SF Symbol, animated for free. `.symbolEffect(.pulse, .repeating)`
/// is frame-driven in-process like every per-frame SwiftUI update (measured
/// ~17% CPU for one badge); a `CABasicAnimation` on layer opacity runs
/// entirely in the render server instead.
private struct PulsingIcon: NSViewRepresentable {
    let systemName: String
    let color: Color

    func makeNSView(context: Context) -> IconView { IconView(systemName: systemName, color: NSColor(color)) }
    func updateNSView(_ nsView: IconView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: IconView, context: Context) -> CGSize? {
        IconView.iconSize
    }

    final class IconView: NSView {
        static let iconSize = NSSize(width: 12, height: 12)
        private let imageView = NSImageView()

        init(systemName: String, color: NSColor) {
            super.init(frame: NSRect(origin: .zero, size: Self.iconSize))
            wantsLayer = true
            let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
                .applying(.init(paletteColors: [color]))
            imageView.image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            imageView.frame = bounds
            imageView.autoresizingMask = [.width, .height]
            imageView.wantsLayer = true
            addSubview(imageView)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var intrinsicContentSize: NSSize { Self.iconSize }

        // CA strips animations from a layer that leaves the hierarchy, so
        // (re)install whenever we land in a window.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, let layer = imageView.layer else { return }
            guard layer.animation(forKey: "belfry.pulse") == nil else { return }
            layer.add(makePulseAnimation(), forKey: "belfry.pulse")
        }
    }
}

/// The classic braille "processing" spinner (⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏), animated for free.
///
/// Anything that updates SwiftUI state per frame (TimelineView Text swaps,
/// SF Symbol effects) re-renders the sidebar row 8–30×/sec and measured
/// 7–17% CPU while a single badge was visible. Here the ten frames are
/// rendered to images once and cycled by a `CAKeyframeAnimation` on a layer's
/// `contents` — the window server runs the loop, the app does zero per-frame
/// work, and macOS pauses it automatically when the window isn't visible.
private struct BrailleSpinner: NSViewRepresentable {
    let color: Color

    func makeNSView(context: Context) -> SpinnerView { SpinnerView(color: NSColor(color)) }
    func updateNSView(_ nsView: SpinnerView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SpinnerView, context: Context) -> CGSize? {
        SpinnerView.glyphSize
    }

    final class SpinnerView: NSView {
        private static let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
        private static let frameInterval = 0.125
        static let glyphSize = NSSize(width: 8, height: 12)
        private let images: [CGImage]

        init(color: NSColor) {
            images = Self.renderFrames(color: color)
            super.init(frame: NSRect(origin: .zero, size: Self.glyphSize))
            wantsLayer = true
            setContentHuggingPriority(.required, for: .horizontal)
            setContentHuggingPriority(.required, for: .vertical)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var intrinsicContentSize: NSSize { Self.glyphSize }

        // CA strips animations from a layer that leaves the hierarchy, so
        // (re)install whenever we land in a window.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let layer, window != nil else { return }
            layer.contentsScale = window?.backingScaleFactor ?? 2
            guard layer.animation(forKey: "belfry.spin") == nil else { return }
            let animation = CAKeyframeAnimation(keyPath: "contents")
            animation.values = images
            animation.calculationMode = .discrete
            animation.duration = Double(images.count) * Self.frameInterval
            animation.repeatCount = .infinity
            layer.add(animation, forKey: "belfry.spin")
        }

        /// Draw each braille frame once into a 2x bitmap tinted `color`.
        private static func renderFrames(color: NSColor) -> [CGImage] {
            let scale: CGFloat = 2
            let size = NSSize(width: glyphSize.width * scale, height: glyphSize.height * scale)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 10 * scale, weight: .regular),
                .foregroundColor: color,
            ]
            return frames.compactMap { glyph in
                guard let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
                ) else { return nil }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                (glyph as NSString).draw(at: .zero, withAttributes: attributes)
                NSGraphicsContext.restoreGraphicsState()
                return rep.cgImage
            }
        }
    }
}

#else  // UIKit — same render-server animations, UIView-hosted.

/// iOS twin of the macOS PulsingIcon (see that doc comment for the why).
private struct PulsingIcon: UIViewRepresentable {
    let systemName: String
    let color: Color

    func makeUIView(context: Context) -> IconView { IconView(systemName: systemName, color: UIColor(color)) }
    func updateUIView(_ uiView: IconView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: IconView, context: Context) -> CGSize? {
        IconView.iconSize
    }

    final class IconView: UIView {
        static let iconSize = CGSize(width: 12, height: 12)
        private let imageView = UIImageView()

        init(systemName: String, color: UIColor) {
            super.init(frame: CGRect(origin: .zero, size: Self.iconSize))
            let config = UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            imageView.image = UIImage(systemName: systemName, withConfiguration: config)
            imageView.tintColor = color
            imageView.contentMode = .scaleAspectFit
            imageView.frame = bounds
            imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(imageView)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var intrinsicContentSize: CGSize { Self.iconSize }

        // CA strips animations from a layer that leaves the hierarchy, so
        // (re)install whenever we land in a window.
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            let layer = imageView.layer
            guard layer.animation(forKey: "belfry.pulse") == nil else { return }
            layer.add(makePulseAnimation(), forKey: "belfry.pulse")
        }
    }
}

/// iOS twin of the macOS BrailleSpinner (see that doc comment for the why).
private struct BrailleSpinner: UIViewRepresentable {
    let color: Color

    func makeUIView(context: Context) -> SpinnerView { SpinnerView(color: UIColor(color)) }
    func updateUIView(_ uiView: SpinnerView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: SpinnerView, context: Context) -> CGSize? {
        SpinnerView.glyphSize
    }

    final class SpinnerView: UIView {
        private static let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
        private static let frameInterval = 0.125
        static let glyphSize = CGSize(width: 8, height: 12)
        private let images: [CGImage]

        init(color: UIColor) {
            images = Self.renderFrames(color: color)
            super.init(frame: CGRect(origin: .zero, size: Self.glyphSize))
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var intrinsicContentSize: CGSize { Self.glyphSize }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            layer.contentsScale = 2
            guard layer.animation(forKey: "belfry.spin") == nil else { return }
            let animation = CAKeyframeAnimation(keyPath: "contents")
            animation.values = images
            animation.calculationMode = .discrete
            animation.duration = Double(images.count) * Self.frameInterval
            animation.repeatCount = .infinity
            layer.add(animation, forKey: "belfry.spin")
        }

        /// Draw each braille frame once into a 2x bitmap tinted `color`.
        private static func renderFrames(color: UIColor) -> [CGImage] {
            let scale: CGFloat = 2
            let size = CGSize(width: glyphSize.width * scale, height: glyphSize.height * scale)
            let font = UIFont.monospacedSystemFont(ofSize: 10 * scale, weight: .regular)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = false
            let renderer = UIGraphicsImageRenderer(size: size, format: format)
            return frames.compactMap { glyph in
                renderer.image { _ in
                    (glyph as NSString).draw(
                        at: .zero,
                        withAttributes: [.font: font, .foregroundColor: color])
                }.cgImage
            }
        }
    }
}

#endif
