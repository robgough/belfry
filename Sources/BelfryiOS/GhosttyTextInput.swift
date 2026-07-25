import UIKit

// UITextInput over a virtual one-character document. The terminal consumes
// keystrokes directly (UIKeyInput on the base class); this conformance exists
// for the two behaviours UIKit reserves for "real" text views:
//  1. the spacebar long-press floating cursor is only delivered to a
//     UITextInput — it drives the cursor trackpad;
//  2. a non-empty document makes UIKit run native backspace auto-repeat.
// The document is a single space, the caret always sits at its end, and
// every geometry query returns a degenerate rect — UIKit never draws
// selection UI because `canPerformAction` suppresses everything but Paste.

final class GhosttyTextPosition: UITextPosition {
    let offset: Int
    init(_ offset: Int) { self.offset = offset }
}

final class GhosttyTextRange: UITextRange {
    let startOffset: Int
    let endOffset: Int
    init(_ start: Int, _ end: Int) {
        self.startOffset = start
        self.endOffset = end
    }
    override var start: UITextPosition { GhosttyTextPosition(startOffset) }
    override var end: UITextPosition { GhosttyTextPosition(endOffset) }
    override var isEmpty: Bool { startOffset == endOffset }
}

extension BelfryGhosttySurfaceView: UITextInput {
    private var documentLength: Int { 1 }

    private func offset(of position: UITextPosition) -> Int {
        (position as? GhosttyTextPosition)?.offset ?? documentLength
    }

    // MARK: Text

    func text(in range: UITextRange) -> String? {
        guard let range = range as? GhosttyTextRange, !range.isEmpty else { return nil }
        return " "
    }

    func replace(_ range: UITextRange, withText text: String) {
        // Dictation and QuickType route through replace; the terminal only
        // ever appends.
        insertText(text)
    }

    var selectedTextRange: UITextRange? {
        get { GhosttyTextRange(documentLength, documentLength) }
        set {}
    }

    var markedTextRange: UITextRange? { nil }

    var markedTextStyle: [NSAttributedString.Key: Any]? {
        get { nil }
        set {}
    }

    func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        // IME composition isn't previewed in the virtual document; the
        // committed string arrives via insertText on confirm.
    }

    func unmarkText() {}

    // MARK: Positions

    var beginningOfDocument: UITextPosition { GhosttyTextPosition(0) }
    var endOfDocument: UITextPosition { GhosttyTextPosition(documentLength) }

    func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        let a = offset(of: fromPosition)
        let b = offset(of: toPosition)
        return GhosttyTextRange(min(a, b), max(a, b))
    }

    func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        let target = self.offset(of: position) + offset
        guard (0...documentLength).contains(target) else { return nil }
        return GhosttyTextPosition(target)
    }

    func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        switch direction {
        case .right, .down: self.position(from: position, offset: offset)
        default: self.position(from: position, offset: -offset)
        }
    }

    func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        let a = offset(of: position)
        let b = offset(of: other)
        if a < b { return .orderedAscending }
        if a > b { return .orderedDescending }
        return .orderedSame
    }

    func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        offset(of: toPosition) - offset(of: from)
    }

    // MARK: Delegation

    var inputDelegate: UITextInputDelegate? {
        get { textInputDelegate }
        set { textInputDelegate = newValue }
    }

    var tokenizer: UITextInputTokenizer { textTokenizer }

    // MARK: Layout queries (degenerate — no visible text system)

    func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        switch direction {
        case .right, .down: range.end
        default: range.start
        }
    }

    func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        GhosttyTextRange(0, documentLength)
    }

    func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection {
        .leftToRight
    }

    func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}

    func firstRect(for range: UITextRange) -> CGRect {
        caretRect(for: range.start)
    }

    func caretRect(for position: UITextPosition) -> CGRect {
        // Somewhere sane for the floating cursor to anchor: mid-view.
        CGRect(x: bounds.midX, y: bounds.midY, width: 2, height: 18)
    }

    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }

    func closestPosition(to point: CGPoint) -> UITextPosition? {
        GhosttyTextPosition(documentLength)
    }

    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
        range.end
    }

    func characterRange(at point: CGPoint) -> UITextRange? {
        GhosttyTextRange(0, documentLength)
    }

    // MARK: Floating cursor → cursor trackpad

    func beginFloatingCursor(at point: CGPoint) {
        trackpadDriver?.begin(at: point)
    }

    func updateFloatingCursor(at point: CGPoint) {
        trackpadDriver?.update(to: point)
    }

    func endFloatingCursor() {
        trackpadDriver?.end()
    }
}
