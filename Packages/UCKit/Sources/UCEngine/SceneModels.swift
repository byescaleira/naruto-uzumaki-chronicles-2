import Foundation
import simd
import UCFormats
import UCRender

extension SceneModel {
    /// A game model file (character, stage or object: a ``SectionedFile`` with the model in
    /// section 0 and its textures in section 1) as static geometry in `pose` (rest pose by
    /// default).
    ///
    /// Stage objects draw their only pass with the program the characters use for the
    /// environment overlay (MSCAL 0x5C); when a model has no base pass that one is drawn opaque.
    public convenience init(name: String, file bytes: [UInt8], pose: [simd_float4x4]? = nil) throws {
        guard let file = SectionedFile(bytes), let section = file.section(.model) else {
            throw ModelFile.Failure.invalidHeader
        }
        let model = try ModelFile(section)
        let table = try file.section(.textures).map { try ModelTextureTable($0) }
        let geometry = try ModelGeometry(model: model, pose: pose, passes: [.base, .environment])
        let hasBase = geometry.meshes.contains { $0.pass == .base }

        var textureIndex: [Int: Int] = [:]
        var textures: [Texture] = []
        func texture(_ material: Int?) -> Int? {
            guard let material, let table else { return nil }
            if let known = textureIndex[material] { return known }
            guard let decoded = table.decodeTexture(material) else { return nil }
            let state = material < table.materials.count ? table.materials[material] : nil
            textures.append(Texture(width: decoded.width, height: decoded.height, rgba: decoded.rgba,
                                    clampS: state?.wrapS == 1, clampT: state?.wrapT == 1))
            textureIndex[material] = textures.count - 1
            return textures.count - 1
        }

        var vertices: [SceneVertex] = []
        var indices: [UInt32] = []
        var draws: [Draw] = []
        for mesh in geometry.meshes where !mesh.indices.isEmpty {
            let base = UInt32(vertices.count)
            vertices.append(contentsOf: mesh.vertices.map {
                SceneVertex(position: $0.position, normal: $0.normal, uv: $0.uv, color: Self.modulate($0.color))
            })
            let start = indices.count
            indices.append(contentsOf: mesh.indices.map { $0 + base })
            draws.append(Draw(indices: start ..< indices.count, texture: texture(mesh.material),
                              blend: mesh.pass == .environment && hasBase ? .additive : .opaque))
        }
        self.init(name: name, vertices: vertices, indices: indices, draws: draws, textures: textures)
    }

    /// GS MODULATE: `texel · RGB / 0x80`. ``ModelMesh`` colours are bytes / 255, so a colour set by
    /// the model (MSCAL 0x24 / 0x28, e.g. the baked lighting of stage floors) becomes
    /// `rgb · 255 / 128`; the default white (no colour set) stays neutral.
    static func modulate(_ color: SIMD4<Float>) -> SIMD4<Float> {
        guard SIMD3(color.x, color.y, color.z) != SIMD3(repeating: 1) else { return color }
        return SIMD4(SIMD3(color.x, color.y, color.z) * (255.0 / 128.0), color.w)
    }
}
