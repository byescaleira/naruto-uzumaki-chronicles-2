import Foundation
import Metal
import QuartzCore
#if os(tvOS)
import AVFoundation
#endif

/// Renders frames into a `CAMetalLayer` configured for HDR.
///
/// - iOS, iPadOS, macOS: Metal 4 (`MTL4CommandQueue`, argument tables, `MTL4Compiler`),
///   extended linear Display P3 with EDR.
/// - tvOS: Metal 4 is unavailable in the tvOS 27 SDK, so the classic Metal queue is used
///   with a PQ BT.2100 (HDR10) layer. The Simulator also uses the classic queue.
@MainActor
public protocol Renderer: AnyObject {
    var device: any MTLDevice { get }
    func render(_ frame: FrameInput, to drawable: any CAMetalDrawable)
    /// GPU time of the most recently completed frame (seconds); 0 when not measured.
    var lastGPUTime: Double { get }
}

public enum RendererFactory {
    @MainActor
    public static func make(for layer: CAMetalLayer, mode: HDROutput.Mode = HDRLayer.outputMode) throws -> any Renderer {
        guard let device = layer.device ?? MTLCreateSystemDefaultDevice() else {
            throw RendererError.noDevice
        }
        layer.device = device
        HDRLayer.configure(layer, for: mode)
        // App/Shaders/*.metal are compiled by the app target into its default.metallib.
        guard let library = device.makeDefaultLibrary() else {
            throw RendererError.missingShaderLibrary
        }
        #if os(tvOS) || targetEnvironment(simulator)
        return try MetalRenderer(device: device, library: library, layer: layer)
        #else
        return try Metal4Renderer(device: device, library: library, layer: layer)
        #endif
    }
}

public enum RendererError: Error {
    case noDevice
    case missingShaderLibrary
    case missingFunction(String)
    case resourceCreation(String)
}

/// Layer setup for HDR output on each platform.
public enum HDRLayer {
    public static let sceneFormat: MTLPixelFormat = .rgba16Float

    @MainActor
    public static func configure(_ layer: CAMetalLayer, for mode: HDROutput.Mode) {
        layer.framebufferOnly = true
        layer.maximumDrawableCount = 3
        switch mode {
        case .extendedLinearP3:
            layer.pixelFormat = .rgba16Float
            layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        case .pq:
            layer.pixelFormat = .bgr10a2Unorm
            layer.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_PQ)
        case .sdr:
            layer.pixelFormat = .bgra8Unorm
            layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        }
        #if !os(tvOS)
        layer.wantsExtendedDynamicRangeContent = mode == .extendedLinearP3
        #endif
    }

    /// The output the current display can show.
    ///
    /// iOS, iPadOS and macOS always use EDR: on an SDR screen the headroom is 1 and the
    /// result matches SDR. tvOS sends PQ only when the TV path is HDR-capable; otherwise
    /// PQ would be converted by the system, which looks dull, so it renders sRGB itself.
    public static var outputMode: HDROutput.Mode {
        #if DEBUG
        // Debug override for checking each output path on any device: NUC2_OUTPUT=edr|pq|sdr.
        switch ProcessInfo.processInfo.environment["NUC2_OUTPUT"] {
        case "edr": return .extendedLinearP3
        case "pq": return .pq
        case "sdr": return .sdr
        default: break
        }
        #endif
        #if os(tvOS)
        return AVPlayer.eligibleForHDRPlayback ? .pq : .sdr
        #else
        return .extendedLinearP3
        #endif
    }
}
