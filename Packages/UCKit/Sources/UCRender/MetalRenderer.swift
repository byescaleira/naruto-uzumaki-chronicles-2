#if os(tvOS) || targetEnvironment(simulator)
import Metal
import QuartzCore
import Synchronization

/// Classic Metal renderer for tvOS (no Metal 4 in the tvOS SDK) and the Simulator (whose
/// SDK ships empty Metal 4 headers): HDR scene target → output transform.
@MainActor
final class MetalRenderer: Renderer {
    static let framesInFlight = 3

    let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let scenePipeline: any MTLRenderPipelineState
    private let outputPipeline: any MTLRenderPipelineState
    /// nil when the app's library has no Sprite.metal.
    private let spritePass: SpritePass?
    private var frameIndex = 0
    private let inFlight = DispatchSemaphore(value: MetalRenderer.framesInFlight)
    private var sceneTarget: (any MTLTexture)?
    private let gpuClock = GPUClock()

    /// GPU time of the most recently completed frame, in seconds.
    var lastGPUTime: Double { gpuClock.seconds.withLock { $0 } }

    init(device: any MTLDevice, library: any MTLLibrary, layer: CAMetalLayer) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            throw RendererError.resourceCreation("command queue")
        }
        self.queue = queue
        scenePipeline = try Self.pipeline(device, library, fragment: "boot_scene_fragment", format: HDRLayer.sceneFormat)
        outputPipeline = try Self.pipeline(device, library, fragment: "output_fragment", format: layer.pixelFormat)
        spritePass = try? SpritePass(device: device, library: library, format: HDRLayer.sceneFormat, slots: Self.framesInFlight)
    }

    private static func pipeline(
        _ device: any MTLDevice,
        _ library: any MTLLibrary,
        fragment: String,
        format: MTLPixelFormat
    ) throws -> any MTLRenderPipelineState {
        guard let vertex = library.makeFunction(name: "fullscreen_vertex") else {
            throw RendererError.missingFunction("fullscreen_vertex")
        }
        guard let fragmentFunction = library.makeFunction(name: fragment) else {
            throw RendererError.missingFunction(fragment)
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = fragment
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = format
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    private func sceneTexture(width: Int, height: Int) -> (any MTLTexture)? {
        if let target = sceneTarget, target.width == width, target.height == height {
            return target
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: HDRLayer.sceneFormat, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        sceneTarget = device.makeTexture(descriptor: descriptor)
        return sceneTarget
    }

    func render(_ frame: FrameInput, to drawable: any CAMetalDrawable) {
        let target = drawable.texture
        guard let scene = sceneTexture(width: target.width, height: target.height) else { return }
        inFlight.wait()
        guard let commandBuffer = queue.makeCommandBuffer() else {
            inFlight.signal()
            return
        }
        let semaphore = inFlight
        let gpuClock = gpuClock
        commandBuffer.addCompletedHandler { buffer in
            gpuClock.seconds.withLock { $0 = buffer.gpuEndTime - buffer.gpuStartTime }
            semaphore.signal()
        }

        var values = FrameUniforms(
            resolution: SIMD2(Float(target.width), Float(target.height)),
            time: Float(frame.time),
            output: frame.output
        )

        // The semaphore guarantees the GPU is done with this slot's sprite buffer.
        let slot = frameIndex % Self.framesInFlight
        frameIndex += 1
        let scenePass = MTLRenderPassDescriptor()
        scenePass.colorAttachments[0].texture = scene
        scenePass.colorAttachments[0].storeAction = .store
        let sprites = spritePass != nil ? frame.sprites : nil
        if let sprites {
            scenePass.colorAttachments[0].loadAction = .clear
            scenePass.colorAttachments[0].clearColor = MTLClearColor(red: Double(sprites.clearColor.x), green: Double(sprites.clearColor.y),
                                                                     blue: Double(sprites.clearColor.z), alpha: 1)
        } else {
            scenePass.colorAttachments[0].loadAction = .dontCare
        }
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: scenePass) {
            encoder.label = "Scene"
            if let sprites, let spritePass {
                spritePass.encode(sprites, into: encoder, width: scene.width, height: scene.height, slot: slot)
            } else {
                encoder.setRenderPipelineState(scenePipeline)
                encoder.setFragmentBytes(&values, length: MemoryLayout<FrameUniforms>.stride, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
            encoder.endEncoding()
        }

        let outputPass = MTLRenderPassDescriptor()
        outputPass.colorAttachments[0].texture = target
        outputPass.colorAttachments[0].loadAction = .dontCare
        outputPass.colorAttachments[0].storeAction = .store
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: outputPass) {
            encoder.label = "Output"
            encoder.setRenderPipelineState(outputPipeline)
            encoder.setFragmentTexture(scene, index: 0)
            encoder.setFragmentBytes(&values, length: MemoryLayout<FrameUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

/// Written by the command buffer's completion handler (any thread), read on the main actor.
private final class GPUClock: Sendable {
    let seconds = Mutex(0.0)
}
#endif
