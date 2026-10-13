import CoreVideo
import Foundation
import UCFormats
import VideoToolbox

/// Apple's machine-learning super-resolution scaler (VideoToolbox `VTFrameProcessor`, macOS 26
/// on Apple silicon), used at package time: tvOS has no such API, so the app ships the results.
///
/// The scaler takes `64RGBAHalf` frames, only scales by 4 and outputs opaque pixels, so a texture
/// runs twice: once for the colour (transparent texels first filled with their neighbours'
/// colour, or the cut-out edges would pick up dark fringes), once for the alpha as a grey image.
final class SuperResolution {
    static let scale = 4

    enum Failure: Error {
        case unsupported
        case configuration(Int, Int)
        case model(String)
        case buffer
    }

    private let processor = VTFrameProcessor()
    private let configuration: VTSuperResolutionScalerConfiguration
    let width: Int
    let height: Int
    private var frames = 0

    init(width: Int, height: Int, inputType: VTSuperResolutionScalerConfiguration.InputType) throws {
        guard VTSuperResolutionScalerConfiguration.isSupported,
              VTSuperResolutionScalerConfiguration.supportedScaleFactors.contains(Self.scale) else { throw Failure.unsupported }
        guard let configuration = VTSuperResolutionScalerConfiguration(
            frameWidth: width, frameHeight: height, scaleFactor: Self.scale, inputType: inputType,
            usePrecomputedFlow: false, qualityPrioritization: .normal,
            revision: VTSuperResolutionScalerConfiguration.defaultRevision
        ) else { throw Failure.configuration(width, height) }
        try Self.ensureModel(configuration)
        try processor.startSession(configuration: configuration)
        self.configuration = configuration
        self.width = width
        self.height = height
    }

    deinit { processor.endSession() }

    /// The scaler's models come from Apple on first use (a system download, once per Mac).
    private static func ensureModel(_ configuration: VTSuperResolutionScalerConfiguration) throws {
        guard configuration.configurationModelStatus != .ready else { return }
        print("downloading Apple's super-resolution model…")
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var failure: (any Error)?
        configuration.downloadConfigurationModel { error in
            failure = error
            done.signal()
        }
        done.wait()
        guard configuration.configurationModelStatus == .ready else {
            throw Failure.model(failure.map { "\($0)" } ?? "status \(configuration.configurationModelStatus.rawValue)")
        }
    }

    static func makeBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_64RGBAHalf, attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { throw Failure.buffer }
        return buffer
    }

    /// `source` (`width × height`) → a new buffer 4× the size. `sequential` frames of one video
    /// share history (temporal stability); images pass `false`.
    func process(_ source: CVPixelBuffer, sequential: Bool, time: CMTime = .zero) throws -> CVPixelBuffer {
        let destination = try Self.makeBuffer(width: width * Self.scale, height: height * Self.scale)
        guard let sourceFrame = VTFrameProcessorFrame(buffer: source, presentationTimeStamp: time),
              let destinationFrame = VTFrameProcessorFrame(buffer: destination, presentationTimeStamp: time),
              let parameters = VTSuperResolutionScalerParameters(
                  sourceFrame: sourceFrame, previousFrame: nil, previousOutputFrame: nil, opticalFlow: nil,
                  submissionMode: sequential && frames > 0 ? .sequential : .random, destinationFrame: destinationFrame)
        else { throw Failure.buffer }
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var failure: (any Error)?
        processor.process(parameters: parameters) { _, error in
            failure = error
            done.signal()
        }
        done.wait()
        if let failure { throw failure }
        frames += 1
        return destination
    }
}

/// 4× copies of 2D textures (``HighResolution``).
enum TextureUpscaler {
    /// Below this the scaler does not run (and has nothing to work with): edge-padded first.
    static let minimumSide = 64

    private nonisolated(unsafe) static var sessions: [String: SuperResolution] = [:]

    /// Mirrored margin around every texture: the scaler treats the frame edge as an edge of the
    /// picture, and the game cuts large pictures into 256×256 tiles drawn side by side, so
    /// without it every tile border would show as a seam.
    static let margin = 16

    static func upscale(_ texture: DecodedTexture) throws -> DecodedTexture {
        let w = max(texture.width + 2 * margin, minimumSide), h = max(texture.height + 2 * margin, minimumSide)
        let padded = pad(bleed(texture), width: w, height: h)
        let paddedAlpha = pad(texture, width: w, height: h)
        let key = "\(w)x\(h)"
        let session = try sessions[key] ?? SuperResolution(width: w, height: h, inputType: .image)
        sessions[key] = session

        let colour = try session.process(try buffer(padded, channel: .colour), sequential: false)
        let alpha = try session.process(try buffer(paddedAlpha, channel: .alpha), sequential: false)
        let s = SuperResolution.scale
        var rgba = [UInt8](repeating: 0, count: texture.width * s * texture.height * s * 4)
        read(colour, width: texture.width * s, height: texture.height * s, offset: margin * s) { x, y, pixel in
            let o = (y * texture.width * s + x) * 4
            rgba[o] = pixel.0
            rgba[o + 1] = pixel.1
            rgba[o + 2] = pixel.2
        }
        read(alpha, width: texture.width * s, height: texture.height * s, offset: margin * s) { x, y, pixel in
            // The scaler rings a little around hard edges: snap near-empty / near-full alpha.
            let a = pixel.0
            rgba[(y * texture.width * s + x) * 4 + 3] = a < 3 ? 0 : a > 252 ? 255 : a
        }
        return DecodedTexture(width: texture.width * s, height: texture.height * s, rgba: rgba)
    }

    private enum Channel { case colour, alpha }

    /// sRGB-encoded values as halves (what the scaler's own image path uses), alpha 1.
    private static func buffer(_ texture: DecodedTexture, channel: Channel) throws -> CVPixelBuffer {
        let buffer = try SuperResolution.makeBuffer(width: texture.width, height: texture.height)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!
        for y in 0 ..< texture.height {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: Float16.self)
            for x in 0 ..< texture.width {
                let i = (y * texture.width + x) * 4
                for c in 0 ..< 3 {
                    let value = channel == .colour ? texture.rgba[i + c] : texture.rgba[i + 3]
                    row[x * 4 + c] = Float16(Float(value) / 255)
                }
                row[x * 4 + 3] = 1
            }
        }
        return buffer
    }

    /// `width × height` pixels starting `offset` pixels in from the top-left corner.
    private static func read(_ buffer: CVPixelBuffer, width: Int, height: Int, offset: Int, _ body: (Int, Int, (UInt8, UInt8, UInt8)) -> Void) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!
        func byte(_ v: Float16) -> UInt8 { UInt8(min(255, max(0, (Float(v) * 255).rounded()))) }
        for y in 0 ..< height {
            let row = base.advanced(by: (y + offset) * stride).assumingMemoryBound(to: Float16.self)
            for x in 0 ..< width {
                let i = (x + offset) * 4
                body(x, y, (byte(row[i]), byte(row[i + 1]), byte(row[i + 2])))
            }
        }
    }

    /// `margin` pixels mirrored around the texture, then edge-replicated up to `width × height`
    /// (the margin is cropped from the result).
    private static func pad(_ texture: DecodedTexture, width: Int, height: Int) -> DecodedTexture {
        func reflect(_ i: Int, _ n: Int) -> Int {
            guard n > 1 else { return 0 }
            var v = i
            while v < 0 || v >= n { v = v < 0 ? -v - 1 : 2 * n - v - 1 }
            return v
        }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0 ..< height {
            let sy = reflect(min(y - margin, texture.height - 1 + margin), texture.height)
            for x in 0 ..< width {
                let sx = reflect(min(x - margin, texture.width - 1 + margin), texture.width)
                let s = (sy * texture.width + sx) * 4
                let o = (y * width + x) * 4
                for c in 0 ..< 4 { rgba[o + c] = texture.rgba[s + c] }
            }
        }
        return DecodedTexture(width: width, height: height, rgba: rgba)
    }

    /// Transparent texels take the average colour of their opaque neighbours, growing outwards
    /// (alpha untouched), so filtering across a cut-out edge never mixes in their stored colour.
    static func bleed(_ texture: DecodedTexture, passes: Int = 16) -> DecodedTexture {
        let w = texture.width, h = texture.height
        var rgba = texture.rgba
        var known = (0 ..< w * h).map { rgba[$0 * 4 + 3] > 0 }
        for _ in 0 ..< passes {
            var next = known
            var changed = false
            for y in 0 ..< h {
                for x in 0 ..< w where !known[y * w + x] {
                    var sum = SIMD3<Int>.zero, count = 0
                    for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, -1), (-1, 1), (1, 1)] {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < w, ny < h, known[ny * w + nx] else { continue }
                        let i = (ny * w + nx) * 4
                        sum &+= SIMD3(Int(rgba[i]), Int(rgba[i + 1]), Int(rgba[i + 2]))
                        count += 1
                    }
                    guard count > 0 else { continue }
                    let o = (y * w + x) * 4
                    rgba[o] = UInt8(sum.x / count)
                    rgba[o + 1] = UInt8(sum.y / count)
                    rgba[o + 2] = UInt8(sum.z / count)
                    next[y * w + x] = true
                    changed = true
                }
            }
            known = next
            if !changed { break }
        }
        return DecodedTexture(width: w, height: h, rgba: rgba)
    }
}
