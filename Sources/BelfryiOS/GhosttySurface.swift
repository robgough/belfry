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
        installScrollbackGesture()
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

    /// Claim only clearly vertical single-finger pans for scrollback; let
    /// everything else (including Termini's own two-finger pan) begin freely.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === scrollbackPan,
              let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        // Never claim the pan while the trackpad is steering.
        if trackpadDriver?.isActive == true { return false }
        let velocity = pan.velocity(in: self)
        return abs(velocity.y) > abs(velocity.x) * 1.5
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
