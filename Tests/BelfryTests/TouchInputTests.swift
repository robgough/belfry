import CoreGraphics
import Foundation
import Testing
@testable import Belfry

// The touch-input logic is pure state machines (BelfryKit), so the tuning
// that makes gestures feel right is pinned here rather than rediscovered by
// regression on a device.

struct CursorTrackpadMathTests {
    @Test func deadbandSuppressesSmallDrags() {
        var math = CursorTrackpadMath(start: .zero)
        #expect(math.update(to: CGPoint(x: 8, y: 3)) == nil)
        #expect(!math.didSteer)
    }

    @Test func axisLocksHorizontalAndEmitsSteps() {
        var math = CursorTrackpadMath(start: .zero)
        let emit = math.update(to: CGPoint(x: 30, y: 2))
        #expect(emit?.axis == .horizontal)
        #expect((emit?.steps ?? 0) > 0)
    }

    @Test func verticalStepsAreCoarser() {
        var horizontal = CursorTrackpadMath(start: .zero)
        var vertical = CursorTrackpadMath(start: .zero)
        let h = horizontal.update(to: CGPoint(x: 40, y: 0))?.steps ?? 0
        let v = vertical.update(to: CGPoint(x: 0, y: 40))?.steps ?? 0
        #expect(h > v)
    }

    @Test func remainderCarriesAcrossUpdates() {
        var math = CursorTrackpadMath(start: .zero)
        _ = math.update(to: CGPoint(x: 15, y: 0))   // locks, emits some, keeps remainder
        // Feed sub-step deltas: individually too small, together one step.
        var total = 0
        for x in stride(from: 16.0, through: 40.0, by: 3.0) {
            total += math.update(to: CGPoint(x: x, y: 0))?.steps ?? 0
        }
        #expect(total >= 2)
    }

    @Test func smallWobbleNeverFlipsAxis() {
        var math = CursorTrackpadMath(start: .zero)
        _ = math.update(to: CGPoint(x: 30, y: 0))
        // Wobble a couple of points vertically while continuing right.
        for (x, y) in [(35.0, 2.0), (40.0, -2.0), (45.0, 2.0), (50.0, -1.0)] {
            let emit = math.update(to: CGPoint(x: x, y: y))
            if let emit { #expect(emit.axis == .horizontal) }
        }
    }

    @Test func deliberateOrthogonalPullSwitchesAxis() {
        var math = CursorTrackpadMath(start: .zero)
        _ = math.update(to: CGPoint(x: 30, y: 0))
        // Strong vertical travel with no further horizontal movement.
        var switched = false
        for y in stride(from: 8.0, through: 80.0, by: 8.0) {
            if math.update(to: CGPoint(x: 30, y: y))?.axis == .vertical { switched = true }
        }
        #expect(switched)
    }

    @Test func stepsPerUpdateAreCapped() {
        var math = CursorTrackpadMath(start: .zero)
        let emit = math.update(to: CGPoint(x: 500, y: 0))
        #expect(abs(emit?.steps ?? 0) <= CursorTrackpadMath.maxStepsPerUpdate)
    }

    @Test func intensityRampsWithDisplacement() {
        var near = CursorTrackpadMath(start: .zero)
        _ = near.update(to: CGPoint(x: 20, y: 0))
        var far = CursorTrackpadMath(start: .zero)
        _ = far.update(to: CGPoint(x: 120, y: 0))
        #expect(far.intensity > near.intensity)
        #expect(far.intensity == 1)
        // Cadence follows intensity.
        #expect(CursorTrackpadMath.repeatInterval(intensity: far.intensity)
            < CursorTrackpadMath.repeatInterval(intensity: near.intensity))
    }

    @Test func directionMapsToArrowKeys() {
        #expect(CursorTrackpadMath.key(axis: .horizontal, direction: -1) == .arrowLeft)
        #expect(CursorTrackpadMath.key(axis: .horizontal, direction: 1) == .arrowRight)
        #expect(CursorTrackpadMath.key(axis: .vertical, direction: -1) == .arrowUp)
        #expect(CursorTrackpadMath.key(axis: .vertical, direction: 1) == .arrowDown)
    }
}

struct ControlSequencesTests {
    @Test func lettersMapToControlCodes() {
        #expect(ControlSequences.controlByte(for: "c") == 0x03)
        #expect(ControlSequences.controlByte(for: "C") == 0x03)
        #expect(ControlSequences.controlByte(for: "a") == 0x01)
        #expect(ControlSequences.controlByte(for: "z") == 0x1A)
    }

    @Test func punctuationChords() {
        #expect(ControlSequences.controlByte(for: "[") == 0x1B)   // ESC
        #expect(ControlSequences.controlByte(for: "\\") == 0x1C)
        #expect(ControlSequences.controlByte(for: "]") == 0x1D)
        #expect(ControlSequences.controlByte(for: "^") == 0x1E)
        #expect(ControlSequences.controlByte(for: "_") == 0x1F)
        #expect(ControlSequences.controlByte(for: " ") == 0x00)
        #expect(ControlSequences.controlByte(for: "?") == 0x7F)
    }

    @Test func meaninglessPairsPassThrough() {
        #expect(ControlSequences.controlByte(for: "1") == nil)
        #expect(ControlSequences.controlByte(for: "é") == nil)
        #expect(ControlSequences.controlByte(for: "ab") == nil)
    }

    @Test func caretSpecs() {
        #expect(ControlSequences.data(forControl: "^C") == Data([0x03]))
        #expect(ControlSequences.data(forControl: "c") == Data([0x03]))
        #expect(ControlSequences.data(forControl: "^L") == Data([0x0C]))
    }

    @Test @MainActor func stickyModifierConsumesOnce() {
        let sticky = StickyModifierState()
        sticky.armControl()
        #expect(sticky.apply(to: "c") == Data([0x03]))
        #expect(sticky.controlArmed == false)
        #expect(sticky.apply(to: "c") == Data("c".utf8))
    }

    @Test @MainActor func stickyModifierPassesUnmappablesThrough() {
        let sticky = StickyModifierState()
        sticky.armControl()
        #expect(sticky.apply(to: "hello") == Data("hello".utf8))
        #expect(sticky.controlArmed == false)
    }
}

struct ShortcutStoreTests {
    @MainActor private func makeStore() -> ShortcutStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("belfry-shortcuts-\(UUID().uuidString).json")
        return ShortcutStore(fileURL: url)
    }

    @Test @MainActor func seedsStartersOnFirstLaunch() {
        let store = makeStore()
        #expect(store.collections.count == StarterShortcuts.all.count)
        #expect(store.collections.contains { $0.title == "Claude" })
    }

    @Test @MainActor func deletedStarterStaysDeletedAcrossReload() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("belfry-shortcuts-\(UUID().uuidString).json")
        let store = ShortcutStore(fileURL: url)
        let claude = try #require(store.collections.first { $0.title == "Claude" })
        let victim = claude.shortcuts[0]
        store.removeShortcut(id: victim.id, from: claude.id)

        // Fresh store over the same file: reseeding must not resurrect it.
        let reloaded = ShortcutStore(fileURL: url)
        let reloadedClaude = try #require(reloaded.collections.first { $0.title == "Claude" })
        #expect(!reloadedClaude.shortcuts.contains { $0.id == victim.id })
    }

    @Test @MainActor func customShortcutRoundTrips() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("belfry-shortcuts-\(UUID().uuidString).json")
        let store = ShortcutStore(fileURL: url)
        let shell = try #require(store.collections.first { $0.title == "Shell" })
        let custom = Shortcut(title: "Deploy", steps: [.text("make deploy", submit: true)])
        store.addShortcut(custom, to: shell.id)

        let reloaded = ShortcutStore(fileURL: url)
        let reloadedShell = try #require(reloaded.collections.first { $0.title == "Shell" })
        #expect(reloadedShell.shortcuts.contains { $0.title == "Deploy" })
    }
}

struct HardwareKeyRouterTests {
    typealias M = HardwareKeyRouter.Modifiers

    @Test func plainTypingPassesToTextInput() {
        #expect(HardwareKeyRouter.route(keyCode: 4, charactersIgnoringModifiers: "a", modifiers: [])
            == .passToTextInput)
        #expect(HardwareKeyRouter.route(keyCode: 4, charactersIgnoringModifiers: "a", modifiers: .shift)
            == .passToTextInput)
    }

    @Test func returnEscapeArrowsSynthesize() {
        #expect(HardwareKeyRouter.route(keyCode: 40, charactersIgnoringModifiers: "\r", modifiers: [])
            == .sendKey(.enter))
        #expect(HardwareKeyRouter.route(keyCode: 88, charactersIgnoringModifiers: "\r", modifiers: [])
            == .sendKey(.enter))
        #expect(HardwareKeyRouter.route(keyCode: 41, charactersIgnoringModifiers: "", modifiers: [])
            == .sendKey(.escape))
        #expect(HardwareKeyRouter.route(keyCode: 82, charactersIgnoringModifiers: "", modifiers: [])
            == .sendKey(.arrowUp))
        #expect(HardwareKeyRouter.route(keyCode: 42, charactersIgnoringModifiers: "", modifiers: [])
            == .sendKey(.backspace))
    }

    @Test func controlChordsBecomeBytes() {
        #expect(HardwareKeyRouter.route(keyCode: 6, charactersIgnoringModifiers: "c", modifiers: .control)
            == .sendBytes(Data([0x03])))
        #expect(HardwareKeyRouter.route(keyCode: 15, charactersIgnoringModifiers: "l", modifiers: .control)
            == .sendBytes(Data([0x0C])))
        #expect(HardwareKeyRouter.route(keyCode: 47, charactersIgnoringModifiers: "[", modifiers: .control)
            == .sendBytes(Data([0x1B])))
        // Unmappable ctrl chord goes to the system rather than vanishing.
        #expect(HardwareKeyRouter.route(keyCode: 30, charactersIgnoringModifiers: "1", modifiers: .control)
            == .passToSystem)
    }

    @Test func altActsAsMeta() {
        #expect(HardwareKeyRouter.route(keyCode: 5, charactersIgnoringModifiers: "b", modifiers: .alternate)
            == .sendBytes(Data([0x1B, 0x62])))
    }

    @Test func commandShortcutsStayWithSystemExceptPasteAndEscape() {
        #expect(HardwareKeyRouter.route(keyCode: 25, charactersIgnoringModifiers: "v", modifiers: .command)
            == .paste)
        #expect(HardwareKeyRouter.route(keyCode: 6, charactersIgnoringModifiers: "c", modifiers: .command)
            == .passToSystem)
        #expect(HardwareKeyRouter.route(keyCode: 43, charactersIgnoringModifiers: "\t", modifiers: .command)
            == .passToSystem)
        // ⌘. is Escape by iPadOS convention (many iPad keyboards lack Esc).
        #expect(HardwareKeyRouter.route(keyCode: 55, charactersIgnoringModifiers: ".", modifiers: .command)
            == .sendKey(.escape))
        // …but only bare ⌘. — ⌘⇧. etc. stay with the system.
        #expect(HardwareKeyRouter.route(keyCode: 55, charactersIgnoringModifiers: ".", modifiers: [.command, .shift])
            == .passToSystem)
    }

    @Test func modifierOnlyPressesIgnored() {
        #expect(HardwareKeyRouter.route(keyCode: 0xE0, charactersIgnoringModifiers: "", modifiers: .control)
            == .passToSystem)
    }
}
