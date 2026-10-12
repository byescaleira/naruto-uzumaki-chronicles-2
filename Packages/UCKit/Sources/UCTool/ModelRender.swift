import Foundation
import ImageIO
import simd
import UCFormats
import UniformTypeIdentifiers

/// Straight RGBA8, top row first.
struct RenderedImage {
    let width: Int
    let height: Int
    let rgba: [UInt8]

    init(width: Int, height: Int, rgba: [UInt8]) {
        self.width = width
        self.height = height
        self.rgba = rgba
    }

    init(_ texture: DecodedTexture) {
        self.init(width: texture.width, height: texture.height, rgba: texture.rgba)
    }

    func writePNG(to url: URL) throws {
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { fail("cannot write \(url.path)") }
    }
}

/// Small CPU rasterizer for verification renders: orthographic, z-buffered, nearest texel,
/// alpha test at 50 % and a fixed directional light. The game's world is Y-down (screen-like),
/// so +Y maps to image rows growing downwards.
func renderViews(_ geometry: ModelGeometry, textures: [Int: DecodedTexture], materials: [ModelTextureTable.Material],
                 views: [(yaw: Float, pitch: Float)], size: Int) -> RenderedImage {
    let bounds = Bounds(geometry.meshes)
    let radius = max(simd_length(bounds.size) / 2, 1e-3)
    var canvas = [UInt8](repeating: 0, count: size * views.count * size * 4)
    let stride = size * views.count
    for (n, view) in views.enumerated() {
        var raster = Raster(size: size)
        // Rotate about the vertical (Y) axis, then tilt (pitch) about X.
        let yaw = simd_float3x3(simd_quatf(angle: view.yaw, axis: SIMD3(0, 1, 0)))
        let pitch = simd_float3x3(simd_quatf(angle: view.pitch, axis: SIMD3(1, 0, 0)))
        let rotation = pitch * yaw
        let scale = Float(size) * 0.48 / radius
        let light = simd_normalize(SIMD3<Float>(-0.4, -0.7, -0.6))
        for mesh in geometry.meshes {
            let texture = mesh.material.flatMap { textures[$0] }
            let material = mesh.material.flatMap { $0 < materials.count ? materials[$0] : nil }
            let projected = mesh.vertices.map { v -> SIMD3<Float> in
                let p = rotation * (v.position - bounds.center)
                // Camera looks down −Z: x right, y down (Y-down world), nearer = larger z.
                return SIMD3(Float(size) / 2 + p.x * scale, Float(size) / 2 + p.y * scale, -p.z)
            }
            for t in Swift.stride(from: 0, to: mesh.indices.count, by: 3) {
                let i = (Int(mesh.indices[t]), Int(mesh.indices[t + 1]), Int(mesh.indices[t + 2]))
                let a = mesh.vertices[i.0], b = mesh.vertices[i.1], c = mesh.vertices[i.2]
                var normal = a.normal + b.normal + c.normal
                if simd_length(normal) < 1e-6 { normal = simd_cross(b.position - a.position, c.position - a.position) }
                let shade = 0.55 + 0.45 * abs(simd_dot(simd_normalize(normal), light))
                raster.triangle(projected[i.0], projected[i.1], projected[i.2], a.uv, b.uv, c.uv,
                                texture: texture, wrap: (material?.wrapS ?? 0, material?.wrapT ?? 0), shade: shade)
            }
        }
        for y in 0 ..< size {
            for x in 0 ..< size {
                let s = (y * size + x) * 4, d = (y * stride + n * size + x) * 4
                for k in 0 ..< 4 { canvas[d + k] = raster.color[s + k] }
            }
        }
    }
    return RenderedImage(width: stride, height: size, rgba: canvas)
}

private struct Raster {
    let size: Int
    var color: [UInt8]
    var depth: [Float]

    init(size: Int) {
        self.size = size
        color = [UInt8](repeating: 0, count: size * size * 4)
        for i in 0 ..< size * size {
            let checker = ((i % size) / 16 + (i / size) / 16) % 2 == 0
            color[i * 4] = checker ? 58 : 50; color[i * 4 + 1] = checker ? 60 : 52; color[i * 4 + 2] = checker ? 66 : 58
            color[i * 4 + 3] = 255
        }
        depth = [Float](repeating: -.greatestFiniteMagnitude, count: size * size)
    }

    mutating func triangle(_ p0: SIMD3<Float>, _ p1: SIMD3<Float>, _ p2: SIMD3<Float>,
                           _ t0: SIMD2<Float>, _ t1: SIMD2<Float>, _ t2: SIMD2<Float>,
                           texture: DecodedTexture?, wrap: (Int, Int), shade: Float) {
        let area = (p1.x - p0.x) * (p2.y - p0.y) - (p2.x - p0.x) * (p1.y - p0.y)
        guard abs(area) > 1e-8 else { return }
        let minX = max(0, Int(min(p0.x, p1.x, p2.x).rounded(.down))), maxX = min(size - 1, Int(max(p0.x, p1.x, p2.x).rounded(.up)))
        let minY = max(0, Int(min(p0.y, p1.y, p2.y).rounded(.down))), maxY = min(size - 1, Int(max(p0.y, p1.y, p2.y).rounded(.up)))
        guard minX <= maxX, minY <= maxY else { return }
        for y in minY ... maxY {
            for x in minX ... maxX {
                let px = Float(x) + 0.5, py = Float(y) + 0.5
                let w0 = ((p1.x - px) * (p2.y - py) - (p2.x - px) * (p1.y - py)) / area
                let w1 = ((p2.x - px) * (p0.y - py) - (p0.x - px) * (p2.y - py)) / area
                let w2 = 1 - w0 - w1
                guard w0 >= -1e-3, w1 >= -1e-3, w2 >= -1e-3 else { continue }
                let z = w0 * p0.z + w1 * p1.z + w2 * p2.z
                let i = y * size + x
                guard z > depth[i] else { continue }
                var rgba = SIMD4<Float>(200, 200, 200, 255)
                if let texture {
                    let uv = w0 * t0 + w1 * t1 + w2 * t2
                    let tx = Self.wrap(uv.x, texture.width, mode: wrap.0), ty = Self.wrap(uv.y, texture.height, mode: wrap.1)
                    let o = (ty * texture.width + tx) * 4
                    rgba = SIMD4(Float(texture.rgba[o]), Float(texture.rgba[o + 1]), Float(texture.rgba[o + 2]), Float(texture.rgba[o + 3]))
                    if rgba.w < 128 { continue }
                }
                depth[i] = z
                color[i * 4] = UInt8(min(255, rgba.x * shade))
                color[i * 4 + 1] = UInt8(min(255, rgba.y * shade))
                color[i * 4 + 2] = UInt8(min(255, rgba.z * shade))
                color[i * 4 + 3] = 255
            }
        }
    }

    static func wrap(_ coordinate: Float, _ size: Int, mode: Int) -> Int {
        let texel = Int((coordinate * Float(size)).rounded(.down))
        if mode == 1 { return min(max(texel, 0), size - 1) }
        return ((texel % size) + size) % size
    }
}
