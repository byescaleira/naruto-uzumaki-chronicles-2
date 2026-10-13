import Foundation
import Testing
@testable import UCEngine
import UCFormats
import UCRender

@Suite("High-resolution textures")
struct HighResolutionTests {
    @Test("Smaller textures in a padded atlas sample only their own corner")
    func uvScale() {
        let atlas = SpriteAtlas(textures: [
            (256, 256, [UInt8](repeating: 0, count: 256 * 256 * 4)),
            (128, 64, [UInt8](repeating: 0, count: 128 * 64 * 4)),
        ])
        #expect(atlas.uvScale(0) == SIMD2(1, 1))
        #expect(atlas.uvScale(1) == SIMD2(0.5, 0.25))
    }

    @Test("Upscaled atlases carry a full mip chain; the game's own textures one level")
    func mips() {
        let rgba = [UInt8](repeating: 255, count: 1024 * 512 * 4)
        #expect(SpriteAtlas(textures: [(1024, 512, rgba)], mipmapped: true).levelCount == 11)
        #expect(SpriteAtlas(textures: [(1024, 512, rgba)]).levelCount == 1)
    }

    @Test("Upscaled layers widen REGION_CLAMP back to half a pixel")
    func clamp() {
        let atlas = SpriteAtlas(textures: [(1024, 1024, []), (256, 256, [UInt8](repeating: 0, count: 256 * 256 * 4))], detail: [4, 1])
        #expect(atlas.clampWidening(0) == SIMD2(repeating: 1.5 / 1024))
        #expect(atlas.clampWidening(1) == .zero)
    }

    @Test("PNGs round-trip straight alpha exactly")
    func png() throws {
        var rgba = [UInt8](repeating: 0, count: 8 * 4 * 4)
        for i in rgba.indices { rgba[i] = UInt8((i * 37) & 0xFF) }
        let texture = DecodedTexture(width: 8, height: 4, rgba: rgba)
        let data = try #require(HighResolution.png(texture))
        let url = FileManager.default.temporaryDirectory.appending(path: "nuc2-hd-\(UUID().uuidString).png")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let back = try #require(HighResolution.decode(url))
        #expect(back.width == 8 && back.height == 4)
        #expect(back.rgba == rgba)
    }

    @Test("A sheet keeps the original texel space for upscaled textures")
    func sheetSizes() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "../../../../GameData").standardizedFileURL
        guard let data = try? GameData(url: root) else { return }
        var file = try data.titleSprites()
        let original = SpriteSheet(files: [file])
        let size = original.textureSizes[0][0]
        let hd = DecodedTexture(width: size.x * 4, height: size.y * 4,
                                rgba: [UInt8](repeating: 255, count: size.x * 4 * size.y * 4 * 4))
        file.highResolution[0] = hd
        let sheet = SpriteSheet(files: [file])
        #expect(sheet.textureSizes[0][0] == size)
        #expect(sheet.atlas.width == size.x * 4)
        #expect(sheet.atlas.mipmapped)
    }

    @Test("Package names match uc-tool's texture dumps")
    func paths() {
        #expect(HighResolution.path(entry: 40, subfile: 1, texture: 9) == "HD/0040_01_t09.png")
    }
}
