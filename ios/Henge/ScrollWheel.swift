import Foundation

/// GameController reports the scroll axes separately. The guest mouse accepts whole wheel notches.
struct ScrollWheel {
    private struct Axis {
        var remainder = 0.0
        var lastInput: TimeInterval?
        var nextStep = 0.0

        mutating func step(_ delta: Double, at now: TimeInterval) -> Int32 {
            guard delta.isFinite, delta != 0 else { return 0 }
            if let lastInput, now - lastInput >= 0.1 || delta.sign != remainder.sign {
                remainder = 0
            }
            lastInput = now
            remainder += delta
            guard abs(remainder) >= 1 else { return 0 }
            guard now >= nextStep else {
                remainder = remainder.sign == .minus ? -1 : 1
                return 0
            }
            let step: Int32 = remainder < 0 ? -1 : 1
            remainder = remainder.truncatingRemainder(dividingBy: 1)
            nextStep = now + 1.0 / 24
            return step
        }
    }

    private var horizontal = Axis(), vertical = Axis()

    mutating func move(dx: Float, dy: Float, scale: Float, at now: TimeInterval) -> (x: Int32, y: Int32) {
        // Four units of hardware motion per notch at the default scroll speed.
        let gain = Double(scale) / 4
        return (horizontal.step(Double(dx) * gain, at: now), vertical.step(-Double(dy) * gain, at: now))
    }
}
