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
    /// Each texture's size in pixels (its top-left corner of the padded layer).
    public let sizes: [SIMD2<Int>]
    /// Upload with a mipmap chain (generated on the GPU): set for high-resolution textures,
    /// which are drawn smaller than their pixels on most screens. The game's own 2D textures are
    /// magnified only. Their transparent texels carry their neighbours' colour (see `uc-tool`'s
    /// texture upscaler), so straight-alpha filtering does not darken the cut-out edges.
    public let mipmapped: Bool

    /// Pads every texture to the largest size; ``uvScale(_:)`` maps each texture's own
    /// normalised coordinates into its corner of the layer.
    /// Per layer, pixels per texel of the game's texture (``HighResolution/scale`` for the
    /// upscaled copies, 1 otherwise).
    public let detail: [Float]

    public init(textures: [(width: Int, height: Int, rgba: [UInt8])], mipmapped: Bool = false, detail: [Float] = []) {
        let w = max(1, textures.map(\.width).max() ?? 1), h = max(1, textures.map(\.height).max() ?? 1)
        width = w
        height = h
        self.mipmapped = mipmapped
        self.detail = detail
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

    /// Texture `layer`'s share of the padded layer, multiplied into its texture coordinates.
    public func uvScale(_ layer: Int) -> SIMD2<Float> {
        guard sizes.indices.contains(layer) else { return SIMD2(1, 1) }
        return SIMD2(Float(sizes[layer].x) / Float(width), Float(sizes[layer].y) / Float(height))
    }

    /// REGION_CLAMP keeps samples half a game texel inside the region; on an upscaled layer
    /// that is `detail` pixels, so widen it back to half a pixel (in the texture's own
    /// normalised space), or neighbouring tiles of one picture would meet with a visible seam.
    public func clampWidening(_ layer: Int) -> SIMD2<Float> {
        guard detail.indices.contains(layer), detail[layer] > 1, sizes.indices.contains(layer) else { return .zero }
        let pixels = SIMD2<Float>(Float(sizes[layer].x), Float(sizes[layer].y))
        return 0.5 * (detail[layer] - 1) / pixels
    }

    /// Number of mip levels uploaded.
    public var levelCount: Int { mipmapped ? Int(log2(Double(max(width, height)))) + 1 : 1 }
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

    init(_ quad: SpriteQuad, uvScale: SIMD2<Float> = SIMD2(1, 1), clampWidening: SIMD2<Float> = .zero) {
        p0 = quad.corners.0; p1 = quad.corners.1; p2 = quad.corners.2; p3 = quad.corners.3
        let scale = SIMD4(uvScale.x, uvScale.y, uvScale.x, uvScale.y)
        let widen = SIMD4(-clampWidening.x, -clampWidening.y, clampWidening.x, clampWidening.y)
        uv = quad.uv * scale
        clamp = simd_clamp(quad.clamp + widen, .zero, SIMD4(repeating: 1)) * scale
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
