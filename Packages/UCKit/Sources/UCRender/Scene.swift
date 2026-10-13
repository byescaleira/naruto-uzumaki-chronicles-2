import Foundation
import simd

/// Mirrors `ModelVertex` in App/Shaders/Model.metal (64 bytes).
public struct SceneVertex: Sendable, Equatable {
    public var position: SIMD4<Float>
    public var normal: SIMD4<Float>
    /// Vertex colour (1 = neutral: the texel is left as is).
    public var color: SIMD4<Float>
    public var uv: SIMD2<Float>
    var padding: SIMD2<Float> = .zero

    public init(position: SIMD3<Float>, normal: SIMD3<Float>, uv: SIMD2<Float>, color: SIMD4<Float>) {
        self.position = SIMD4(position, 1)
        self.normal = SIMD4(normal, 0)
        self.color = color
        self.uv = uv
    }
}

/// Static geometry of one game model, uploaded to the GPU once (shared by every instance).
public final class SceneModel: Sendable {
    public struct Draw: Sendable, Equatable {
        public enum Blend: Sendable, Equatable {
            /// Alpha-tested and depth-written (the GS's 0x44 blend over a cut-out).
            case opaque
            /// Additive, depth-tested only (the environment pass, ALPHA 0x48).
            case additive
        }

        public var indices: Range<Int>
        /// Texture in ``SceneModel/textures``; `nil` draws the vertex colour only.
        public var texture: Int?
        public var blend: Blend

        public init(indices: Range<Int>, texture: Int?, blend: Blend) {
            self.indices = indices
            self.texture = texture
            self.blend = blend
        }
    }

    public struct Texture: Sendable {
        public let width: Int
        public let height: Int
        /// Straight-alpha sRGB RGBA8, top row first.
        public let rgba: [UInt8]
        /// CLAMP_1 WMS / WMT = 1: clamp instead of repeat.
        public let clampS: Bool
        public let clampT: Bool

        public init(width: Int, height: Int, rgba: [UInt8], clampS: Bool = false, clampT: Bool = false) {
            self.width = width
            self.height = height
            self.rgba = rgba
            self.clampS = clampS
            self.clampT = clampT
        }
    }

    public let name: String
    public let vertices: [SceneVertex]
    public let indices: [UInt32]
    public let draws: [Draw]
    public let textures: [Texture]
    public let boundsMin: SIMD3<Float>
    public let boundsMax: SIMD3<Float>

    public init(name: String, vertices: [SceneVertex], indices: [UInt32], draws: [Draw], textures: [Texture]) {
        self.name = name
        self.vertices = vertices
        self.indices = indices
        self.draws = draws
        self.textures = textures
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for v in vertices {
            let p = SIMD3(v.position.x, v.position.y, v.position.z)
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        boundsMin = vertices.isEmpty ? .zero : lo
        boundsMax = vertices.isEmpty ? .zero : hi
    }
}

public struct SceneInstance: Sendable {
    public var model: SceneModel
    public var transform: simd_float4x4

    public init(model: SceneModel, transform: simd_float4x4 = matrix_identity_float4x4) {
        self.model = model
        self.transform = transform
    }
}

/// What the 3D layer draws this frame. The game's world is Y-down (feet at y = 0, heads at
/// negative y); ``view`` is a world → camera transform in that space.
public struct SceneFrame: Sendable {
    public var instances: [SceneInstance]
    public var view: simd_float4x4
    /// Vertical field of view in radians; the aspect comes from the drawable.
    public var fieldOfView: Float
    public var near: Float
    public var far: Float
    /// Linear clear colour behind the scene.
    public var clearColor: SIMD3<Float>
    /// Direction the light travels, world space.
    public var lightDirection: SIMD3<Float>
    public var ambient: Float

    public init(instances: [SceneInstance], view: simd_float4x4, fieldOfView: Float = 0.9, near: Float = 1, far: Float = 4000,
                clearColor: SIMD3<Float> = .zero, lightDirection: SIMD3<Float> = SIMD3(-0.4, 0.8, -0.45),
                ambient: Float = 0.55) {
        self.instances = instances
        self.view = view
        self.fieldOfView = fieldOfView
        self.near = near
        self.far = far
        self.clearColor = clearColor
        self.lightDirection = lightDirection
        self.ambient = ambient
    }

    /// Right-handed camera space (−Z forward, +Y up) → Metal clip space, reversed depth
    /// (near → 1, far → 0) for precision over the long draw distances.
    public func projection(aspect: Float) -> simd_float4x4 {
        let y = 1 / tan(fieldOfView / 2), x = y / max(aspect, 1e-3)
        let a = near / (far - near), b = near * far / (far - near)
        return simd_float4x4(columns: (SIMD4(x, 0, 0, 0), SIMD4(0, y, 0, 0), SIMD4(0, 0, a, -1), SIMD4(0, 0, b, 0)))
    }

    /// A camera at `eye` looking at `target` in the game's Y-down world: the camera's up is
    /// world −Y.
    public static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>) -> simd_float4x4 {
        let forward = simd_normalize(target - eye)
        var right = simd_cross(forward, SIMD3(0, -1, 0))
        if simd_length(right) < 1e-5 { right = SIMD3(1, 0, 0) }
        right = simd_normalize(right)
        let up = simd_cross(right, forward)
        let rotation = simd_float4x4(rows: [
            SIMD4(right, -simd_dot(right, eye)),
            SIMD4(up, -simd_dot(up, eye)),
            SIMD4(-forward, simd_dot(forward, eye)),
            SIMD4(0, 0, 0, 1),
        ])
        return rotation
    }
}

/// Mirrors `ModelUniforms` in App/Shaders/Model.metal (160 bytes, 256-aligned in the ring).
struct ModelUniforms {
    var clipFromModel: simd_float4x4
    var worldFromModel: simd_float4x4
    /// xyz: direction towards the light (world), w: ambient.
    var light: SIMD4<Float>
    /// x: 1 when textured, y: clamp S, z: clamp T, w: 1 for additive.
    var flags: SIMD4<Float>

    static let stride = 256
}
