// Builds the app icon layers from textures decoded out of the game (see re/scripts/textures.py):
//   face atlas  — 0039/00 texture #1 (character-select faces, Naruto at the top-left)
//   pattern     — 0216/00 texture #4 (green karakusa cloth pattern used across the menus)
//
// Usage: swiftc -O MakeIcon.swift -o make-icon && ./make-icon <atlas.png> <pattern.png> <repo-root>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct RGBA {
    var width: Int
    var height: Int
    var pixels: [UInt32]  // premultiplied RGBA8, native byte order as stored by CGContext

    init(width: Int, height: Int, pixels: [UInt32]? = nil) {
        self.width = width
        self.height = height
        self.pixels = pixels ?? Array(repeating: 0, count: width * height)
    }

    subscript(x: Int, y: Int) -> UInt32 {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }

    func alpha(_ x: Int, _ y: Int) -> UInt8 { UInt8(truncatingIfNeeded: self[x, y] >> 24) }
}

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

func context(_ width: Int, _ height: Int) -> CGContext {
    CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
              space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func load(_ path: String) -> RGBA {
    let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
    let ctx = context(image.width, image.height)
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return pixels(of: ctx)
}

func pixels(of ctx: CGContext) -> RGBA {
    let count = ctx.width * ctx.height
    let buffer = ctx.data!.bindMemory(to: UInt32.self, capacity: count)
    // CGContext rows are top-down in memory.
    return RGBA(width: ctx.width, height: ctx.height, pixels: Array(UnsafeBufferPointer(start: buffer, count: count)))
}

func image(_ img: RGBA) -> CGImage {
    var copy = img.pixels
    let ctx = copy.withUnsafeMutableBytes { raw in
        CGContext(data: raw.baseAddress, width: img.width, height: img.height, bitsPerComponent: 8,
                  bytesPerRow: img.width * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }
    return ctx.makeImage()!
}

func save(_ cg: CGImage, _ path: String) {
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, cg, nil)
    precondition(CGImageDestinationFinalize(dest), "write failed: \(path)")
    print("wrote \(path) (\(cg.width)×\(cg.height))")
}

/// Bounding box of opaque pixels inside a search rect.
func opaqueBounds(_ img: RGBA, in rect: (x: Int, y: Int, w: Int, h: Int)) -> (x: Int, y: Int, w: Int, h: Int) {
    var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
    for y in rect.y ..< rect.y + rect.h {
        for x in rect.x ..< rect.x + rect.w where img.alpha(x, y) > 0 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    return (minX, minY, maxX - minX + 1, maxY - minY + 1)
}

func crop(_ img: RGBA, _ r: (x: Int, y: Int, w: Int, h: Int), pad: Int) -> RGBA {
    var out = RGBA(width: r.w + pad * 2, height: r.h + pad * 2)
    for y in 0 ..< r.h { for x in 0 ..< r.w { out[x + pad, y + pad] = img[r.x + x, r.y + y] } }
    return out
}

/// Drops opaque islands smaller than `minPixels` (dithered fringe left by binary alpha).
func despeckled(_ img: RGBA, minPixels: Int) -> RGBA {
    var out = img
    var seen = [Bool](repeating: false, count: img.width * img.height)
    for start in 0 ..< img.width * img.height where !seen[start] && (img.pixels[start] >> 24) > 0 {
        var stack = [start], component: [Int] = []
        seen[start] = true
        while let i = stack.popLast() {
            component.append(i)
            let x = i % img.width, y = i / img.width
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, ny >= 0, nx < img.width, ny < img.height else { continue }
                let j = ny * img.width + nx
                if !seen[j], (img.pixels[j] >> 24) > 0 { seen[j] = true; stack.append(j) }
            }
        }
        if component.count < minPixels { for i in component { out.pixels[i] = 0 } }
    }
    return out
}

/// Pulls the pattern toward its mean colour so the foreground reads clearly.
func softened(_ img: RGBA, amount: Double) -> RGBA {
    var sum = [0.0, 0.0, 0.0]
    for p in img.pixels { for c in 0 ..< 3 { sum[c] += Double((p >> UInt32(c * 8)) & 0xFF) } }
    let mean = sum.map { $0 / Double(img.pixels.count) }
    var out = img
    for i in out.pixels.indices {
        let p = img.pixels[i]
        var q = p & 0xFF00_0000
        for c in 0 ..< 3 {
            let v = Double((p >> UInt32(c * 8)) & 0xFF)
            q |= UInt32(v + (mean[c] - v) * amount) << UInt32(c * 8)
        }
        out.pixels[i] = q
    }
    return out
}

/// Scale2x (EPX): doubles resolution while keeping hard cel-art edges.
func scale2x(_ src: RGBA) -> RGBA {
    var dst = RGBA(width: src.width * 2, height: src.height * 2)
    func at(_ x: Int, _ y: Int) -> UInt32 { src[min(max(x, 0), src.width - 1), min(max(y, 0), src.height - 1)] }
    for y in 0 ..< src.height {
        for x in 0 ..< src.width {
            let p = at(x, y), a = at(x, y - 1), b = at(x + 1, y), c = at(x - 1, y), d = at(x, y + 1)
            var e0 = p, e1 = p, e2 = p, e3 = p
            if c == a && c != d && a != b { e0 = a }
            if a == b && a != c && b != d { e1 = b }
            if d == c && d != b && c != a { e2 = c }
            if b == d && b != a && d != c { e3 = d }
            dst[2 * x, 2 * y] = e0; dst[2 * x + 1, 2 * y] = e1
            dst[2 * x, 2 * y + 1] = e2; dst[2 * x + 1, 2 * y + 1] = e3
        }
    }
    return dst
}

/// Draws `img` scaled into a new transparent canvas; returns the canvas pixels.
func place(_ img: RGBA, canvas: (w: Int, h: Int), rect: CGRect, quality: CGInterpolationQuality = .high) -> RGBA {
    let ctx = context(canvas.w, canvas.h)
    ctx.interpolationQuality = quality
    // CG origin is bottom-left; convert from a top-left rect.
    ctx.draw(image(img), in: CGRect(x: rect.minX, y: CGFloat(canvas.h) - rect.maxY, width: rect.width, height: rect.height))
    return pixels(of: ctx)
}

/// White sticker outline: everything within `radius` px of the subject becomes white, under it.
func outlined(_ layer: RGBA, radius: Double) -> RGBA {
    let w = layer.width, h = layer.height
    let inf = Double(w + h)
    // Two-pass Euclidean-ish distance transform (8-neighbour chamfer) to the subject.
    var dist = [Double](repeating: inf, count: w * h)
    for i in 0 ..< w * h where (layer.pixels[i] >> 24) > 127 { dist[i] = 0 }
    let diag = 2.0.squareRoot()
    for y in 0 ..< h {
        for x in 0 ..< w {
            var d = dist[y * w + x]
            if x > 0 { d = min(d, dist[y * w + x - 1] + 1) }
            if y > 0 { d = min(d, dist[(y - 1) * w + x] + 1) }
            if x > 0, y > 0 { d = min(d, dist[(y - 1) * w + x - 1] + diag) }
            if x < w - 1, y > 0 { d = min(d, dist[(y - 1) * w + x + 1] + diag) }
            dist[y * w + x] = d
        }
    }
    for y in stride(from: h - 1, through: 0, by: -1) {
        for x in stride(from: w - 1, through: 0, by: -1) {
            var d = dist[y * w + x]
            if x < w - 1 { d = min(d, dist[y * w + x + 1] + 1) }
            if y < h - 1 { d = min(d, dist[(y + 1) * w + x] + 1) }
            if x < w - 1, y < h - 1 { d = min(d, dist[(y + 1) * w + x + 1] + diag) }
            if x > 0, y < h - 1 { d = min(d, dist[(y + 1) * w + x - 1] + diag) }
            dist[y * w + x] = d
        }
    }
    var out = layer
    for i in 0 ..< w * h {
        // Anti-aliased edge of the outline.
        let coverage = max(0, min(1, radius + 0.5 - dist[i]))
        guard coverage > 0 else { continue }
        let a = UInt32(coverage * 255)
        let white = (a << 24) | (a << 16) | (a << 8) | a
        let src = layer.pixels[i]
        let sa = Double(src >> 24) / 255
        // src over white (premultiplied).
        func channel(_ shift: UInt32) -> UInt32 {
            let s = Double((src >> shift) & 0xFF), d = Double((white >> shift) & 0xFF)
            return UInt32(min(255, s + d * (1 - sa)))
        }
        out.pixels[i] = channel(24) << 24 | channel(16) << 16 | channel(8) << 8 | channel(0)
    }
    return out
}

/// Tiles the pattern across a canvas at `tile` px, with a soft vignette for depth.
func patternBackground(_ tile: RGBA, canvas: (w: Int, h: Int), tileSize: Int, vignette: Double) -> CGImage {
    let ctx = context(canvas.w, canvas.h)
    ctx.interpolationQuality = .none
    let cg = image(tile)
    var y = 0
    while y < canvas.h {
        var x = 0
        while x < canvas.w {
            ctx.draw(cg, in: CGRect(x: x, y: y, width: tileSize, height: tileSize))
            x += tileSize
        }
        y += tileSize
    }
    let center = CGPoint(x: canvas.w / 2, y: canvas.h / 2)
    let radius = hypot(Double(canvas.w), Double(canvas.h)) / 2
    let gradient = CGGradient(colorsSpace: colorSpace, colors: [
        CGColor(srgbRed: 0, green: 0.05, blue: 0.02, alpha: 0),
        CGColor(srgbRed: 0, green: 0.05, blue: 0.02, alpha: vignette),
    ] as CFArray, locations: [0.35, 1])!
    ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [.drawsAfterEndLocation])
    return ctx.makeImage()!
}

// MARK: - Main

let args = CommandLine.arguments
precondition(args.count == 4, "usage: make-icon <atlas.png> <pattern.png> <repo-root>")
let atlas = load(args[1])
let pattern = load(args[2])
let root = args[3]

// Naruto occupies the first cell of the 3×2 face atlas.
let bounds = opaqueBounds(atlas, in: (0, 0, 88, 106))
var face = despeckled(crop(atlas, bounds, pad: 2), minPixels: 24)
for _ in 0 ..< 2 { face = scale2x(face) }       // 4× with hard edges, then a smooth resample
let tile = softened(scale2x(scale2x(pattern)), amount: 0.3)  // 512 px tile
let aspect = Double(face.width) / Double(face.height)

/// The atlas cell cuts the bust off flat, so the bust is anchored past the bottom edge
/// (`overflow` of its height is hidden) instead of floating as a cut-out.
func faceLayer(canvas: (w: Int, h: Int), heightFraction: Double, centerX: Double = 0.5, outline: Double, overflow: Double = 0.06) -> CGImage {
    let h = Double(canvas.h) * heightFraction
    let w = h * aspect
    let rect = CGRect(x: Double(canvas.w) * centerX - w / 2, y: Double(canvas.h) - h * (1 - overflow), width: w, height: h)
    let placed = place(face, canvas: canvas, rect: rect)
    return image(outlined(placed, radius: outline * Double(canvas.h)))
}

// Icon Composer layers (1024 pt canvas).
let iconDir = "\(root)/App/AppIcon.icon/Assets"
save(patternBackground(tile, canvas: (1024, 1024), tileSize: 512, vignette: 0.5), "\(iconDir)/Background.png")
save(faceLayer(canvas: (1024, 1024), heightFraction: 0.86, outline: 0.02), "\(iconDir)/Naruto.png")

// tvOS layered icon (parallax: Back = pattern, Front = Naruto) and Top Shelf.
let brand = "\(root)/App/tvOS/Assets.xcassets/App Icon & Top Shelf Image.brandassets"
for (stack, sizes) in [("App Icon.imagestack", [(400, 240, ""), (800, 480, "@2x")]),
                       ("App Icon - App Store.imagestack", [(1280, 768, "")])] {
    for (w, h, suffix) in sizes {
        save(patternBackground(tile, canvas: (w, h), tileSize: h, vignette: 0.45),
             "\(brand)/\(stack)/Back.imagestacklayer/Content.imageset/back\(suffix).png")
        save(faceLayer(canvas: (w, h), heightFraction: 0.92, outline: 0.022),
             "\(brand)/\(stack)/Front.imagestacklayer/Content.imageset/front\(suffix).png")
    }
}
for (set, w, h) in [("Top Shelf Image.imageset", 1920, 720), ("Top Shelf Image Wide.imageset", 2320, 720)] {
    for (scale, suffix) in [(1, ""), (2, "@2x")] {
        let canvas = (w * scale, h * scale)
        let ctx = context(canvas.0, canvas.1)
        ctx.draw(patternBackground(tile, canvas: canvas, tileSize: 360 * scale, vignette: 0.4), in: CGRect(x: 0, y: 0, width: canvas.0, height: canvas.1))
        ctx.draw(faceLayer(canvas: canvas, heightFraction: 0.95, centerX: 0.8, outline: 0.02), in: CGRect(x: 0, y: 0, width: canvas.0, height: canvas.1))
        let name = set.hasPrefix("Top Shelf Image Wide") ? "topshelf-wide" : "topshelf"
        save(ctx.makeImage()!, "\(brand)/\(set)/\(name)\(suffix).png")
    }
}
