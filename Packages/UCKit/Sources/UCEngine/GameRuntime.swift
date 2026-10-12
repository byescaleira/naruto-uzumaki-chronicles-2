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
    public static let tickRate = FramePacer.tickRate
    public static let tickDuration = FramePacer.tickDuration

    public private(set) var tick: UInt64 = 0
    public private(set) var input = InputState()
    public let data: GameData?
    /// Pacing state, exposed for a performance readout (measured refresh, vsync lock).
    public private(set) var pacer = FramePacer()

    private let inputSource = InputSource()

    public init(data: GameData?) {
        self.data = data
    }

    public var time: Double { Double(tick) * Self.tickDuration }

    /// Advances the simulation for a refresh presented at `presentationTime`
    /// (seconds, display link clock); see ``FramePacer`` for the pacing rules.
    public func advance(to presentationTime: Double) {
        for _ in 0 ..< pacer.ticks(at: presentationTime) {
            input = inputSource.sample()
            step()
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
