import Foundation
import QuartzCore

/// Two fingers on the guest's Magic Trackpad. IDs 12...15 are reserved for hardware scrolling.
final class ScrollFingers {
    private static let spread: Float = 1100
    private static let xs: ClosedRange<Float> = (8134 * 0.12 + spread / 2)...(8134 * 0.88 - spread / 2)
    private static let ys: ClosedRange<Float> = (5206 * 0.15)...(5206 * 0.70)
    private static let frame = 1.0 / 120
    private static let quiet = 0.100
    private let now: () -> TimeInterval
    private var timer: DispatchSourceTimer?
    private var deadline: TimeInterval?
    private var lastInput: TimeInterval?
    private var stoppedAt: TimeInterval?
    private var pendingX = 0.0, pendingY = 0.0
    private var sampleTime: TimeInterval?
    private var lastDelivery: TimeInterval?
    private var lastStamp: TimeInterval?
    private var id: Int32 = 14
    private var down = false
    private var x: Float = 0, y: Float = 0
    private var stationarySince: TimeInterval?

    init(now: @escaping () -> TimeInterval = CACurrentMediaTime) { self.now = now }

    deinit { timer?.cancel() }

    func move(dx: Float, dy: Float, at time: TimeInterval) {
        guard dx.isFinite, dy.isFinite, dx != 0 || dy != 0 else { return }
        let arrival = now()
        if let lastInput, arrival - lastInput >= Self.quiet { end(at: stoppedAt ?? arrival) }
        lastInput = arrival
        stoppedAt = nil
        pendingX += Double(dx)
        pendingY += Double(dy)
        // A delayed batch gets one current report. A fresh sample keeps its hardware timestamp.
        let stamp = time.isFinite ? min(arrival, max(arrival - Self.frame, time)) : arrival
        sampleTime = max(sampleTime ?? stamp, stamp)
        schedule(at: max((lastDelivery ?? arrival - Self.frame) + Self.frame, arrival + 0.001))
    }

    func releaseSoon(at time: TimeInterval) {
        guard let lastInput, stoppedAt == nil else { return }
        // The axes also return to zero between reports during a continuous swipe.
        // Use the first zero as the lift timestamp only after the input stays quiet.
        stoppedAt = time.isFinite ? min(now(), max(lastInput, time)) : lastInput
    }

    private func schedule(at time: TimeInterval) {
        if let deadline, deadline <= time { return }
        if timer == nil {
            let source = DispatchSource.makeTimerSource(queue: .main)
            source.setEventHandler { [weak self] in self?.tick() }
            source.activate()
            timer = source
        }
        deadline = time
        timer?.schedule(deadline: .now() + max(0, time - now()), leeway: .microseconds(250))
    }

    func tick() {
        deadline = nil
        guard let lastInput else { return }
        let delivery = now()
        if delivery - lastInput >= Self.quiet {
            end(at: stoppedAt ?? delivery)
            return
        }
        if let sampleTime {
            let earliest = (lastDelivery ?? delivery - Self.frame) + Self.frame
            if delivery + 0.000_001 < earliest {
                schedule(at: earliest)
                return
            }
            // Keep timestamps apart even when GameController delivers several updates together.
            let stamp = min(delivery, max(sampleTime, (lastStamp ?? sampleTime - Self.frame) + Self.frame))
            let dt = min(2 * Self.frame, max(0, stamp - (lastStamp ?? stamp - Self.frame)))
            // Limit the speed the guest can infer from a single batched input. Discard excess
            // travel here so the next frame, or an immediate reversal, has no debt to pay back.
            let magnitude = max(abs(pendingX), abs(pendingY))
            if magnitude > 0 {
                let factor = min(1, 14400 * dt / magnitude)
                apply(dx: Float(pendingX * factor), dy: Float(pendingY * factor), at: stamp)
            }
            pendingX = 0
            pendingY = 0
            self.sampleTime = nil
            lastDelivery = delivery
            lastStamp = stamp
        }
        schedule(at: lastInput + Self.quiet)
    }

    func end(at time: TimeInterval? = nil) {
        let stamp = max(lastStamp ?? 0, time ?? now())
        if down { lift(stamp) }
        timer?.schedule(deadline: .distantFuture)
        deadline = nil
        lastInput = nil
        stoppedAt = nil
        sampleTime = nil
        pendingX = 0
        pendingY = 0
        lastDelivery = nil
        lastStamp = nil
    }

    private func apply(dx: Float, dy: Float, at time: TimeInterval) {
        if !down { place(dx: dx, dy: dy, at: max(0, time - Self.frame)) }
        let fx = dx == 0 ? 1 : ((dx > 0 ? Self.xs.upperBound : Self.xs.lowerBound) - x) / dx
        let fy = dy == 0 ? 1 : ((dy > 0 ? Self.ys.upperBound : Self.ys.lowerBound) - y) / dy
        let fraction = min(1, fx, fy)
        if fraction == 0, let since = stationarySince, time - since >= 0.024 {
            lift(max(since, time - Self.frame / 2))
            place(dx: dx, dy: dy, at: time)
            return
        }
        stationarySince = fraction == 0 ? (stationarySince ?? time) : nil
        x = min(max(x + fraction * dx, Self.xs.lowerBound), Self.xs.upperBound)
        y = min(max(y + fraction * dy, Self.ys.lowerBound), Self.ys.upperBound)
        send(phase: 1, time: time)
    }

    private func place(dx: Float, dy: Float, at time: TimeInterval) {
        x = abs(dx) > abs(dy) ? (dx > 0 ? Self.xs.lowerBound : Self.xs.upperBound) : 4067
        y = abs(dy) >= abs(dx) ? (dy > 0 ? Self.ys.lowerBound : Self.ys.upperBound) : 2603
        down = true
        send(phase: 0, time: time)
    }

    private func lift(_ time: TimeInterval) {
        send(phase: 2, time: time)
        down = false
        stationarySince = nil
        id = id == 14 ? 12 : 14
    }

    private func send(phase: Int32, time: TimeInterval) {
        let ms = UInt32(truncatingIfNeeded: Int64(time * 1000))
        henge_vm_scroll_pair(id, phase, Int32(x - Self.spread / 2), Int32(x + Self.spread / 2), Int32(y), ms)
    }
}
