import SwiftUI
import UIKit

// The cursor-trackpad driver: owns a CursorTrackpadMath state machine, emits
// arrow keys through the workspace's key path, auto-repeats while the finger
// holds a displacement, and shows a small HUD chip over the terminal. Driven
// from two entry points: a long-press+drag on the terminal view, and the
// system keyboard's spacebar floating cursor (via the UITextInput shim).

@MainActor
final class CursorTrackpadDriver {
    private weak var view: BelfryGhosttySurfaceView?
    private var math: CursorTrackpadMath?
    private var lastDirection: (axis: CursorTrackpadMath.Axis, sign: Int)?
    private var repeatTimer: Timer?
    private var hud: UILabel?

    init(view: BelfryGhosttySurfaceView) {
        self.view = view
    }

    var isActive: Bool { math != nil }
    var didSteer: Bool { math?.didSteer ?? false }

    func begin(at point: CGPoint) {
        math = CursorTrackpadMath(start: point)
        lastDirection = nil
        Haptics.tap()
    }

    func update(to point: CGPoint) {
        guard var math else { return }
        let hadAxis = math.didSteer
        if let emit = math.update(to: point) {
            if !hadAxis { Haptics.selection() }   // axis just locked
            send(axis: emit.axis, steps: emit.steps)
            lastDirection = (emit.axis, emit.steps < 0 ? -1 : 1)
            scheduleRepeat(after: CursorTrackpadMath.repeatInitialDelay, intensity: math.intensity)
            showHUD(axis: emit.axis, sign: emit.steps < 0 ? -1 : 1)
        }
        self.math = math
    }

    func end() {
        math = nil
        lastDirection = nil
        repeatTimer?.invalidate()
        repeatTimer = nil
        hideHUD()
    }

    private func send(axis: CursorTrackpadMath.Axis, steps: Int) {
        guard let view else { return }
        let key = CursorTrackpadMath.key(axis: axis, direction: steps).terminiKey
        for _ in 0..<abs(steps) {
            view.sendKey(key)
        }
    }

    /// Held-direction auto-repeat: one key per tick, deadline measured from
    /// the actual send so a slow main thread never "catches up" with a burst.
    private func scheduleRepeat(after delay: TimeInterval, intensity: CGFloat) {
        repeatTimer?.invalidate()
        repeatTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, let math = self.math, let direction = self.lastDirection else { return }
                self.send(axis: direction.axis, steps: direction.sign)
                self.scheduleRepeat(
                    after: CursorTrackpadMath.repeatInterval(intensity: math.intensity),
                    intensity: math.intensity)
            }
        }
    }

    // MARK: HUD

    private func showHUD(axis: CursorTrackpadMath.Axis, sign: Int) {
        guard let view else { return }
        let label = hud ?? {
            let label = UILabel()
            label.font = .systemFont(ofSize: 22, weight: .semibold)
            label.textColor = .white
            label.textAlignment = .center
            label.backgroundColor = UIColor.black.withAlphaComponent(0.55)
            label.layer.cornerRadius = 22
            label.layer.masksToBounds = true
            label.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
            view.addSubview(label)
            hud = label
            return label
        }()
        label.center = CGPoint(x: view.bounds.midX, y: view.bounds.minY + 60)
        label.text = switch (axis, sign < 0) {
        case (.horizontal, true): "←"
        case (.horizontal, false): "→"
        case (.vertical, true): "↑"
        case (.vertical, false): "↓"
        }
    }

    private func hideHUD() {
        hud?.removeFromSuperview()
        hud = nil
    }
}

// MARK: - Gesture + text-input entry points

extension BelfryGhosttySurfaceView {
    /// Install the long-press trackpad gesture. A press that ends without
    /// steering falls through to `onLongPressToken` (link/path preview).
    func installTrackpad(onLongPressToken: @escaping (CGPoint) -> Void) {
        let driver = CursorTrackpadDriver(view: self)
        trackpadDriver = driver
        self.onLongPressToken = onLongPressToken
        let press = UILongPressGestureRecognizer(target: self, action: #selector(handleTrackpadPress(_:)))
        press.minimumPressDuration = 0.45
        press.delegate = self
        addGestureRecognizer(press)
    }

    @objc private func handleTrackpadPress(_ gesture: UILongPressGestureRecognizer) {
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began:
            trackpadDriver?.begin(at: point)
        case .changed:
            trackpadDriver?.update(to: point)
        case .ended, .cancelled, .failed:
            let steered = trackpadDriver?.didSteer ?? false
            trackpadDriver?.end()
            if !steered, gesture.state == .ended {
                onLongPressToken?(point)
            }
        default:
            break
        }
    }
}
