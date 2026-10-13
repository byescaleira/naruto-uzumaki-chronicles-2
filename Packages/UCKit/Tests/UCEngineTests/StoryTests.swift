import Foundation
import simd
import Testing
@testable import UCEngine
import UCFormats
import UCRender

private let gameData: GameData? = {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appending(path: "../../../../GameData").standardizedFileURL
    return try? GameData(url: root)
}()

@Suite("Story mode")
struct StoryTests {
    @Test("Handles split into entry and sub-file")
    func handles() {
        let handle = ResourceHandle(0x01FB_0002)
        #expect(handle.entry == 507 && handle.subfile == 2)
        #expect(ResourceHandle(entry: 13, subfile: 1).raw == 0xD0001)
        #expect(ResourceHandle(0xFFFF_FFFF).isNone)
    }

    @Test("0x105 data tables: offsets, row counts and rows")
    func dataTable() throws {
        var bytes = [UInt8](repeating: 0, count: 0x30 + 0x14 + 2 * 4)
        bytes[0] = 0x05; bytes[1] = 0x01; bytes[8] = 1
        bytes[0x20] = 0x30
        bytes[0x30] = 2
        bytes[0x44] = 7; bytes[0x48] = 9
        let table = try DataTable(bytes)
        #expect(table.tables.count == 1 && table.tables[0].rows == 2)
        #expect(table.row(1, size: 4)?.first == 9)
        #expect(table.row(2, size: 4) == nil)
    }

    @Test("A new game starts episode 0xF on map 0x37, area 1, with the stage of 0507",
          .enabled(if: (try? gameData?.executable()) != nil, "needs the embedded game data with the executable"))
    func firstEpisode() throws {
        let data = try #require(gameData)
        let episodes = try EpisodeTable(try data.file(EpisodeTable.handle))
        #expect(episodes.episodes.count == 60)
        let first = try #require(episodes.episode(EpisodeTable.newGame))
        #expect(first.map == 0x37 && first.area == 1)
        let maps = try MapTable(try data.executable())
        let area = try #require(maps.area(map: 0x37, area: 1))
        #expect(area.stage == ResourceHandle(entry: 507, subfile: 0))
        #expect(area.stageModels.first == ResourceHandle(entry: 507, subfile: 0))
        #expect(area.areaData == ResourceHandle(entry: 508, subfile: 0))
        #expect(area.music == 0x53)
    }

    @Test("The stick moves the leader away from the camera and Start asks to leave",
          .enabled(if: (try? gameData?.executable()) != nil, "needs the embedded game data with the executable"))
    func walking() throws {
        let data = try #require(gameData)
        var scene = StoryScene(assets: try data.storyAssets(episode: 0))
        var input = InputState()
        input.leftStick = SIMD2(0, 1)
        for _ in 0 ..< 10 { scene.tick(input) }
        #expect(simd_length(scene.position) > 10)
        #expect(!scene.wantsToLeave)
        input = InputState()
        input.buttons = [.start]
        scene.tick(input)
        #expect(scene.wantsToLeave)
        #expect(scene.frame().instances.count == scene.assets.stage.count + 1)
    }

    @Test("GS MODULATE: model colours scale by 255/128, the default white stays neutral")
    func modulate() {
        #expect(SceneModel.modulate(SIMD4(1, 1, 1, 1)) == SIMD4(1, 1, 1, 1))
        let lit = SceneModel.modulate(SIMD4(0.25, 0.25, 0.25, 1))
        #expect(abs(lit.x - 0.25 * 255 / 128) < 1e-6 && lit.w == 1)
    }

    @Test("Reversed-Z projection: near maps to 1, far to 0")
    func projection() {
        let frame = SceneFrame(instances: [], view: matrix_identity_float4x4, near: 1, far: 100)
        let p = frame.projection(aspect: 16 / 9)
        func depth(_ z: Float) -> Float { let c = p * SIMD4(0, 0, -z, 1); return c.z / c.w }
        #expect(abs(depth(1) - 1) < 1e-5)
        #expect(abs(depth(100)) < 1e-5)
    }
}
