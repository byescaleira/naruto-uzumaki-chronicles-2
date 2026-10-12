import Foundation
import UCFormats
import UCRender

/// Game state advanced in fixed 60 Hz steps, independent of the display refresh.
///
/// The source disc is PAL (`VMODE = PAL` in SYSTEM.CNF, 50 Hz video); this reimplementation
/// ticks at 60 Hz, so per-frame constants recovered from the binary must be checked against
/// the frame rate they assume before reuse.
@MainActor
public final class GameRuntime {
    public static let tickRate = 60.0
    public static let tickDuration = 1.0 / tickRate

    public private(set) var tick: UInt64 = 0
    public private(set) var input = InputState()
    public let data: GameData?

    private let inputSource = InputSource()
    private var accumulator = 0.0
    private var lastHostTime: Double?

    public init(data: GameData?) {
        self.data = data
    }

    public var time: Double { Double(tick) * Self.tickDuration }

    /// Advances the simulation up to `hostTime` (seconds, display link clock).
    public func advance(to hostTime: Double) {
        defer { lastHostTime = hostTime }
        guard let last = lastHostTime else { return }
        // Clamp long stalls (app switch, breakpoint) instead of fast-forwarding.
        accumulator += min(hostTime - last, 0.25)
        while accumulator >= Self.tickDuration {
            input = inputSource.sample()
            step()
            accumulator -= Self.tickDuration
        }
    }

    private func step() {
        tick += 1
    }

    public func frame(output: HDROutput) -> FrameInput {
        FrameInput(time: time, output: output)
    }
}

/// The user's own disc contents, opened from the ISO mount or an extracted folder.
public struct GameData: Sendable {
    public let root: URL
    public let archive: DIGArchive

    /// `language` selects `CFC.DIG` (nil, Japanese voices) or `CFC_<code>.DIG`, as `FUN_00127300` does.
    public init(root: URL, language: String? = "UK") throws {
        self.root = root
        let name = language.map { "CFC_\($0).DIG" } ?? "CFC.DIG"
        archive = try DIGArchive(url: root.appending(path: name))
    }
}
