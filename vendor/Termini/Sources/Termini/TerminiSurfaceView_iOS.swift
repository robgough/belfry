#if canImport(UIKit)

import SwiftUI
import UIKit
import GhosttyKit

/// SwiftUI wrapper that embeds the live Ghostty surface on iOS.
public struct TerminiSurfaceView: UIViewRepresentable {
    private let controller: TerminiTerminalController?
    private let showsSystemKeyboard: Bool
    private let appearance: TerminiTerminalAppearance

    public init(
        controller: TerminiTerminalController? = nil,
        showsSystemKeyboard: Bool = true,
        appearance: TerminiTerminalAppearance = .default,
        isRenderVisible: Bool = true   // Sessionator patch: macOS-only render gate; ignored on iOS
    ) {
        self.controller = controller
        self.showsSystemKeyboard = showsSystemKeyboard
        self.appearance = appearance
    }

    public init(
        controller: TerminiTerminalController? = nil,
        showsSystemKeyboard: Bool = true,
        fontSize: Double? = nil
    ) {
        self.init(
            controller: controller,
            showsSystemKeyboard: showsSystemKeyboard,
            appearance: .init(fontSize: fontSize)
        )
    }

    public func makeUIView(context: Context) -> SurfaceContainerView {
        let view = SurfaceContainerView(runtime: .shared)
        view.showsSystemKeyboard = showsSystemKeyboard
        view.terminalAppearance = appearance
        view.bind(controller: controller)
        return view
    }

    public func updateUIView(_ uiView: SurfaceContainerView, context: Context) {
        uiView.showsSystemKeyboard = showsSystemKeyboard
        uiView.terminalAppearance = appearance
        uiView.bind(controller: controller)
    }
}

/// UIView subclass that hosts the Ghostty surface and forwards basic iOS input.
/// Belfry patch: `open` (was `public final`) so the app layer can subclass it
/// with its touch UX (focus discipline, gestures, text-input shims).
open class SurfaceContainerView: UIView, UIKeyInput, UITextInputTraits, UIGestureRecognizerDelegate {
    private let runtime: TerminiRuntime
    private var surface: ghostty_surface_t?
    /// Set once the surface has been created and ticked. Until then, terminal
    /// output is buffered rather than handed to `ghostty_surface_process_output`,
    /// which blocks the main thread on an un-ticked surface (the tick that drains
    /// it also runs on the main thread).
    private var surfaceIOReady = false
    private var pendingOutput = Data()
    // MARK: Sessionator patch — off-main output feed (deadlock fix).
    /// Serial queue that hands terminal output to libghostty. See the macOS
    /// SurfaceContainerView for the full story: `ghostty_surface_process_output`
    /// blocks when a burst generates more host notifications than ghostty's
    /// 64-slot app mailbox holds, and only a main-thread `ghostty_app_tick`
    /// drains it — feeding on the main thread could therefore deadlock.
    private let outputFeedQueue = DispatchQueue(label: "dev.arach.Termini.surface-output-feed")
    private var renderLink: CADisplayLink?
    private weak var controller: TerminiTerminalController?
    private var lastReportedSize: TerminiTerminalSize?
    private lazy var suppressedInputView = UIView(frame: .zero)
    private lazy var scrollPanGestureRecognizer: UIPanGestureRecognizer = {
        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handleScrollPan(_:)))
        recognizer.minimumNumberOfTouches = 2
        recognizer.maximumNumberOfTouches = 3
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = self
        return recognizer
    }()

    public var keyboardType: UIKeyboardType = .asciiCapable
    public var autocorrectionType: UITextAutocorrectionType = .no
    public var autocapitalizationType: UITextAutocapitalizationType = .none
    public var spellCheckingType: UITextSpellCheckingType = .no
    public var smartQuotesType: UITextSmartQuotesType = .no
    public var smartDashesType: UITextSmartDashesType = .no
    public var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    public var enablesReturnKeyAutomatically: Bool = false
    private var lastAppliedAppearance: TerminiTerminalAppearance = .default
    public var terminalAppearance: TerminiTerminalAppearance = .default {
        didSet {
            guard oldValue != terminalAppearance else { return }
            updateBackgroundColor()
            applyTerminalAppearanceIfNeeded(force: false)
        }
    }
    public var showsSystemKeyboard = true {
        didSet {
            guard oldValue != showsSystemKeyboard else { return }
            reloadInputViews()
        }
    }

    // MARK: Belfry patch — keyboard discipline + render gating.
    /// When false, attaching to a window does not grab first responder (which
    /// would summon the system keyboard). Hosts with manual keyboard UX
    /// (Belfry: keyboard appears on tap or toolbar toggle only) opt out;
    /// upstream call sites keep the auto-focus default.
    public var autoFocusOnAttach = true

    /// When false, touching the surface does not grab first responder either —
    /// hosts that distinguish taps (focus) from pans (scrollback, where a
    /// keyboard popping up mid-read is exactly wrong) opt out and install
    /// their own tap recognizer. Default preserves upstream behavior.
    public var focusOnTouch = true

    /// When false, hardware key presses are NOT forwarded into ghostty's key
    /// API here — they fall through to UIKit (and the host's own overrides).
    /// Belfry routes hardware keys itself: the blanket forward-and-claim
    /// approach ate Return and Ctrl chords on real iPad keyboards.
    public var forwardsHardwareKeys = true

    /// iOS twin of the macOS `isRenderVisible` patch: a warm-but-hidden
    /// surface keeps absorbing output (terminal state stays current) but
    /// stops drawing — no display-link frames, renderer marked occluded —
    /// with one catch-up draw on reveal.
    public var isRenderVisible = true {
        didSet {
            guard oldValue != isRenderVisible else { return }
            renderLink?.isPaused = !isRenderVisible
            if let surface {
                ghostty_surface_set_occlusion(surface, isRenderVisible)
            }
            if isRenderVisible, needsDrawOnReveal {
                needsDrawOnReveal = false
                drawAfterRemoteOutput()
            }
        }
    }
    private var needsDrawOnReveal = false

    /// The renderer reported unhealthy and the surface was rebuilt (fresh
    /// terminal state — libghostty has no terminal/surface split, so content
    /// is lost). The host should ask the remote to repaint, e.g. a tmux
    /// winsize nudge.
    public var onRendererRebuild: (() -> Void)?

    public var hasText: Bool { true }

    open override var inputView: UIView? {
        showsSystemKeyboard ? nil : suppressedInputView
    }

    public override class var layerClass: AnyClass {
        CAMetalLayer.self
    }

    init(runtime: TerminiRuntime) {
        self.runtime = runtime
        // Ghostty expects a non-zero host view so its internal IOSurface layer can size itself.
        super.init(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        commonInit()
    }

    // MARK: Belfry patch — public creation for host-owned views.
    /// Hosts that keep one persistent surface per session and re-parent it
    /// across SwiftUI remounts (Belfry's warm session cache) own the view
    /// directly instead of letting a representable create it. Public and
    /// designated so app-side subclasses (gesture/input layers) can chain to it.
    public init() {
        self.runtime = .shared
        super.init(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        commonInit()
    }

    private func commonInit() {
        updateBackgroundColor()
        isOpaque = true
        contentScaleFactor = UIScreen.main.scale
        isMultipleTouchEnabled = true
        addGestureRecognizer(scrollPanGestureRecognizer)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    open override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard terminalAppearance.theme == nil else { return }
        guard previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle else { return }
        applyTerminalAppearanceIfNeeded(force: true)
    }

    deinit {
        renderLink?.invalidate()
        if let surface {
            ghostty_surface_free(surface)
        }
    }

    open override func didMoveToWindow() {
        super.didMoveToWindow()
        createSurfaceIfNeeded()
        synchronizeGhosttyLayerGeometry()
        updateSurfaceSize()
        startRenderLoopIfNeeded()
        renderLink?.isPaused = !isRenderVisible   // Belfry patch: honour gating from the start
        guard autoFocusOnAttach else { return }   // Belfry patch: manual keyboard UX
        Task { @MainActor in
            _ = self.becomeFirstResponder()
        }
    }

    open override func layoutSubviews() {
        super.layoutSubviews()
        synchronizeGhosttyLayerGeometry()
        updateSurfaceSize()
    }

    open override var canBecomeFirstResponder: Bool { true }

    @discardableResult
    open override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        setSurfaceFocus(true)
        runtime.keyboardDidChange()
        return ok
    }

    @discardableResult
    open override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        setSurfaceFocus(false)
        return ok
    }

    open override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        guard focusOnTouch else { return }   // Belfry patch: tap-vs-pan focus
        _ = becomeFirstResponder()
    }

    @objc
    private func handleScrollPan(_ gesture: UIPanGestureRecognizer) {
        guard let surface else { return }

        let translation = gesture.translation(in: self)
        let scale = window?.screen.scale ?? UIScreen.main.scale
        let precisionMultiplier = 8.0

        switch gesture.state {
        case .began:
            _ = becomeFirstResponder()
            gesture.setTranslation(.zero, in: self)

        case .changed:
            // UIPanGestureRecognizer reports movement in points. Ghostty expects
            // precision scroll input in pixels, so convert using the display scale.
            let deltaX = translation.x * scale * precisionMultiplier
            let deltaY = translation.y * scale * precisionMultiplier
            guard abs(deltaX) > 0 || abs(deltaY) > 0 else { return }

            ghostty_surface_mouse_scroll(
                surface,
                Double(deltaX),
                Double(deltaY),
                ghostty_input_scroll_mods_t(0b0000_0001)
            )
            gesture.setTranslation(.zero, in: self)

        case .ended, .cancelled, .failed:
            gesture.setTranslation(.zero, in: self)

        default:
            break
        }
    }

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    open override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if forward(presses: presses, action: GHOSTTY_ACTION_PRESS) {
            return
        }
        super.pressesBegan(presses, with: event)
    }

    open override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if forward(presses: presses, action: GHOSTTY_ACTION_RELEASE) {
            return
        }
        super.pressesEnded(presses, with: event)
    }

    open override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if forward(presses: presses, action: GHOSTTY_ACTION_RELEASE) {
            return
        }
        super.pressesCancelled(presses, with: event)
    }

    open func insertText(_ text: String) {
        if controller?.forwardInputText(text) == true {
            return
        }
        sendText(text)
    }

    open func deleteBackward() {
        if controller?.forwardDeleteBackward() == true {
            return
        }
        sendText("\u{7F}")
    }

    private func startRenderLoopIfNeeded() {
        guard renderLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(drawFrame))
        link.add(to: .main, forMode: .common)
        renderLink = link
    }

    @objc
    private func drawFrame() {
        guard let surface, isRenderVisible else { return }
        ghostty_surface_draw(surface)
    }

    // Belfry patch: public — host-owned views (created via `init()`) bind
    // their controller directly rather than through the representable.
    public func bind(controller: TerminiTerminalController?) {
        self.controller = controller
        controller?.bind(
            processRemoteOutput: { [weak self] data in
                self?.processRemoteOutput(data)
            },
            focus: { [weak self] in
                _ = self?.becomeFirstResponder()
            },
            blur: { [weak self] in
                _ = self?.resignFirstResponder()
            },
            currentSize: { [weak self] in
                self?.currentTerminalSize()
            },
            visibleText: { [weak self] in
                self?.visibleTerminalText()
            },
            diagnostics: { [weak self] in
                self?.surfaceDiagnostics()
            }
        )
        reportSizeIfNeeded()
        reportDiagnostics()
    }

    private func createSurfaceIfNeeded() {
        guard surface == nil, let app = runtime.app else { return }

        var cfg = ghostty_surface_config_new()
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.platform_tag = GHOSTTY_PLATFORM_IOS
        cfg.platform = ghostty_platform_u(ios: ghostty_platform_ios_s(
            uiview: Unmanaged.passUnretained(self).toOpaque()
        ))
        cfg.scale_factor = Double(window?.screen.scale ?? UIScreen.main.scale)
        cfg.font_size = Float(terminalAppearance.fontSize ?? 0)
        cfg.wait_after_command = false

        guard let created = ghostty_surface_new(app, &cfg) else { return }
        surface = created
        if !isRenderVisible {                     // Belfry patch: born-hidden warm surface
            ghostty_surface_set_occlusion(created, false)
        }
        synchronizeGhosttyLayerGeometry()
        setSurfaceFocus(true)
        updateSurfaceSize()
        ghostty_surface_refresh(created)
        ghostty_surface_draw(created)
        reportSizeIfNeeded()
        reportDiagnostics()
        scheduleInitialAppearance()
    }

    /// Mark the surface IO-ready and apply the initial appearance on a later
    /// main-actor turn. Feeding `ghostty_surface_process_output` before the app
    /// has ticked the freshly-created surface blocks the main thread on the
    /// surface's IO futex (the draining tick also runs on the main thread), so
    /// `processRemoteOutput` buffers until this runs.
    private func scheduleInitialAppearance() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.surface != nil else { return }
            self.runtime.tick()
            self.surfaceIOReady = true
            self.applyTerminalAppearanceIfNeeded(force: true)
            self.flushPendingOutput()
        }
    }

    private func flushPendingOutput() {
        guard surfaceIOReady, !pendingOutput.isEmpty else { return }
        let buffered = pendingOutput
        pendingOutput = Data()
        processRemoteOutput(buffered)
    }

    private func updateSurfaceSize() {
        guard let surface else { return }
        let scale = Double(window?.screen.scale ?? UIScreen.main.scale)
        ghostty_surface_set_content_scale(surface, scale, scale)
        let width = UInt32(bounds.width * scale)
        let height = UInt32(bounds.height * scale)
        ghostty_surface_set_size(surface, width, height)
        ghostty_surface_refresh(surface)
        ghostty_surface_draw(surface)
        reportSizeIfNeeded()
        reportDiagnostics()
    }

    private func setSurfaceFocus(_ focused: Bool) {
        guard let surface else { return }
        ghostty_surface_set_focus(surface, focused)
    }

    func handleTransportWrite(_ data: Data) {
        controller?.forwardTransportWrite(data)
    }

    private func sendText(_ text: String) {
        guard let surface else { return }
        let len = text.utf8CString.count
        guard len > 0 else { return }
        text.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(len - 1))
        }
    }

    private func processRemoteOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        // Buffer until the surface exists and has been ticked — feeding an
        // un-ticked surface blocks the main thread (see scheduleInitialAppearance).
        guard surfaceIOReady, let surface else {
            pendingOutput.append(data)
            return
        }
        // Feed off-main (see outputFeedQueue). `guard let self` keeps the view
        // alive for the duration of the call, so deinit — the only place the
        // surface is freed — cannot run mid-feed; blocks that only start after
        // deinit see a nil weak self and skip the freed pointer.
        outputFeedQueue.async { [weak self] in
            guard let self else { return }
            withExtendedLifetime(self) {
                data.withUnsafeBytes { buffer in
                    guard let ptr = buffer.bindMemory(to: CChar.self).baseAddress else { return }
                    ghostty_surface_process_output(surface, ptr, UInt(data.count))
                }
            }
            DispatchQueue.main.async { [weak self] in
                self?.drawAfterRemoteOutput()
            }
        }
    }

    private func drawAfterRemoteOutput() {
        guard let surface else { return }
        guard isRenderVisible else {              // Belfry patch: gate hidden draws
            needsDrawOnReveal = true
            return
        }
        ghostty_surface_refresh(surface)
        ghostty_surface_draw(surface)
        reportDiagnostics()
    }

    private func applyTerminalAppearanceIfNeeded(force: Bool) {
        guard let surface else { return }
        var canCommitAppearanceState = true

        if force || lastAppliedAppearance.theme != terminalAppearance.theme {
            if let theme = terminalAppearance.theme {
                ghostty_surface_set_color_scheme(surface, theme.ghosttyColorScheme)
                processRemoteOutput(Data(theme.applyEscapeSequence.utf8))
            } else if lastAppliedAppearance.theme != nil {
                ghostty_surface_set_color_scheme(surface, ambientGhosttyColorScheme)
                processRemoteOutput(Data(TerminiTerminalTheme.resetEscapeSequence.utf8))
            } else if force {
                ghostty_surface_set_color_scheme(surface, ambientGhosttyColorScheme)
            }
        }

        let fontSizeChanged = lastAppliedAppearance.fontSize != terminalAppearance.fontSize
        let fontFamilyChanged = lastAppliedAppearance.fontFamily != terminalAppearance.fontFamily
        let shouldApplyFontConfig = fontSizeChanged
            || fontFamilyChanged
            || (force && terminalAppearance.hasRuntimeFontOverride)

        if shouldApplyFontConfig {
            guard let config = runtime.makeSurfaceConfig(for: terminalAppearance) else {
                canCommitAppearanceState = false
                return
            }
            defer { ghostty_config_free(config) }

            ghostty_surface_update_config(surface, config)

            if !force, fontSizeChanged {
                scheduleFontSizeBindingUpdate()
            }

            ghostty_surface_refresh(surface)
            ghostty_surface_draw(surface)
            reportSizeIfNeeded()
            reportDiagnostics()
        }

        if canCommitAppearanceState {
            lastAppliedAppearance = terminalAppearance
        }
    }

    private func updateBackgroundColor() {
        let color = terminalAppearance.theme?.background ?? .init(hex: 0x000000)
        backgroundColor = UIColor(
            red: CGFloat(color.red) / 255.0,
            green: CGFloat(color.green) / 255.0,
            blue: CGFloat(color.blue) / 255.0,
            alpha: 1.0
        )
    }

    private var ambientGhosttyColorScheme: ghostty_color_scheme_e {
        switch traitCollection.userInterfaceStyle {
        case .dark:
            GHOSTTY_COLOR_SCHEME_DARK
        default:
            GHOSTTY_COLOR_SCHEME_LIGHT
        }
    }

    private func applyBindingAction(_ action: String) {
        guard let surface else { return }
        _ = ghostty_surface_binding_action(
            surface,
            action,
            UInt(action.lengthOfBytes(using: .utf8))
        )
    }

    private func scheduleFontSizeBindingUpdate() {
        let action: String
        if let fontSize = terminalAppearance.fontSize {
            action = "set_font_size:\(String(format: "%.2f", min(max(fontSize, 1), 255)))"
        } else {
            action = "reset_font_size"
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.applyBindingAction(action)
            guard self.surface != nil else { return }
            ghostty_surface_refresh(self.surface)
            ghostty_surface_draw(self.surface)
            self.reportSizeIfNeeded()
            self.reportDiagnostics()
        }
    }

    private func currentTerminalSize() -> TerminiTerminalSize? {
        guard let surface else { return nil }
        let size = ghostty_surface_size(surface)
        return TerminiTerminalSize(
            columns: Int(size.columns),
            rows: Int(size.rows),
            cellWidthPixels: Int(size.cell_width_px),
            cellHeightPixels: Int(size.cell_height_px)
        )
    }

    private func reportSizeIfNeeded() {
        guard let size = currentTerminalSize() else { return }
        guard size != lastReportedSize else { return }
        lastReportedSize = size
        controller?.reportSizeChanged(size)
    }

    private func synchronizeGhosttyLayerGeometry() {
        let hostBounds = layer.bounds
        let scale = window?.screen.scale ?? UIScreen.main.scale

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contentsScale = scale
        for sublayer in layer.sublayers ?? [] {
            sublayer.frame = hostBounds
            sublayer.contentsScale = scale
            sublayer.setNeedsDisplay()
        }
        CATransaction.commit()
    }

    private func reportDiagnostics() {
        guard let diagnostics = surfaceDiagnostics() else { return }
        controller?.reportDiagnosticsChanged(diagnostics)
    }

    private func surfaceDiagnostics() -> TerminiSurfaceDiagnostics? {
        let hostLayer = layer
        let sublayers = hostLayer.sublayers ?? []

        func describe(_ rect: CGRect) -> String {
            "\(Int(rect.origin.x)),\(Int(rect.origin.y)) \(Int(rect.size.width))x\(Int(rect.size.height))"
        }

        var lines = [
            "view.bounds \(describe(bounds))",
            "host.layer \(String(describing: type(of: hostLayer))) \(describe(hostLayer.bounds)) scale=\(hostLayer.contentsScale)",
            "window=\(window != nil) firstResponder=\(isFirstResponder) sublayers=\(sublayers.count)"
        ]

        for (index, sublayer) in sublayers.prefix(3).enumerated() {
            lines.append(
                "sub[\(index)] \(String(describing: type(of: sublayer))) frame=\(describe(sublayer.frame)) bounds=\(describe(sublayer.bounds)) scale=\(sublayer.contentsScale)"
            )
        }

        if let size = currentTerminalSize() {
            lines.append("grid \(size.columns)x\(size.rows) cell=\(size.cellWidthPixels)x\(size.cellHeightPixels)")
        } else {
            lines.append("grid unavailable")
        }

        return TerminiSurfaceDiagnostics(lines: lines)
    }

    private func visibleTerminalText() -> String? {
        guard let surface, let size = currentTerminalSize() else { return nil }
        guard size.columns > 0, size.rows > 0 else { return nil }

        var text = ghostty_text_s(
            tl_px_x: 0,
            tl_px_y: 0,
            offset_start: 0,
            offset_len: 0,
            text: nil,
            text_len: 0
        )

        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_EXACT,
                x: 0,
                y: 0
            ),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_EXACT,
                x: UInt32(max(size.columns - 1, 0)),
                y: UInt32(max(size.rows - 1, 0))
            ),
            rectangle: false
        )

        guard ghostty_surface_read_text(surface, selection, &text),
              let base = text.text else {
            return nil
        }

        defer { ghostty_surface_free_text(surface, &text) }
        let data = Data(bytes: base, count: Int(text.text_len))
        return String(decoding: data, as: UTF8.self)
    }

    private func forward(presses: Set<UIPress>, action: ghostty_input_action_e) -> Bool {
        guard let surface else { return false }
        var handledAny = false

        for press in presses {
            guard let key = press.key else { continue }
            handledAny = true

            let text = key.characters

            var keyEvent = ghostty_input_key_s(
                action: action,
                mods: mods(from: key.modifierFlags),
                consumed_mods: GHOSTTY_MODS_NONE,
                keycode: Self.ghosttyKeycode(forHID: UInt32(key.keyCode.rawValue)),
                text: nil,
                unshifted_codepoint: key.charactersIgnoringModifiers.unicodeScalars.first?.value ?? 0,
                composing: false
            )

            if text.isEmpty {
                ghostty_surface_key(surface, keyEvent)
            } else {
                text.utf8CString.withUnsafeBufferPointer { buffer in
                    keyEvent.text = buffer.baseAddress
                    ghostty_surface_key(surface, keyEvent)
                }
            }
        }

        return handledAny
    }

    /// Ghostty's embedded keycode lookup uses macOS virtual keycodes on iOS
    /// too (keycodes.zig `native` column), not the HID usages `UIKey.keyCode`
    /// carries. Translate the keys whose encoding depends on the resolved
    /// physical key (no text payload to fall back on); printing keys carry
    /// text, which the encoder prefers, so they pass through untranslated.
    private static let hidToMacKeycode: [UInt32: UInt32] = [
        40: 0x24,   // Return
        88: 0x4C,   // Keypad Enter
        41: 0x35,   // Escape
        43: 0x30,   // Tab
        42: 0x33,   // Backspace
        76: 0x75,   // Delete Forward
        82: 0x7E, 81: 0x7D, 80: 0x7B, 79: 0x7C,   // arrows: up down left right
        75: 0x74, 78: 0x79, 74: 0x73, 77: 0x77,   // PageUp PageDown Home End
    ]

    static func ghosttyKeycode(forHID hid: UInt32) -> UInt32 {
        hidToMacKeycode[hid] ?? hid
    }

    private func mods(from flags: UIKeyModifierFlags) -> ghostty_input_mods_e {
        var raw = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.alternate) { raw |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.alphaShift) { raw |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(rawValue: raw)
    }
}

// MARK: Belfry patch — synthesized keys, touch scrollback, row readback,
// renderer-health recovery, and a launch-time renderer prewarm. All additive.

/// Special keys a host can synthesize without a hardware keyboard. Routed
/// through `ghostty_surface_key` so mode-dependent encodings (DECCKM
/// application cursor keys, kitty keyboard protocol) come out right — raw
/// escape strings would not.
public enum TerminiTerminalKey: Sendable {
    case arrowUp, arrowDown, arrowLeft, arrowRight
    case escape, tab, enter, backspace
    case pageUp, pageDown, home, end

    /// macOS virtual keycodes (kVK_*). Ghostty's keycode table maps its
    /// `native` column to the *mac virtual keycode* on both macOS AND iOS
    /// (src/input/keycodes.zig: `.ios, .macos => 4`) — it does NOT accept
    /// HID usages. Feeding `UIKey.keyCode` HID values here resolved Esc to
    /// the semicolon key and arrows to keypad digits; with no text payload
    /// those key events encoded nothing at all.
    var ghosttyKeycode: UInt32 {
        switch self {
        case .arrowUp: 0x7E
        case .arrowDown: 0x7D
        case .arrowLeft: 0x7B
        case .arrowRight: 0x7C
        case .escape: 0x35
        case .tab: 0x30
        case .enter: 0x24
        case .backspace: 0x33
        case .pageUp: 0x74
        case .pageDown: 0x79
        case .home: 0x73
        case .end: 0x77
        }
    }

    /// Text payload for keys that carry one on hardware keyboards (UIKey
    /// reports "\t"/"\r"); nil for pure control keys.
    var textPayload: String? {
        switch self {
        case .tab: "\t"
        case .enter: "\r"
        default: nil
        }
    }
}

extension SurfaceContainerView {
    /// Paste text with clipboard semantics. Routed through ghostty's text
    /// callback, which wraps the text in bracketed-paste markers when the
    /// remote app enabled mode 2004 (vim, modern shells) and filters
    /// newlines to '\r' otherwise — sending pasted text straight to the
    /// host as raw bytes gets multiline pastes auto-indented or executed
    /// line by line.
    public func pasteText(_ text: String) {
        sendText(text)
    }

    /// Synthesize a press+release pair for a special key, as if typed on a
    /// hardware keyboard.
    public func sendKey(_ key: TerminiTerminalKey) {
        sendKeyEvent(key, action: GHOSTTY_ACTION_PRESS)
        sendKeyEvent(key, action: GHOSTTY_ACTION_RELEASE)
    }

    private func sendKeyEvent(_ key: TerminiTerminalKey, action: ghostty_input_action_e) {
        guard let surface else { return }
        var keyEvent = ghostty_input_key_s(
            action: action,
            mods: GHOSTTY_MODS_NONE,
            consumed_mods: GHOSTTY_MODS_NONE,
            keycode: key.ghosttyKeycode,
            text: nil,
            unshifted_codepoint: 0,
            composing: false
        )
        if action == GHOSTTY_ACTION_PRESS, let text = key.textPayload {
            text.utf8CString.withUnsafeBufferPointer { buffer in
                keyEvent.text = buffer.baseAddress
                ghostty_surface_key(surface, keyEvent)
            }
        } else {
            ghostty_surface_key(surface, keyEvent)
        }
    }

    /// Whether the app in the terminal has captured the mouse (mouse
    /// reporting active — tmux `mouse on`, vim, etc). Diagnostic + gesture
    /// routing aid.
    public var isMouseCaptured: Bool {
        guard let surface else { return false }
        return ghostty_surface_mouse_captured(surface)
    }

    /// Report a touch location as the mouse position (view points). Wheel
    /// events that follow are routed by ghostty to the pane under this point
    /// when the app has mouse reporting on (tmux `mouse on`).
    public func reportTouchLocation(_ point: CGPoint) {
        guard let surface else { return }
        // Unscaled view points: the embedded apprt converts to pixels itself
        // (`cursorPosToPixels`) — pre-scaling here put the reported position
        // outside the grid and silently killed mouse reports.
        ghostty_surface_mouse_pos(surface, point.x, point.y, GHOSTTY_MODS_NONE)
    }

    /// Precision scroll by pixel deltas (view points; converted to pixels).
    /// Positive dy scrolls content down (finger moving down reveals older
    /// output, matching UIScrollView direction handled by the caller).
    public func scrollWheel(deltaY points: CGFloat, at point: CGPoint) {
        guard let surface else { return }
        reportTouchLocation(point)
        let scale = window?.screen.scale ?? UIScreen.main.scale
        // Bit 0 = precision deltas (pixels, not wheel ticks) — see the macOS
        // scroll-semantics patch in LOCAL_PATCHES.md.
        ghostty_surface_mouse_scroll(surface, 0, Double(points * scale),
                                     ghostty_input_scroll_mods_t(0b0000_0001))
    }

    /// The visible text of the terminal row under `point`, plus the character
    /// column the point falls in. Used for long-press link/path detection —
    /// iOS builds of libghostty don't export `quicklook_word`, so the host
    /// reads the row and tokenizes around the column itself.
    public func rowText(at point: CGPoint) -> (text: String, column: Int)? {
        guard let surface else { return nil }
        let size = ghostty_surface_size(surface)
        guard size.columns > 0, size.rows > 0,
              size.cell_width_px > 0, size.cell_height_px > 0,
              bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = window?.screen.scale ?? UIScreen.main.scale
        let row = min(max(Int(point.y * scale) / Int(size.cell_height_px), 0), Int(size.rows) - 1)
        let column = min(max(Int(point.x * scale) / Int(size.cell_width_px), 0), Int(size.columns) - 1)

        var text = ghostty_text_s(
            tl_px_x: 0, tl_px_y: 0, offset_start: 0, offset_len: 0,
            text: nil, text_len: 0)
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT,
                x: 0, y: UInt32(row)),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT,
                x: UInt32(Int(size.columns) - 1), y: UInt32(row)),
            rectangle: false)
        guard ghostty_surface_read_text(surface, selection, &text), let base = text.text else {
            return nil
        }
        defer { ghostty_surface_free_text(surface, &text) }
        let data = Data(bytes: base, count: Int(text.text_len))
        return (String(decoding: data, as: UTF8.self), column)
    }

    /// Renderer health flipped (delivered via the runtime action callback).
    /// On unhealthy: rebuild the GPU surface over the same UIView. libghostty
    /// couples terminal state to the surface, so content is lost — the host's
    /// `onRendererRebuild` asks the remote (tmux) to repaint.
    func rendererHealthChanged(healthy: Bool) {
        guard !healthy, let old = surface else { return }
        surface = nil
        surfaceIOReady = false
        pendingOutput = Data()
        // Free on the output-feed queue: any already-enqueued feed block
        // captured the old pointer, and the serial queue guarantees this free
        // runs after those blocks complete.
        outputFeedQueue.async {
            ghostty_surface_free(old)
        }
        createSurfaceIfNeeded()
        onRendererRebuild?()
    }

    /// Warm the renderer once at launch (Remux-style mitigation): create a
    /// small offscreen surface, tick + draw it so libghostty initializes its
    /// Metal state and font atlas off the critical path, then let it go.
    @MainActor
    public static func prewarmRenderer() {
        let view = SurfaceContainerView()
        view.frame = CGRect(x: 0, y: 0, width: 96, height: 96)
        view.isRenderVisible = true
        view.createSurfaceIfNeeded()
        prewarmedView = view
        // A couple of runloop turns for the initial tick + appearance, one
        // explicit draw, then release. 3s is arbitrary but far past first use.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let surface = view.surface {
                ghostty_surface_draw(surface)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            prewarmedView = nil
        }
    }
}

/// Keeps the prewarm surface alive long enough to actually render once.
@MainActor
private var prewarmedView: SurfaceContainerView?

private extension TerminiTerminalTheme {
    var ghosttyColorScheme: ghostty_color_scheme_e {
        switch colorScheme {
        case .dark:
            GHOSTTY_COLOR_SCHEME_DARK
        case .light:
            GHOSTTY_COLOR_SCHEME_LIGHT
        }
    }
}

#endif
