import Testing
@testable import UCEngine

/// Feeds `refreshes` presentation timestamps at `hz` (with optional jitter) and returns the
/// ticks the pacer asked for at each refresh, after a warm-up so the measured rate settles.
private func run(hz: Double, refreshes: Int, jitter: Double = 0, warmup: Int = 240,
                 pacer: inout FramePacer, start: inout Double) -> [Int] {
    var ticks: [Int] = []
    for i in 0 ..< warmup + refreshes {
        // Deterministic ±jitter pattern.
        let wobble = jitter * Double((i * 7919) % 5 - 2) / 2
        start += 1 / hz
        let n = pacer.ticks(at: start + wobble)
        if i >= warmup { ticks.append(n) }
    }
    return ticks
}

@Suite("Frame pacer")
struct FramePacerTests {
    @Test("60 Hz runs exactly one tick per refresh, even with timestamp jitter")
    func sixtyHertz() {
        var pacer = FramePacer(), t = 0.0
        let ticks = run(hz: 60, refreshes: 600, jitter: 0.0008, pacer: &pacer, start: &t)
        #expect(ticks.allSatisfy { $0 == 1 })
        #expect(pacer.isVsyncLocked)
    }

    @Test("120 Hz runs one tick every other refresh")
    func oneTwentyHertz() {
        var pacer = FramePacer(), t = 0.0
        let ticks = run(hz: 120, refreshes: 600, pacer: &pacer, start: &t)
        #expect(ticks.reduce(0, +) == 300)
        #expect(ticks.allSatisfy { $0 <= 1 })
        #expect(pacer.isVsyncLocked)
    }

    @Test("ProMotion falling back to 60 Hz keeps full game speed")
    func proMotionFallback() {
        var pacer = FramePacer(), t = 0.0
        _ = run(hz: 120, refreshes: 120, pacer: &pacer, start: &t)
        // Low Power Mode: the panel now delivers 60 Hz.
        let ticks = run(hz: 60, refreshes: 600, warmup: 120, pacer: &pacer, start: &t)
        #expect(ticks.reduce(0, +) == 600)
    }

    @Test("A missed vsync is made up instead of slowing the game")
    func missedVsync() {
        var pacer = FramePacer(), t = 0.0
        _ = run(hz: 60, refreshes: 60, pacer: &pacer, start: &t)
        t += 2.0 / 60 // one refresh never arrived
        #expect(pacer.ticks(at: t) == 2)
    }

    @Test("50 Hz and 30 Hz displays still run the game at 60 ticks per second")
    func offRates() {
        for hz in [50.0, 30.0] {
            var pacer = FramePacer(), t = 0.0
            let seconds = 10
            let ticks = run(hz: hz, refreshes: Int(hz) * seconds, pacer: &pacer, start: &t)
            #expect(abs(ticks.reduce(0, +) - 60 * seconds) <= 1, "\(hz) Hz")
            #expect(ticks.allSatisfy { $0 <= FramePacer.maxTicksPerRefresh })
        }
    }

    @Test("A long stall runs one tick instead of fast-forwarding")
    func stall() {
        var pacer = FramePacer(), t = 0.0
        _ = run(hz: 60, refreshes: 60, pacer: &pacer, start: &t)
        t += 0.8 // display mode switch, app switch, breakpoint
        #expect(pacer.ticks(at: t) == 1)
        // And the cadence resumes normally right after.
        let ticks = run(hz: 60, refreshes: 60, warmup: 0, pacer: &pacer, start: &t)
        #expect(ticks.allSatisfy { $0 == 1 })
    }
}
