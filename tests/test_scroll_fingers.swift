import Foundation
import QuartzCore

private struct Contact {
    let id, phase, left, right, y: Int32
    let ms: UInt32
}

private var reports: [Contact] = []
func henge_vm_scroll_pair(_ id: Int32, _ phase: Int32, _ left: Int32, _ right: Int32, _ y: Int32, _ ms: UInt32) {
    reports.append(Contact(id: id, phase: phase, left: left, right: right, y: y, ms: ms))
}

@main
struct ScrollTests {
    static func testWheel() {
        var wheel = ScrollWheel()
        for i in 0..<3 {
            precondition(wheel.move(dx: 1, dy: 0, scale: 1, at: Double(i) / 120) == (0, 0))
        }
        precondition(wheel.move(dx: 1, dy: 4, scale: 1, at: 0.025) == (1, -1))
        for _ in 0..<1000 {
            precondition(wheel.move(dx: 80, dy: 160, scale: 1, at: 0.025) == (0, 0))
        }
        precondition(wheel.move(dx: 0, dy: 0, scale: 1, at: 0.07) == (0, 0))
        precondition(wheel.move(dx: -2, dy: -2, scale: 2, at: 0.075) == (-1, 1))
        precondition(wheel.move(dx: -2, dy: -2, scale: -2, at: 0.125) == (1, -1))

        wheel = ScrollWheel()
        precondition(wheel.move(dx: 3, dy: 0, scale: 1, at: 0) == (0, 0))
        precondition(wheel.move(dx: 1, dy: 4, scale: 1, at: 0.15) == (0, -1))
        precondition(wheel.move(dx: .nan, dy: .infinity, scale: 1, at: 0.16) == (0, 0))
        precondition(wheel.move(dx: 3, dy: 4, scale: 1, at: 0.17) == (1, 0))
        precondition(wheel.move(dx: 0, dy: -4, scale: 1, at: 0.20) == (0, 1))

        wheel = ScrollWheel()
        var steps = 0
        for i in 0..<120 {
            let (x, y) = wheel.move(dx: 0, dy: 200, scale: 1, at: Double(i) / 120)
            precondition(x == 0 && (y == 0 || y == -1))
            if y != 0 { steps += 1 }
        }
        precondition((20...24).contains(steps))
        print("Wheel: \(steps) one-notch steps for 120 samples in one second; burst, reversal, speed and idle reset passed")
    }

    static func main() {
        testWheel()
        var clock = 100.0
        let fingers = ScrollFingers(now: { clock })
        // 30 Hz with a zero between samples is one slow swipe, even on a busy main queue.
        for i in 0..<30 {
            clock = 100 + Double(i) / 30
            fingers.move(dx: 0, dy: 34, at: clock)
            fingers.releaseSoon(at: clock + 0.001)
            clock += 0.002
            fingers.tick()
        }
        clock += 0.110
        fingers.tick()
        precondition(reports.map(\.phase) == [0] + Array(repeating: Int32(1), count: 30) + [2])
        precondition(reports[30].y - reports[0].y == 1020)

        // Both axes of each hardware sample arrive separately. At the edge the
        // guest sees a stationary pair before a lift, and a fresh pair before motion.
        reports.removeAll()
        for i in 0..<150 {
            clock = 200 + Double(i) / 120
            fingers.move(dx: 0, dy: 88, at: clock)
            fingers.move(dx: 12, dy: 0, at: clock)
            fingers.releaseSoon(at: clock)
            clock += 0.001
            fingers.tick()
        }
        fingers.end(at: clock + 0.005)
        var previous: Contact?
        var moving = 0, grips = 0
        for report in reports {
            precondition(report.right - report.left == 1100 && (12...15).contains(report.id))
            if report.phase == 2 { previous = nil; continue }
            if report.phase == 0 { precondition(previous == nil); grips += 1 }
            if let p = previous {
                precondition(p.id == report.id && report.phase == 1 && (7...10).contains(report.ms - p.ms))
                let dx = report.left - p.left, dy = report.y - p.y
                precondition((0...12).contains(dx) && (0...88).contains(dy))
                if dx > 0 || dy > 0 { moving += 1 }
            }
            previous = report
        }
        precondition(previous == nil && grips > 1 && moving > 125)

        // A stalled main queue can deliver many callbacks at once with the same
        // profile timestamp. Limit the first frame and react immediately to a reversal.
        reports.removeAll()
        clock = 300
        for _ in 0..<100 { fingers.move(dx: 0, dy: 40, at: clock - 0.030) }
        clock += 0.001
        fingers.tick()
        precondition(reports.map(\.phase) == [0, 1])
        let burstTravel = reports[1].y - reports[0].y
        precondition((119...121).contains(burstTravel))
        clock += 0.010
        fingers.move(dx: 0, dy: -20, at: clock)
        fingers.tick()
        precondition(reports.count == 3 && reports[2].y - reports[1].y == -20)
        // No old movement is paid out after the reversal or on a delayed wake.
        clock += 0.012
        fingers.move(dx: 0, dy: 800, at: clock)
        clock += 0.150
        fingers.tick()
        precondition(reports.map(\.phase) == [0, 1, 1, 2])

        // Drive the real one-shot main-queue timer through motion, lift, and restart.
        reports.removeAll()
        let live = ScrollFingers()
        for _ in 0..<2 {
            live.move(dx: 16, dy: 0, at: CACurrentMediaTime())
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.18))
        }
        precondition(reports.map(\.phase) == [0, 1, 2, 0, 1, 2])
        print("One gesture at 30 Hz; 150 two-axis samples at 120 Hz; burst travel \(burstTravel) units; reversal, delayed delivery and timer restart passed")
    }
}
