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
        // No shortcuts/predictions bar: with a hardware keyboard attached an
        // (empty) input assistant bar would otherwise be shown, reserving a
        // strip of terminal space for nothing.
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
        installScrollbackGesture()
        installFocusTap()
        installKeyboardObservers()
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

    // MARK: System-priority key commands

    /// Esc, Return, Tab and the arrows are focus-system keys on iPadOS: with
    /// a hardware keyboard the system consumes them for focus navigation
    /// BEFORE press delivery — Esc pops focus (the terminal visibly loses the
    /// keyboard), Return "activates" the focused item and never reaches the
    /// app. Key commands with `wantsPriorityOverSystemBehavior` are the
    /// documented override; the system calls these actions *instead of*
    /// delivering the press, so there's no double-send with `pressesBegan`
    /// (which still handles paging, backspace, ctrl chords and alt-meta).
    private static let priorityKeys: [String: TerminalKey] = [
        UIKeyCommand.inputEscape: .escape,
        "\r": .enter,
        "\t": .tab,
        UIKeyCommand.inputUpArrow: .arrowUp,
        UIKeyCommand.inputDownArrow: .arrowDown,
        UIKeyCommand.inputLeftArrow: .arrowLeft,
        UIKeyCommand.inputRightArrow: .arrowRight,
    ]

    override var keyCommands: [UIKeyCommand]? {
        var commands = Self.priorityKeys.keys.map { input in
            let command = UIKeyCommand(input: input, modifierFlags: [],
                                       action: #selector(handlePriorityKey(_:)))
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
        // Shift+Tab is a focus key too; terminals expect backtab (CSI Z).
        let backtab = UIKeyCommand(input: "\t", modifierFlags: .shift,
                                   action: #selector(handlePriorityKey(_:)))
        backtab.wantsPriorityOverSystemBehavior = true
        commands.append(backtab)
        return commands
    }

    @objc private func handlePriorityKey(_ command: UIKeyCommand) {
        guard let input = command.input else { return }
        if input == "\t", command.modifierFlags.contains(.shift) {
            onHardwareKeyBytes?(Data([0x1B, 0x5B, 0x5A]))   // CSI Z
            return
        }
        guard let key = Self.priorityKeys[input] else { return }
        sendKey(key.terminiKey)
    }

    /// Auto-repeat for claimed presses. UIKit only repeats keys that reach
    /// the text-input system; anything we claim in `pressesBegan` (arrows,
    /// backspace, ctrl chords…) would otherwise fire exactly once no matter
    /// how long it's held.
    private var keyRepeatTimer: Timer?
    private var repeatingKeyCode: UInt32?
    private static let keyRepeatInitialDelay: TimeInterval = 0.4
    private static let keyRepeatInterval: TimeInterval = 0.07

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            switch route(press) {
            case .sendBytes(let data):
                onHardwareKeyBytes?(data)
                beginKeyRepeat(press) { [weak self] in self?.onHardwareKeyBytes?(data) }
            case .sendKey(let key):
                sendKey(key.terminiKey)
                beginKeyRepeat(press) { [weak self] in self?.sendKey(key.terminiKey) }
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
        endKeyRepeat(for: presses)
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

    /// Arm repeat for the newest claimed press (last key down wins, like a
    /// physical keyboard). The keycode gate keeps a stale timer from firing
    /// after another key took over or the press ended.
    private func beginKeyRepeat(_ press: UIPress, send: @escaping () -> Void) {
        guard let keyCode = press.key.map({ UInt32($0.keyCode.rawValue) }) else { return }
        keyRepeatTimer?.invalidate()
        repeatingKeyCode = keyCode
        keyRepeatTimer = Timer.scheduledTimer(
            withTimeInterval: Self.keyRepeatInitialDelay, repeats: false
        ) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.repeatingKeyCode == keyCode else { return }
                self.keyRepeatTimer = Timer.scheduledTimer(
                    withTimeInterval: Self.keyRepeatInterval, repeats: true
                ) { [weak self] _ in
                    DispatchQueue.main.async {
                        guard let self, self.repeatingKeyCode == keyCode else { return }
                        send()
                    }
                }
            }
        }
    }

    private func endKeyRepeat(for presses: Set<UIPress>) {
        guard let repeating = repeatingKeyCode,
              presses.contains(where: { $0.key.map({ UInt32($0.keyCode.rawValue) }) == repeating })
        else { return }
        stopKeyRepeat()
    }

    private func stopKeyRepeat() {
        keyRepeatTimer?.invalidate()
        keyRepeatTimer = nil
        repeatingKeyCode = nil
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
        if resigned {
            stopKeyRepeat()
            if Self.keyboardOwner === self { Self.keyboardOwner = nil }
        }
        return resigned
    }

    // MARK: Keyboard geometry

    /// The terminal opts out of SwiftUI's automatic keyboard avoidance
    /// (`.ignoresSafeArea(.keyboard)` in TerminalDetailView) — it proved
    /// capable of leaving a phantom inset behind after the keyboard was gone.
    /// Instead the container pins our bottom edge through this constraint and
    /// we drive its constant from the actual keyboard frame notifications:
    /// overlap is computed fresh from geometry each time, so "keyboard gone"
    /// is always exactly zero.
    var containerBottomConstraint: NSLayoutConstraint?
    private(set) var keyboardOverlap: CGFloat = 0

    private func installKeyboardObservers() {
        for name in [UIResponder.keyboardWillChangeFrameNotification,
                     UIResponder.keyboardWillHideNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(keyboardFrameChanged(_:)), name: name, object: nil)
        }
    }

    @objc private func keyboardFrameChanged(_ note: Notification) {
        guard let window, let superview else { return }
        var overlap: CGFloat = 0
        if note.name == UIResponder.keyboardWillChangeFrameNotification,
           let endFrame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
            let frame = window.convert(endFrame, from: window.screen.coordinateSpace)
            // A floating/split keyboard is narrower than the window; it
            // hovers over content rather than docking, so no inset.
            if frame.width >= window.bounds.width {
                // Measure against the container, not self — self may already
                // be shrunken by the previous overlap.
                let containerFrame = superview.convert(superview.bounds, to: window)
                overlap = max(0, min(containerFrame.maxY, window.bounds.maxY) - frame.minY)
                overlap = min(overlap, containerFrame.height)
            }
        }
        guard overlap != keyboardOverlap else { return }
        keyboardOverlap = overlap
        containerBottomConstraint?.constant = -overlap
        let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey]
            as? TimeInterval ?? 0.25
        UIView.animate(withDuration: duration) {
            superview.layoutIfNeeded()
        }
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
        // Through ghostty, not the typed-text path: pastes must honour
        // bracketed-paste mode (vim auto-indent, shells not executing every
        // line) — only the terminal state knows whether mode 2004 is on.
        pasteText(text)
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
            // The bottom pin carries the keyboard overlap (see "Keyboard
            // geometry" above): the container spans under the keyboard, the
            // terminal stops above it.
            let bottom = terminalView.bottomAnchor.constraint(
                equalTo: container.bottomAnchor, constant: -terminalView.keyboardOverlap)
            terminalView.containerBottomConstraint = bottom
            NSLayoutConstraint.activate([
                terminalView.topAnchor.constraint(equalTo: container.topAnchor),
                bottom,
                terminalView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                terminalView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
        }
        terminalView.isRenderVisible = isVisible
        terminalView.terminalAppearance = appearance
    }
}
