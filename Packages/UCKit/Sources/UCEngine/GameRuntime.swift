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

    private func step() {
        tick += 1
    }

    public func frame(output: HDROutput) -> FrameInput {
        FrameInput(time: time, output: output)
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
