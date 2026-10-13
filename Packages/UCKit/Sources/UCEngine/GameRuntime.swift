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
    /// Pacing state, exposed for a performance readout (measured refresh, vsync lock).
    public private(set) var pacer = FramePacer()

    private let inputSource = InputSource()

    /// The menus (title, SELECT MODE), advanced each tick and drawn by the renderer's sprite
    /// pass. Set it once the game data is loaded.
    public var frontEnd: FrontEnd?
    /// Plays what ``frontEnd`` asks for.
    public weak var audio: (any GameAudio)?
    /// The story scene, when one runs: it takes the screen and the pad from ``frontEnd``.
    public var story: StoryScene?

    public init() {}

    public var time: Double { Double(tick) * Self.tickDuration }

    /// Advances the simulation for a refresh presented at `presentationTime`
    /// (seconds, display link clock); see ``FramePacer`` for the pacing rules.
    public func advance(to presentationTime: Double) {
        for _ in 0 ..< pacer.ticks(at: presentationTime) {
            input = inputSource.sample()
            step()
        }
    }

    /// A tap or click at `point` on a surface of `size` (both in the view's points, origin at the
    /// top-left). Mapped through the same canvas transform the sprite pass draws with, so it
    /// lands on what is under the finger on any screen shape.
    public func tap(at point: SIMD2<Float>, in size: SIMD2<Float>) {
        // Touch controls for the 3D scenes are not there yet; a tap must not act as Start.
        guard story == nil else { return }
        guard frontEnd != nil, size.x > 0, size.y > 0 else {
            press([.cross, .start])
            return
        }
        let canvas = SpriteCanvas()
        let half = canvas.visibleHalfExtent(width: Int(size.x * 4), height: Int(size.y * 4))
        let normalized = point / size * 2 - 1
        frontEnd?.tap(at: normalized * half)
    }

    /// A short press from touch or a click (held for a few ticks, then released).
    public func press(_ buttons: InputState.Buttons = [], stick: SIMD2<Float> = .zero) {
        inputSource.press(buttons, stick: stick)
    }

    private func step() {
        tick += 1
        if var scene = story {
            scene.tick(input)
            story = scene
            if scene.wantsToLeave {
                story = nil
                audio?.handle(.fadeOutAudio(frames: 0))
                frontEnd?.returnToModeSelect()
            }
            return
        }
        guard var menus = frontEnd else { return }
        let events = menus.tick(input, voiceIdle: audio?.isVoiceIdle ?? true)
        frontEnd = menus
        for event in events { audio?.handle(event) }
    }

    public func frame(output: HDROutput) -> FrameInput {
        if let story {
            return FrameInput(time: time, output: output, scene: story.frame())
        }
        return FrameInput(time: time, output: output, sprites: frontEnd?.screen.frame())
    }
}

/// The user's own disc, opened in place from the `.iso` (or a folder with its files).
public struct GameData: Sendable {
    public let disc: DiscImage
    public let archive: DIGArchive
    public let language: String

    /// Archives on the PAL disc: `CFC_<code>.DIG` (text + English voices) per language, as
    /// selected by `FUN_00127300`.
    public static let languages = ["UK", "FR", "DE", "ES", "IT"]

    /// Opens `CFC_<language>.DIG`; when the data doesn't carry that language (the embedded
    /// package ships English only), falls back to English.
    public init(disc: DiscImage, language: String = GameData.preferredLanguage) throws {
        try disc.validate()
        self.disc = disc
        let chosen = disc.files["CFC_\(language).DIG"] != nil ? language : "UK"
        self.language = chosen
        archive = try DIGArchive(file: try disc.file("CFC_\(chosen).DIG"))
    }

    public init(url: URL) throws {
        try self.init(disc: try DiscImage(url: url))
    }

    /// The device language when the disc has it, English otherwise.
    public static var preferredLanguage: String {
        let code = Locale.current.language.languageCode?.identifier.uppercased() ?? "EN"
        return languages.contains(code) ? code : "UK"
    }

    /// Character-select face atlas (entry 39, sub-file 0, texture 1): Naruto, Choji, Sakura,
    /// Gaara, Kankuro and Rock Lee, decoded from the disc.
    public func characterFaces() throws -> DecodedTexture? {
        let entry = archive.entries[39]
        let data = try archive.read(entry)
        let table = DIGSubfileTable(data, count: Int(entry.subfileCount))
        guard let subfile = table.subfiles.first(where: { $0.index == 0 }) else { return nil }
        let textures = TextureSet.decode(Array(table.slice(subfile, of: data)))
        return textures.count > 1 ? textures[1] : nil
    }
}
