import Metal
import QuartzCore

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
}

public enum RendererFactory {
    @MainActor
    public static func make(for layer: CAMetalLayer) throws -> any Renderer {
        guard let device = layer.device ?? MTLCreateSystemDefaultDevice() else {
            throw RendererError.noDevice
        }
        layer.device = device
        HDRLayer.configure(layer)
        #if os(tvOS) || targetEnvironment(simulator)
        return try MetalRenderer(device: device, layer: layer)
        #else
        return try Metal4Renderer(device: device, layer: layer)
        #endif
    }
}

public enum RendererError: Error {
    case noDevice
    case missingFunction(String)
    case resourceCreation(String)
}

/// Layer setup for HDR output on each platform.
public enum HDRLayer {
    public static let sceneFormat: MTLPixelFormat = .rgba16Float

    @MainActor
    public static func configure(_ layer: CAMetalLayer) {
        layer.framebufferOnly = true
        layer.maximumDrawableCount = 3
        #if os(tvOS)
        layer.pixelFormat = .bgr10a2Unorm
        layer.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_PQ)
        #else
        layer.pixelFormat = .rgba16Float
        layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        layer.wantsExtendedDynamicRangeContent = true
        #endif
    }

    public static var outputMode: HDROutput.Mode {
        #if os(tvOS)
        .pq
        #else
        .extendedLinearP3
        #endif
    }
}
