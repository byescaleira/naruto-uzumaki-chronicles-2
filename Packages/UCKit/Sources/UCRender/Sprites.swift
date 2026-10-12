import Foundation
import simd

/// GS `ALPHA_1` modes the 2D layer uses (`FUN_00260a40`: piece blend 0/1/2 → 0x44/0x48/0x42).
public enum SpriteBlend: UInt8, Sendable {
    /// 0x44: (Cs − Cd)·As + Cd.
    case blend = 0
    /// 0x48: Cs·As + Cd.
    case add = 1
    /// 0x42: Cd − Cs·As.
    case subtract = 2
}

/// One textured quad in the game's 2D space: x right, y down, origin at the screen centre,
/// 512 × 448 visible on the original 4:3 display (the PAL build scales y by 8/7 itself).
public struct SpriteQuad: Sendable, Equatable {
    /// Corners in TRIFAN order: top-left, top-right, bottom-right, bottom-left (before transforms).
    public var corners: (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)
    /// Texture coordinates of the first and third corner (`s0, t0, s1, t1`), normalised.
    public var uv: SIMD4<Float>
    /// REGION_CLAMP as a normalised rect of sample positions (`s min, t min, s max, t max`).
    public var clamp: SIMD4<Float>
    /// MODULATE vertex colour in PS2 units (1 = 0x80): rgb scales the texel, a its alpha.
    public var color: SIMD4<Float>
    /// Texture (layer) in the atlas.
    public var texture: UInt32
    public var blend: SpriteBlend

    public init(corners: (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>, SIMD2<Float>), uv: SIMD4<Float>,
                clamp: SIMD4<Float>, color: SIMD4<Float>, texture: UInt32, blend: SpriteBlend) {
        self.corners = corners
        self.uv = uv
        self.clamp = clamp
        self.color = color
        self.texture = texture
        self.blend = blend
    }

    public static func == (a: SpriteQuad, b: SpriteQuad) -> Bool {
        a.corners.0 == b.corners.0 && a.corners.1 == b.corners.1 && a.corners.2 == b.corners.2
            && a.corners.3 == b.corners.3 && a.uv == b.uv && a.clamp == b.clamp && a.color == b.color
            && a.texture == b.texture && a.blend == b.blend
    }
}

/// The textures of one sprite file, decoded once and uploaded once as a 2D array
/// (`rgba8Unorm_srgb`: the game's art is display-referred sRGB).
public final class SpriteAtlas: Sendable {
    public let width: Int
    public let height: Int
    /// One straight-alpha RGBA8 image of `width × height` per layer.
    public let layers: [[UInt8]]
    /// Each source texture's size, for normalising texel coordinates.
    public let sizes: [SIMD2<Int>]

    /// Pads every texture to the largest size (texture coordinates stay in each texture's own space).
    public init(textures: [(width: Int, height: Int, rgba: [UInt8])]) {
        let w = max(1, textures.map(\.width).max() ?? 1), h = max(1, textures.map(\.height).max() ?? 1)
        width = w
        height = h
        sizes = textures.map { SIMD2($0.width, $0.height) }
        layers = textures.map { texture in
            if texture.width == w, texture.height == h { return texture.rgba }
            var padded = [UInt8](repeating: 0, count: w * h * 4)
            for y in 0 ..< texture.height {
                let row = texture.rgba[(y * texture.width * 4) ..< ((y + 1) * texture.width * 4)]
                padded.replaceSubrange((y * w * 4) ..< (y * w * 4 + texture.width * 4), with: row)
            }
            return padded
        }
    }
}

/// What the 2D layer draws this frame.
public struct SpriteFrame: Sendable {
    public var atlas: SpriteAtlas
    public var quads: [SpriteQuad]
    public var canvas: SpriteCanvas
    /// Scene colour behind the sprites (linear; the GS frame buffer is cleared to black).
    public var clearColor: SIMD3<Float>

    public init(atlas: SpriteAtlas, quads: [SpriteQuad], canvas: SpriteCanvas = SpriteCanvas(), clearColor: SIMD3<Float> = .zero) {
        self.atlas = atlas
        self.quads = quads
        self.canvas = canvas
        self.clearColor = clearColor
    }
}

/// Maps the game's 2D space onto a drawable of any shape without stretching.
///
/// The original frame is 512 × 448 logical pixels shown on a 4:3 TV, so a logical pixel is
/// 7:6 wide (`pixelAspect`). The canvas covers the drawable: the full 448 lines fill the height
/// and wider screens show more of the horizontal space the game already draws into (its menu
/// backgrounds are built wider than 512); narrower ones crop the sides symmetrically.
public struct SpriteCanvas: Sendable, Equatable {
    public var size: SIMD2<Float>
    public var pixelAspect: Float

    public init(size: SIMD2<Float> = SIMD2(512, 448), pixelAspect: Float = 7.0 / 6.0) {
        self.size = size
        self.pixelAspect = pixelAspect
    }

    /// Logical rect visible on a drawable of `width × height` pixels: `(half width, half height)`.
    public func visibleHalfExtent(width: Int, height: Int) -> SIMD2<Float> {
        let aspect = Float(max(width, 1)) / Float(max(height, 1))
        let nativeAspect = size.x * pixelAspect / size.y
        if aspect >= nativeAspect {
            return SIMD2(size.y * aspect / pixelAspect, size.y) * 0.5
        }
        return SIMD2(size.x, size.x * pixelAspect / aspect) * 0.5
    }

    /// `ndc = p · scale + offset` for a drawable of `width × height`.
    public func transform(width: Int, height: Int) -> SpriteUniforms {
        let half = visibleHalfExtent(width: width, height: height)
        return SpriteUniforms(scale: SIMD2(1 / half.x, -1 / half.y), offset: .zero)
    }
}

/// Mirrors `SpriteUniforms` in App/Shaders/Sprite.metal (16 bytes).
public struct SpriteUniforms: Sendable, Equatable {
    public var scale: SIMD2<Float>
    public var offset: SIMD2<Float>
}

/// Mirrors `SpriteInstance` in App/Shaders/Sprite.metal (96 bytes).
struct SpriteInstance {
    var p0: SIMD2<Float>, p1: SIMD2<Float>, p2: SIMD2<Float>, p3: SIMD2<Float>
    var uv: SIMD4<Float>
    var clamp: SIMD4<Float>
    var color: SIMD4<Float>
    var layer: UInt32
    var padding: SIMD3<UInt32> = .zero

    init(_ quad: SpriteQuad) {
        p0 = quad.corners.0; p1 = quad.corners.1; p2 = quad.corners.2; p3 = quad.corners.3
        uv = quad.uv
        clamp = quad.clamp
        // MODULATE happens on display-referred values; scale the colour in that space, then
        // linearise the factor so a neutral 0x80 vertex leaves the texel untouched.
        let rgb = SIMD3(quad.color.x, quad.color.y, quad.color.z)
        let linear = simd_max(rgb, SIMD3<Float>(repeating: 0))
        color = SIMD4(powf(linear.x, 2.2), powf(linear.y, 2.2), powf(linear.z, 2.2), quad.color.w)
        layer = quad.texture
    }
}

/// Runs of consecutive quads sharing a blend mode, in draw order.
func spriteBatches(_ quads: [SpriteQuad]) -> [(blend: SpriteBlend, range: Range<Int>)] {
    var batches: [(blend: SpriteBlend, range: Range<Int>)] = []
    var start = 0
    for i in quads.indices where i > start && quads[i].blend != quads[start].blend {
        batches.append((quads[start].blend, start ..< i))
        start = i
    }
    if start < quads.count { batches.append((quads[start].blend, start ..< quads.count)) }
    return batches
}
