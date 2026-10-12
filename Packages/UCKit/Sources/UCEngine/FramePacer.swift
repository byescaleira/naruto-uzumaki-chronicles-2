/// Decides how many 60 Hz game ticks to run for each display refresh.
///
/// The game always advances by real time, never by the refresh the device advertises: a
/// ProMotion panel can deliver 60 Hz in Low Power Mode, an Apple TV can sit at 50 Hz, and a
/// display mode switch stalls the link for a moment.
///
/// - Near 60 Hz or 120 Hz the pacer locks to vsync, giving exactly one tick per refresh (or per
///   two at 120 Hz), so floating-point drift never produces 0/2-tick judder. Missed refreshes
///   are counted so a dropped frame doesn't slow the game.
/// - Anywhere else (50 Hz, 30 Hz, variable) it follows the clock.
/// - Catch-up is capped and the backlog is dropped after a stall instead of fast-forwarding.
public struct FramePacer: Sendable {
    public static let tickRate = 60.0
    public static let tickDuration = 1.0 / tickRate
    /// Most ticks run in one refresh (covers 24–30 Hz displays without spiralling).
    public static let maxTicksPerRefresh = 3
    /// A refresh gap longer than this is a stall: run one tick and start over.
    public static let stallThreshold = 0.1

    public private(set) var refreshInterval = FramePacer.tickDuration
    public private(set) var isVsyncLocked = false
    private var lastTime: Double?
    private var vsyncCounter = 0
    private var accumulator = 0.0

    public init() {}

    /// Measured display refresh rate (Hz), smoothed.
    public var refreshRate: Double { 1 / refreshInterval }

    /// Ticks to run for a refresh presented at `time` (seconds, monotonic).
    public mutating func ticks(at time: Double) -> Int {
        guard let last = lastTime else {
            lastTime = time
            return 1
        }
        lastTime = time
        let dt = max(0, time - last)
        if dt > Self.stallThreshold {
            vsyncCounter = 0
            accumulator = 0
            return 1
        }
        // Smooth the measured interval per refresh: a gap spanning missed vsyncs counts as
        // that many refreshes, so a dropped frame doesn't look like a slower display.
        let refreshes = max(1, Int((dt / refreshInterval).rounded()))
        let sample = dt / Double(refreshes)
        if sample > 0.002, sample < 0.05 {
            refreshInterval += (sample - refreshInterval) * 0.05
        }

        let ratio = Self.tickDuration / refreshInterval        // refreshes per tick
        let refreshesPerTick = max(1, Int(ratio.rounded()))
        let deviation = abs(ratio - Double(refreshesPerTick)) / Double(refreshesPerTick)
        // Hysteresis keeps a jittery refresh from flipping between modes.
        isVsyncLocked = refreshesPerTick <= 2 && deviation < (isVsyncLocked ? 0.008 : 0.004)

        if isVsyncLocked {
            accumulator = 0
            vsyncCounter += refreshes
            let ticks = vsyncCounter / refreshesPerTick
            vsyncCounter %= refreshesPerTick
            return min(ticks, Self.maxTicksPerRefresh)
        }

        vsyncCounter = 0
        accumulator += dt
        // The epsilon keeps exact multiples (2/60 s) from rounding down to one tick less.
        let ticks = min(Int(accumulator / Self.tickDuration + 1e-6), Self.maxTicksPerRefresh)
        accumulator -= Double(ticks) * Self.tickDuration
        // Never carry more than one tick of debt into the next refresh.
        if accumulator > Self.tickDuration { accumulator = 0 }
        return ticks
    }
}
