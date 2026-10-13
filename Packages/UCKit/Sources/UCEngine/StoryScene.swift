import Foundation
import simd
import UCFormats
import UCRender

/// What a story episode needs on screen, decoded off the main actor.
public struct StoryAssets: Sendable {
    public let episode: EpisodeTable.Episode
    public let area: MapTable.Area
    /// The stage object `FUN_0016a1f0` binds (`[2]`, `[3]`, `[10]` of the area record).
    public let stage: [SceneModel]
    /// The party leader (`0119/00`, Naruto, for now: the party table `FUN_00182180` is next).
    public let player: SceneModel

    public static let naruto = ResourceHandle(entry: 119, subfile: 0)
}

extension GameData {
    /// `FUN_00137320` → `FUN_00165870` → `FUN_0016a1f0` for `episode`.
    public func storyAssets(episode id: Int) throws -> StoryAssets {
        let episodes = try EpisodeTable(try file(EpisodeTable.handle))
        let maps = try MapTable(try executable())
        guard let episode = episodes.episode(id == 0 ? EpisodeTable.newGame : id),
              let area = maps.area(map: episode.map, area: episode.area) else {
            throw StoryScene.Failure.unknownEpisode(id)
        }
        var stage: [SceneModel] = []
        for handle in area.stageModels where !handle.isNone {
            guard let bytes = try? file(handle), let model = try? SceneModel(name: "stage \(handle)", file: bytes) else { continue }
            stage.append(model)
        }
        let player = try SceneModel(name: "Naruto", file: try file(StoryAssets.naruto))
        return StoryAssets(episode: episode, area: area, stage: stage, player: player)
    }
}

/// A story area: the stage, the party leader walking on it and a follow camera.
///
/// Not yet the original's behaviour: the characters keep their rest pose (motions are not
/// decoded), there is no collision, and Start returns to SELECT MODE in place of the pause menu.
public struct StoryScene: Sendable {
    public enum Failure: Error, Equatable {
        case unknownEpisode(Int)
    }

    public let assets: StoryAssets
    public private(set) var position = SIMD3<Float>(0, 0, 0)
    /// Facing, radians about the vertical axis (0 = towards +Z).
    public private(set) var facing: Float = 0
    public private(set) var cameraYaw: Float = .pi
    private var previous = InputState()
    /// Set when the player asks to leave (Start); ``GameRuntime`` reads it.
    public var wantsToLeave = false

    /// Units per tick at full stick (Naruto is about 15 units tall).
    static let runSpeed: Float = 1.8
    static let cameraDistance: Float = 70
    static let cameraHeight: Float = 32
    static let cameraTurnSpeed: Float = 0.045
    /// The stage's walkable radius (`0507/00` spans ±210).
    static let arenaRadius: Float = 200

    public init(assets: StoryAssets) {
        self.assets = assets
    }

    public mutating func tick(_ input: InputState) {
        defer { previous = input }
        if input.buttons.subtracting(previous.buttons).contains(.start) { wantsToLeave = true }
        // Right stick turns the camera; otherwise it eases in behind the runner.
        if abs(input.rightStick.x) > 0.2 { cameraYaw -= input.rightStick.x * Self.cameraTurnSpeed }
        var stick = input.leftStick
        if simd_length(stick) < 0.2 { stick = .zero }
        guard stick != .zero else { return }
        let magnitude = min(1, simd_length(stick))
        // Stick up = away from the camera.
        let forward = SIMD2(-sin(cameraYaw), -cos(cameraYaw))
        let right = SIMD2(-forward.y, forward.x)
        let move = simd_normalize(forward * stick.y + right * stick.x) * magnitude * Self.runSpeed
        var next = position + SIMD3(move.x, 0, move.y)
        let flat = SIMD2(next.x, next.z)
        if simd_length(flat) > Self.arenaRadius {
            let clamped = simd_normalize(flat) * Self.arenaRadius
            next = SIMD3(clamped.x, 0, clamped.y)
        }
        position = next
        facing = atan2(move.x, move.y)
        if abs(input.rightStick.x) <= 0.2 {
            let behind = facing + .pi
            var delta = remainder(behind - cameraYaw, 2 * .pi)
            if abs(delta) > .pi * 0.9 { delta = 0 }
            cameraYaw += delta * 0.03 * magnitude
        }
    }

    public func frame() -> SceneFrame {
        // Y-down world: "up" is −Y.
        let eye = position + SIMD3(sin(cameraYaw) * Self.cameraDistance, -Self.cameraHeight, cos(cameraYaw) * Self.cameraDistance)
        let target = position + SIMD3(0, -9, 0)
        // Models face −Z in their own space.
        let player = SceneInstance(model: assets.player, transform: Self.translation(position) * Self.rotationY(facing + .pi))
        let stage = assets.stage.map { SceneInstance(model: $0) }
        return SceneFrame(instances: stage + [player], view: SceneFrame.lookAt(eye: eye, target: target))
    }

    static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(t, 1)
        return m
    }

    static func rotationY(_ angle: Float) -> simd_float4x4 {
        let c = cos(angle), s = sin(angle)
        return simd_float4x4(columns: (SIMD4(c, 0, -s, 0), SIMD4(0, 1, 0, 0), SIMD4(s, 0, c, 0), SIMD4(0, 0, 0, 1)))
    }
}
