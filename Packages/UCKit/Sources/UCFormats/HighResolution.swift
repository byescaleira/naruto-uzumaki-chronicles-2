import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// High-resolution copies of the game's 2D textures, made when the data package is built
/// (`uc-tool pack`, Apple's VideoToolbox super-resolution scaler at 4×) and shipped next to the
/// disc files as `HD/<entry>_<sub-file>_t<texture>.png`. The app swaps them in for the decoded
/// textures; texture coordinates stay normalised, so nothing else changes.
public enum HighResolution {
    public static let scale = 4
    public static let directory = "HD"

    /// `HD/0040_00_t09.png` (the same names `uc-tool sprite textures` writes).
    public static func path(entry: Int, subfile: Int, texture: Int) -> String {
        String(format: "%@/%04d_%02d_t%02d.png", directory, entry, subfile, texture)
    }

    /// Straight-alpha RGBA8 from a PNG written by ``png(_:)``.
    public static func decode(_ url: URL) -> DecodedTexture? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let width = image.width, height = image.height
        // The PNG stores straight alpha; read it back as stored when the layout matches.
        if image.bitsPerComponent == 8, image.bitsPerPixel == 32, image.alphaInfo == .last,
           image.bitmapInfo.intersection(.byteOrderMask) == [] || image.bitmapInfo.intersection(.byteOrderMask) == .byteOrder32Big,
           let data = image.dataProvider?.data as Data?, data.count >= width * height * 4 {
            let stride = image.bytesPerRow
            var rgba = [UInt8](repeating: 0, count: width * height * 4)
            data.withUnsafeBytes { raw in
                for y in 0 ..< height {
                    rgba.withUnsafeMutableBytes { out in
                        out.baseAddress!.advanced(by: y * width * 4).copyMemory(from: raw.baseAddress!.advanced(by: y * stride), byteCount: width * 4)
                    }
                }
            }
            return DecodedTexture(width: width, height: height, rgba: rgba)
        }
        // Anything else: draw premultiplied, then undo it.
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        for i in stride(from: 0, to: rgba.count, by: 4) where rgba[i + 3] > 0 && rgba[i + 3] < 255 {
            let a = Int(rgba[i + 3])
            for c in 0 ..< 3 { rgba[i + c] = UInt8(min(255, (Int(rgba[i + c]) * 255 + a / 2) / a)) }
        }
        return DecodedTexture(width: width, height: height, rgba: rgba)
    }

    /// A straight-alpha sRGB PNG of `texture`.
    public static func png(_ texture: DecodedTexture) -> Data? {
        let data = NSMutableData()
        guard let provider = CGDataProvider(data: Data(texture.rgba) as CFData),
              let image = CGImage(width: texture.width, height: texture.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: texture.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
