#if !os(tvOS) && !targetEnvironment(simulator)
import Metal
import QuartzCore

/// Metal 4 renderer: HDR scene target → output transform into the EDR drawable.
@MainActor
final class Metal4Renderer: Renderer {
    static let framesInFlight = 3

    let device: any MTLDevice
    private let queue: any MTL4CommandQueue
    private let commandBuffer: any MTL4CommandBuffer
    private let allocators: [any MTL4CommandAllocator]
    private let argumentTable: any MTL4ArgumentTable
    private let residency: any MTLResidencySet
    private let uniforms: [any MTLBuffer]
    private let frameEvent: any MTLSharedEvent
    private let scenePipeline: any MTLRenderPipelineState
    private let outputPipeline: any MTLRenderPipelineState
    /// nil when the app's library has no Sprite.metal.
    private let spritePass: Metal4SpritePass?
    private var sceneTarget: (any MTLTexture)?
    private var frameIndex: UInt64 = 0

    /// Not measured on the Metal 4 path yet (would need an MTL4 counter heap).
    var lastGPUTime: Double { 0 }

    init(device: any MTLDevice, library: any MTLLibrary, layer: CAMetalLayer) throws {
        self.device = device
        guard let queue = device.makeMTL4CommandQueue(),
              let commandBuffer = device.makeCommandBuffer(),
              let frameEvent = device.makeSharedEvent()
        else { throw RendererError.resourceCreation("Metal 4 queue") }
        self.queue = queue
        self.commandBuffer = commandBuffer
        self.frameEvent = frameEvent

        allocators = try (0 ..< Self.framesInFlight).map { _ in
            guard let allocator = device.makeCommandAllocator() else {
                throw RendererError.resourceCreation("command allocator")
            }
            return allocator
        }
        uniforms = try (0 ..< Self.framesInFlight).map { _ in
            guard let buffer = device.makeBuffer(length: MemoryLayout<FrameUniforms>.stride, options: .storageModeShared) else {
                throw RendererError.resourceCreation("uniform buffer")
            }
            return buffer
        }

        let tableDescriptor = MTL4ArgumentTableDescriptor()
        tableDescriptor.maxBufferBindCount = 1
        tableDescriptor.maxTextureBindCount = 1
        argumentTable = try device.makeArgumentTable(descriptor: tableDescriptor)

        let residencyDescriptor = MTLResidencySetDescriptor()
        residencyDescriptor.initialCapacity = 8
        residency = try device.makeResidencySet(descriptor: residencyDescriptor)
        for buffer in uniforms { residency.addAllocation(buffer) }
        residency.commit()
        queue.addResidencySet(residency)
        queue.addResidencySet(layer.residencySet)

        let compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
        scenePipeline = try Self.pipeline(compiler, library, fragment: "boot_scene_fragment", format: HDRLayer.sceneFormat)
        outputPipeline = try Self.pipeline(compiler, library, fragment: "output_fragment", format: layer.pixelFormat)
        spritePass = try? Metal4SpritePass(device: device, compiler: compiler, library: library, format: HDRLayer.sceneFormat,
                                           slots: Self.framesInFlight, residency: residency)
    }

    private static func pipeline(
        _ compiler: any MTL4Compiler,
        _ library: any MTLLibrary,
        fragment: String,
        format: MTLPixelFormat
    ) throws -> any MTLRenderPipelineState {
        let vertexFunction = MTL4LibraryFunctionDescriptor()
        vertexFunction.library = library
        vertexFunction.name = "fullscreen_vertex"
        let fragmentFunction = MTL4LibraryFunctionDescriptor()
        fragmentFunction.library = library
        fragmentFunction.name = fragment

        let descriptor = MTL4RenderPipelineDescriptor()
        descriptor.label = fragment
        descriptor.vertexFunctionDescriptor = vertexFunction
        descriptor.fragmentFunctionDescriptor = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = format
        return try compiler.makeRenderPipelineState(descriptor: descriptor)
    }

    private func sceneTexture(width: Int, height: Int) throws -> any MTLTexture {
        if let target = sceneTarget, target.width == width, target.height == height {
            return target
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: HDRLayer.sceneFormat, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw RendererError.resourceCreation("scene target")
        }
        if let old = sceneTarget { residency.removeAllocation(old) }
        residency.addAllocation(texture)
        residency.commit()
        sceneTarget = texture
        return texture
    }

    func render(_ frame: FrameInput, to drawable: any CAMetalDrawable) {
        let slot = Int(frameIndex % UInt64(Self.framesInFlight))
        if frameIndex >= UInt64(Self.framesInFlight) {
            // Wait until the GPU has finished the frame that last used this slot.
            _ = frameEvent.wait(untilSignaledValue: frameIndex - UInt64(Self.framesInFlight) + 1, timeoutMS: 1000)
        }
        let target = drawable.texture
        guard let scene = try? sceneTexture(width: target.width, height: target.height) else { return }

        var values = FrameUniforms(
            resolution: SIMD2(Float(target.width), Float(target.height)),
            time: Float(frame.time),
            output: frame.output
        )
        uniforms[slot].contents().copyMemory(from: &values, byteCount: MemoryLayout<FrameUniforms>.stride)
        argumentTable.setAddress(uniforms[slot].gpuAddress, index: 0)

        let allocator = allocators[slot]
        allocator.reset()
        commandBuffer.beginCommandBuffer(allocator: allocator)

        // Pass 1: scene into the HDR target.
        let scenePass = MTL4RenderPassDescriptor()
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
                encoder.setArgumentTable(argumentTable, stages: [.vertex, .fragment])
                encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)
            }
            encoder.endEncoding()
        }

        // Pass 2: output transform into the drawable.
        let outputPass = MTL4RenderPassDescriptor()
        outputPass.colorAttachments[0].texture = target
        outputPass.colorAttachments[0].loadAction = .dontCare
        outputPass.colorAttachments[0].storeAction = .store
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: outputPass) {
            encoder.label = "Output"
            encoder.barrier(afterQueueStages: .fragment, beforeStages: .fragment, visibilityOptions: .device)
            encoder.setRenderPipelineState(outputPipeline)
            argumentTable.setTexture(scene.gpuResourceID, index: 0)
            encoder.setArgumentTable(argumentTable, stages: [.vertex, .fragment])
            encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        commandBuffer.endCommandBuffer()
        queue.waitForDrawable(drawable)
        queue.commit([commandBuffer])
        queue.signalDrawable(drawable)
        frameIndex += 1
        queue.signalEvent(frameEvent, value: frameIndex)
        drawable.present()
    }
}
#endif
