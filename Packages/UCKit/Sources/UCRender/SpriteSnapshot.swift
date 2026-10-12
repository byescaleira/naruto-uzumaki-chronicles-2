import Metal

/// Off-screen render of a ``SpriteFrame`` through the same sprite pass and scene format the app
/// uses, for checking screens without the app (`uc-tool screen render`) and in tests.
public enum SpriteSnapshot {
    public enum Backend: String, Sendable, CaseIterable {
        case metal4
        case classic
    }

    public enum Failure: Error {
        case unavailable(String)
    }

    /// Linear BT.709 RGBA (1.0 = SDR white), `width × height`, top row first.
    @MainActor
    public static func render(_ frame: SpriteFrame, width: Int, height: Int, device: any MTLDevice,
                              library: any MTLLibrary, backend: Backend) throws -> [Float] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: HDRLayer.sceneFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let scene = device.makeTexture(descriptor: descriptor) else { throw Failure.unavailable("scene target") }
        let clear = MTLClearColor(red: Double(frame.clearColor.x), green: Double(frame.clearColor.y), blue: Double(frame.clearColor.z), alpha: 1)

        switch backend {
        case .classic:
            guard let queue = device.makeCommandQueue(), let commandBuffer = queue.makeCommandBuffer() else {
                throw Failure.unavailable("command queue")
            }
            let pass = try SpritePass(device: device, library: library, format: HDRLayer.sceneFormat, slots: 1)
            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = scene
            descriptor.colorAttachments[0].loadAction = .clear
            descriptor.colorAttachments[0].clearColor = clear
            descriptor.colorAttachments[0].storeAction = .store
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { throw Failure.unavailable("encoder") }
            pass.encode(frame, into: encoder, width: width, height: height, slot: 0)
            encoder.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()

        case .metal4:
            #if !os(tvOS) && !targetEnvironment(simulator)
            guard let queue = device.makeMTL4CommandQueue(), let commandBuffer = device.makeCommandBuffer(),
                  let allocator = device.makeCommandAllocator(), let event = device.makeSharedEvent() else {
                throw Failure.unavailable("Metal 4 queue")
            }
            let residencyDescriptor = MTLResidencySetDescriptor()
            residencyDescriptor.initialCapacity = 8
            let residency = try device.makeResidencySet(descriptor: residencyDescriptor)
            residency.addAllocation(scene)
            residency.commit()
            queue.addResidencySet(residency)
            let compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
            let pass = try Metal4SpritePass(device: device, compiler: compiler, library: library, format: HDRLayer.sceneFormat,
                                            slots: 1, residency: residency)
            commandBuffer.beginCommandBuffer(allocator: allocator)
            let descriptor = MTL4RenderPassDescriptor()
            descriptor.colorAttachments[0].texture = scene
            descriptor.colorAttachments[0].loadAction = .clear
            descriptor.colorAttachments[0].clearColor = clear
            descriptor.colorAttachments[0].storeAction = .store
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { throw Failure.unavailable("encoder") }
            pass.encode(frame, into: encoder, width: width, height: height, slot: 0)
            encoder.endEncoding()
            commandBuffer.endCommandBuffer()
            queue.commit([commandBuffer])
            queue.signalEvent(event, value: 1)
            guard event.wait(untilSignaledValue: 1, timeoutMS: 10_000) else { throw Failure.unavailable("GPU timeout") }
            #else
            throw Failure.unavailable("Metal 4")
            #endif
        }

        var halves = [Float16](repeating: 0, count: width * height * 4)
        halves.withUnsafeMutableBytes { raw in
            scene.getBytes(raw.baseAddress!, bytesPerRow: width * 8, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return halves.map(Float.init)
    }
}
