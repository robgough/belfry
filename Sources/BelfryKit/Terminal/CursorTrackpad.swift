import CoreGraphics
import Foundation

// Cursor-trackpad math: long-press + drag (on the terminal or the spacebar's
// floating cursor) becomes arrow-key steps. Pure state machine — points in,
// key steps out — so the tuning is unit-testable without UIKit. The feel
// constants follow Remux's published tuning, which is the best-tested touch
// arrow-steering shipping today: axis lock with a dual-condition late switch,
// an analog intensity ramp instead of stepped gears, and remainder carry so
// coalesced UIKit updates never drop travel.

struct CursorTrackpadMath {
    enum Axis: Equatable { case horizontal, vertical }

    /// Finger travel (points) before an axis is chosen and steps begin.
    static let deadband: CGFloat = 12
    /// Switching axes mid-drag needs BOTH this much orthogonal travel since
    /// the lock AND 3× dominance over the locked axis — a 1pt wobble on a
    /// slow drag must never flip the axis.
    static let axisSwitchTravel: CGFloat = 12
    static let axisSwitchDominance: CGFloat = 3
    /// Points of travel per arrow step, per axis (rows are taller than cells
    /// are wide, so vertical steps are coarser).
    static let horizontalStep: CGFloat = 10
    static let verticalStep: CGFloat = 18
    /// Intensity ramps from 0 at 30pt total displacement to 1 at 100pt,
    /// scaling step density up to 3× — continuous analog steering, not gears.
    static let rampStart: CGFloat = 30
    static let rampEnd: CGFloat = 100
    static let maxDensity: CGFloat = 3
    /// Cap steps per update; the remainder carries to the next callback.
    static let maxStepsPerUpdate = 6

    private(set) var axis: Axis?
    /// 0…1 — how far up the ramp the drag currently is (drives repeat cadence).
    private(set) var intensity: CGFloat = 0

    private var start: CGPoint
    private var last: CGPoint
    /// Travel along each axis since the axis lock (for the late-switch test).
    private var travelSinceLock: CGVector = .init(dx: 0, dy: 0)
    /// Sub-step accumulator along the locked axis.
    private var accumulator: CGFloat = 0

    init(start: CGPoint) {
        self.start = start
        self.last = start
    }

    /// Feed a new touch location; returns the arrow steps to emit now.
    /// `steps < 0` means left/up, `> 0` right/down along the locked axis.
    mutating func update(to point: CGPoint) -> (axis: Axis, steps: Int)? {
        let delta = CGPoint(x: point.x - last.x, y: point.y - last.y)
        last = point
        let displacement = CGPoint(x: point.x - start.x, y: point.y - start.y)

        if axis == nil {
            guard max(abs(displacement.x), abs(displacement.y)) >= Self.deadband else { return nil }
            axis = abs(displacement.x) >= abs(displacement.y) ? .horizontal : .vertical
            travelSinceLock = .init(dx: 0, dy: 0)
            accumulator = 0
        } else {
            // Post-lock travel only: the movement that *performed* the lock
            // must not count toward the late-switch dominance test.
            travelSinceLock.dx += abs(delta.x)
            travelSinceLock.dy += abs(delta.y)
            maybeSwitchAxis()
        }

        let magnitude = max(abs(displacement.x), abs(displacement.y))
        intensity = min(max((magnitude - Self.rampStart) / (Self.rampEnd - Self.rampStart), 0), 1)
        let density = 1 + (Self.maxDensity - 1) * intensity

        guard let axis else { return nil }
        let axisDelta = axis == .horizontal ? delta.x : delta.y
        let step = axis == .horizontal ? Self.horizontalStep : Self.verticalStep
        accumulator += axisDelta * density

        var steps = Int((accumulator / step).rounded(.towardZero))
        guard steps != 0 else { return nil }
        steps = min(max(steps, -Self.maxStepsPerUpdate), Self.maxStepsPerUpdate)
        accumulator -= CGFloat(steps) * step   // remainder carries
        return (axis, steps)
    }

    /// True once the drag has actually steered (an axis locked) — a long
    /// press that ends without steering falls through to other gestures
    /// (word/link preview).
    var didSteer: Bool { axis != nil }

    private mutating func maybeSwitchAxis() {
        guard let current = axis else { return }
        let orthogonal = current == .horizontal ? travelSinceLock.dy : travelSinceLock.dx
        let along = current == .horizontal ? travelSinceLock.dx : travelSinceLock.dy
        guard orthogonal >= Self.axisSwitchTravel,
              orthogonal >= along * Self.axisSwitchDominance else { return }
        axis = current == .horizontal ? .vertical : .horizontal
        travelSinceLock = .init(dx: 0, dy: 0)
        accumulator = 0
    }

    /// Held-direction auto-repeat cadence by intensity: a firmer displacement
    /// repeats faster. Initial delay before the first repeat is fixed.
    static let repeatInitialDelay: TimeInterval = 0.30
    static func repeatInterval(intensity: CGFloat) -> TimeInterval {
        switch intensity {
        case ..<0.34: 0.18
        case ..<0.67: 0.10
        default: 0.06
        }
    }

    static func key(axis: Axis, direction: Int) -> TerminalKey {
        switch (axis, direction < 0) {
        case (.horizontal, true): .arrowLeft
        case (.horizontal, false): .arrowRight
        case (.vertical, true): .arrowUp
        case (.vertical, false): .arrowDown
        }
    }
}
