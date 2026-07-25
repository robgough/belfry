import SwiftUI
import Termini
import UIKit

/// Belfry's ghostty surface view: adds the touch UX layer on top of Termini's
/// `SurfaceContainerView` — keyboard-focus discipline shared across sessions,
/// and single-finger scrollback panning. (The cursor trackpad and long-press
/// previews attach here too; see GhosttyTrackpad.swift / TerminalPreview.swift.)
final class BelfryGhosttySurfaceView: SurfaceContainerView {
    /// The terminal currently holding the keyboard, if any. Selection changes
    /// consult this: focus is only *transferred* between terminals, never
    /// conjured — the keyboard stays down until the user summons it (tap or
    /// toolbar button) and stays up across session switches once they have.
    private(set) static weak var keyboardOwner: BelfryGhosttySurfaceView?

    /// Wheel-tick smoothing for the scrollback pan.
    private var lastPanLocation: CGPoint = .zero

    /// Cursor trackpad (long-press drag → arrows); see GhosttyTrackpad.swift.
    var trackpadDriver: CursorTrackpadDriver?
    /// Fallback for a long-press that never steered: token preview at point.
    var onLongPressToken: ((CGPoint) -> Void)?

    /// UITextInput plumbing (see GhosttyTextInput.swift): the shim exists for
    /// exactly two UIKit behaviours — the spacebar long-press floating cursor
    /// is only delivered to a `UITextInput`, and a non-empty virtual document
    /// makes UIKit drive native backspace key-repeat.
    weak var textInputDelegate: UITextInputDelegate?
    lazy var textTokenizer: UITextInputTokenizer = UITextInputStringTokenizer(textInput: self)

    override init() {
        super.init()
        autoFocusOnAttach = false
        // Touches must not summon the keyboard — a pan is usually someone
        // trying to READ. Focus comes from a deliberate tap (below), the
        // toolbar/dock toggles, or focus-transfer between sessions.
        focusOnTouch = false
        // Hardware keys are routed here (HardwareKeyRouter), not blanket-
        // forwarded into ghostty — that ate Return/Ctrl on iPad keyboards.
        forwardsHardwareKeys = false
        installScrollbackGesture()
        installFocusTap()
    }

    // MARK: Focus

    private func installFocusTap() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleFocusTap(_:)))
        tap.numberOfTapsRequired = 1
        addGestureRecognizer(tap)
    }

    @objc private func handleFocusTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        _ = becomeFirstResponder()
    }

    // MARK: Hardware keyboard

    /// Sink for routed key bytes (ctrl chords, alt-meta) — wired by the
    /// workspace to the SSH channel.
    var onHardwareKeyBytes: ((Data) -> Void)?

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            switch route(press) {
            case .sendBytes(let data):
                onHardwareKeyBytes?(data)
            case .sendKey(let key):
                sendKey(key.terminiKey)
            case .paste:
                paste(nil)
            case .passToSystem, .passToTextInput, .none:
                unhandled.insert(press)
            }
        }
        if !unhandled.isEmpty {
            super.pressesBegan(unhandled, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // Releases of keys we claimed are swallowed (sendKey already sent a
        // press+release pair); the rest go to the system.
        let unhandled = presses.filter { press in
            switch route(press) {
            case .passToSystem, .passToTextInput, .none: true
            default: false
            }
        }
        if !unhandled.isEmpty {
            super.pressesEnded(Set(unhandled), with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        pressesEnded(presses, with: event)
    }

    private func route(_ press: UIPress) -> HardwareKeyRouter.Action? {
        guard let key = press.key else { return nil }
        var modifiers: HardwareKeyRouter.Modifiers = []
        if key.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if key.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if key.modifierFlags.contains(.alternate) { modifiers.insert(.alternate) }
        if key.modifierFlags.contains(.command) { modifiers.insert(.command) }
        return HardwareKeyRouter.route(
            keyCode: UInt32(key.keyCode.rawValue),
            charactersIgnoringModifiers: key.charactersIgnoringModifiers,
            modifiers: modifiers)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func becomeFirstResponder() -> Bool {
        // super resigns the previous responder first, so assign after: the
        // old view's resign clears the slot, then we claim it.
        let became = super.becomeFirstResponder()
        if became { Self.keyboardOwner = self }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, Self.keyboardOwner === self { Self.keyboardOwner = nil }
        return resigned
    }

    // MARK: Touch scrollback

    /// Single-finger vertical pans scroll — ghostty translates wheel input to
    /// SGR mouse when the app reports (tmux `mouse on` → native copy-mode
    /// scrollback), and scrolls its own viewport otherwise. Horizontal pans
    /// fall through (Termini's two-finger pan and future gestures).
    private func installScrollbackGesture() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleScrollbackPan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        addGestureRecognizer(pan)
        scrollbackPan = pan
    }

    private weak var scrollbackPan: UIPanGestureRecognizer?

    @objc private func handleScrollbackPan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            lastPanLocation = gesture.location(in: self)
        case .changed:
            let translation = gesture.translation(in: self)
            gesture.setTranslation(.zero, in: self)
            // Finger moving down reveals older content — ghostty's positive
            // deltaY scrolls toward older output (matches the macOS surface).
            scrollWheel(deltaY: translation.y, at: gesture.location(in: self))
        default:
            break
        }
    }

    /// Claim mostly-vertical single-finger pans for scrollback; let everything
    /// else (including Termini's own two-finger pan) begin freely. The bias is
    /// gentle — a slow reading-scroll starts with tiny velocities, and there
    /// is no competing single-finger horizontal gesture to protect.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === scrollbackPan,
              let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        // Never claim the pan while the trackpad is steering.
        if trackpadDriver?.isActive == true { return false }
        let velocity = pan.velocity(in: self)
        return abs(velocity.y) >= abs(velocity.x)
    }

    // MARK: Edit menu

    /// The UITextInput conformance would otherwise advertise Select/Copy/Cut
    /// over a virtual document; only Paste is real.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        action == #selector(paste(_:)) && UIPasteboard.general.hasStrings
    }

    override func paste(_ sender: Any?) {
        guard let text = UIPasteboard.general.string else { return }
        insertText(text)
    }
}

extension TerminalKey {
    /// Bridge to Termini's key synthesis (HID-keycode ghostty key events).
    var terminiKey: TerminiTerminalKey {
        switch self {
        case .arrowUp: .arrowUp
        case .arrowDown: .arrowDown
        case .arrowLeft: .arrowLeft
        case .arrowRight: .arrowRight
        case .escape: .escape
        case .tab: .tab
        case .enter: .enter
        case .backspace: .backspace
        case .pageUp: .pageUp
        case .pageDown: .pageDown
        case .home: .home
        case .end: .end
        }
    }
}

/// Mounts the workspace's persistent ghostty view into SwiftUI.
///
/// The terminal is a single long-lived UIView owned by the workspace, not by
/// this representable: toggling the iPad's `navigationSplitViewStyle` rebuilds
/// the detail column and tears down representables, so we vend a throwaway
/// container SwiftUI *can* own and re-parent the persistent surface into
/// whichever container is currently live (same pattern the SwiftTerm surface
/// used, for the same reason).
struct GhosttySurfaceContainer: UIViewRepresentable {
    let terminalView: BelfryGhosttySurfaceView
    let appearance: TerminiTerminalAppearance
    let isVisible: Bool

    func makeUIView(context: Context) -> UIView { UIView() }

    func updateUIView(_ container: UIView, context: Context) {
        if terminalView.superview !== container {
            // Moving to a new superview drops the old constraints automatically.
            terminalView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(terminalView)
            NSLayoutConstraint.activate([
                terminalView.topAnchor.constraint(equalTo: container.topAnchor),
                terminalView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                terminalView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                terminalView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
        }
        terminalView.isRenderVisible = isVisible
        terminalView.terminalAppearance = appearance
    }
}
