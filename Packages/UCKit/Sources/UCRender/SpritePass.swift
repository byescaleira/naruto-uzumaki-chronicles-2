import Metal

/// Function names in App/Shaders/Sprite.metal.
enum SpriteShader {
    static let vertex = "sprite_vertex"
    static let fragment = "sprite_fragment"
    /// Uniforms live at the start of each frame's instance buffer; instances follow.
    static let instanceOffset = 256
}

/// Blend state per GS `ALPHA_1` mode, on premultiplied shader output (see Sprite.metal).
/// The scene's alpha channel is left untouched.
struct SpriteBlendState {
    var source: MTLBlendFactor = .one
    var destination: MTLBlendFactor
    var operation: MTLBlendOperation

    init(_ blend: SpriteBlend) {
        switch blend {
        case .blend: destination = .oneMinusSourceAlpha; operation = .add
        case .add: destination = .one; operation = .add
        case .subtract: destination = .one; operation = .reverseSubtract
        }
    }
}

/// Uploads a ``SpriteAtlas`` once and keeps the most recent ones resident.
@MainActor
final class SpriteAtlasCache {
    private let device: any MTLDevice
    private var entries: [(atlas: SpriteAtlas, texture: any MTLTexture)] = []
    private let capacity = 4
    /// Called with a texture when it is created / evicted (Metal 4 residency).
    var onInsert: ((any MTLTexture) -> Void)?
    var onEvict: ((any MTLTexture) -> Void)?

    init(device: any MTLDevice) { self.device = device }

    func texture(for atlas: SpriteAtlas) -> (any MTLTexture)? {
        if let i = entries.firstIndex(where: { $0.atlas === atlas }) {
            let entry = entries.remove(at: i)
            entries.append(entry)
            return entry.texture
        }
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.pixelFormat = .rgba8Unorm_srgb
        descriptor.width = atlas.width
        descriptor.height = atlas.height
        descriptor.arrayLength = max(1, atlas.layers.count)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.label = "Sprite atlas"
        for (slice, pixels) in atlas.layers.enumerated() {
            pixels.withUnsafeBytes { raw in
                texture.replace(region: MTLRegionMake2D(0, 0, atlas.width, atlas.height), mipmapLevel: 0, slice: slice,
                                withBytes: raw.baseAddress!, bytesPerRow: atlas.width * 4, bytesPerImage: atlas.width * atlas.height * 4)
            }
        }
        if entries.count >= capacity {
            let evicted = entries.removeFirst()
            onEvict?(evicted.texture)
        }
        entries.append((atlas, texture))
        onInsert?(texture)
        return texture
    }
}

/// Per-frame instance buffers, one per frame in flight; grown on demand.
@MainActor
final class SpriteInstanceRing {
    private let device: any MTLDevice
    private(set) var buffers: [(any MTLBuffer)?]
    var onReplace: ((_ old: (any MTLBuffer)?, _ new: any MTLBuffer) -> Void)?

    init(device: any MTLDevice, slots: Int) {
        self.device = device
        buffers = Array(repeating: nil, count: slots)
    }

    /// Writes uniforms + instances for `frame` into slot `slot`; returns the buffer.
    func fill(slot: Int, frame: SpriteFrame, width: Int, height: Int) -> (any MTLBuffer)? {
        let needed = SpriteShader.instanceOffset + max(1, frame.quads.count) * MemoryLayout<SpriteInstance>.stride
        if (buffers[slot]?.length ?? 0) < needed {
            let length = max(needed * 2, 64 * 1024)
            guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else { return nil }
            buffer.label = "Sprite instances"
            onReplace?(buffers[slot], buffer)
            buffers[slot] = buffer
        }
        guard let buffer = buffers[slot] else { return nil }
        var uniforms = frame.canvas.transform(width: width, height: height)
        buffer.contents().copyMemory(from: &uniforms, byteCount: MemoryLayout<SpriteUniforms>.stride)
        let instances = buffer.contents().advanced(by: SpriteShader.instanceOffset).bindMemory(to: SpriteInstance.self, capacity: frame.quads.count)
        for (i, quad) in frame.quads.enumerated() { instances[i] = SpriteInstance(quad) }
        return buffer
    }
}

/// The 2D layer on the classic Metal queue (tvOS, Simulator, and an off-screen check path).
@MainActor
final class SpritePass {
    private let pipelines: [SpriteBlend: any MTLRenderPipelineState]
    private let atlases: SpriteAtlasCache
    private let ring: SpriteInstanceRing

    init(device: any MTLDevice, library: any MTLLibrary, format: MTLPixelFormat, slots: Int) throws {
        guard let vertex = library.makeFunction(name: SpriteShader.vertex) else { throw RendererError.missingFunction(SpriteShader.vertex) }
        guard let fragment = library.makeFunction(name: SpriteShader.fragment) else { throw RendererError.missingFunction(SpriteShader.fragment) }
        var pipelines: [SpriteBlend: any MTLRenderPipelineState] = [:]
        for blend in [SpriteBlend.blend, .add, .subtract] {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "Sprite \(blend)"
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = format
            let state = SpriteBlendState(blend)
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = state.source
            attachment.destinationRGBBlendFactor = state.destination
            attachment.rgbBlendOperation = state.operation
            attachment.sourceAlphaBlendFactor = .zero
            attachment.destinationAlphaBlendFactor = .one
            attachment.alphaBlendOperation = .add
            pipelines[blend] = try device.makeRenderPipelineState(descriptor: descriptor)
        }
        self.pipelines = pipelines
        atlases = SpriteAtlasCache(device: device)
        ring = SpriteInstanceRing(device: device, slots: slots)
    }

    func encode(_ frame: SpriteFrame, into encoder: any MTLRenderCommandEncoder, width: Int, height: Int, slot: Int) {
        guard !frame.quads.isEmpty, let atlas = atlases.texture(for: frame.atlas),
              let buffer = ring.fill(slot: slot, frame: frame, width: width, height: height) else { return }
        encoder.pushDebugGroup("Sprites")
        encoder.setVertexBuffer(buffer, offset: SpriteShader.instanceOffset, index: 0)
        encoder.setVertexBuffer(buffer, offset: 0, index: 1)
        encoder.setFragmentTexture(atlas, index: 0)
        for batch in spriteBatches(frame.quads) {
            guard let pipeline = pipelines[batch.blend] else { continue }
            encoder.setRenderPipelineState(pipeline)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                   instanceCount: batch.range.count, baseInstance: batch.range.lowerBound)
        }
        encoder.popDebugGroup()
    }
}

#if !os(tvOS) && !targetEnvironment(simulator)
/// The 2D layer on the Metal 4 queue (iOS, iPadOS, macOS): its own argument table, atlases
/// and instance buffers tracked in the renderer's residency set.
@MainActor
final class Metal4SpritePass {
    private let pipelines: [SpriteBlend: any MTLRenderPipelineState]
    private let atlases: SpriteAtlasCache
    private let ring: SpriteInstanceRing
    private let argumentTable: any MTL4ArgumentTable

    init(device: any MTLDevice, compiler: any MTL4Compiler, library: any MTLLibrary, format: MTLPixelFormat,
         slots: Int, residency: any MTLResidencySet) throws {
        guard library.functionNames.contains(SpriteShader.vertex) else { throw RendererError.missingFunction(SpriteShader.vertex) }
        let vertex = MTL4LibraryFunctionDescriptor()
        vertex.library = library
        vertex.name = SpriteShader.vertex
        let fragment = MTL4LibraryFunctionDescriptor()
        fragment.library = library
        fragment.name = SpriteShader.fragment
        var pipelines: [SpriteBlend: any MTLRenderPipelineState] = [:]
        for blend in [SpriteBlend.blend, .add, .subtract] {
            let descriptor = MTL4RenderPipelineDescriptor()
            descriptor.label = "Sprite \(blend)"
            descriptor.vertexFunctionDescriptor = vertex
            descriptor.fragmentFunctionDescriptor = fragment
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = format
            let state = SpriteBlendState(blend)
            attachment.blendingState = .enabled
            attachment.sourceRGBBlendFactor = state.source
            attachment.destinationRGBBlendFactor = state.destination
            attachment.rgbBlendOperation = state.operation
            attachment.sourceAlphaBlendFactor = .zero
            attachment.destinationAlphaBlendFactor = .one
            attachment.alphaBlendOperation = .add
            pipelines[blend] = try compiler.makeRenderPipelineState(descriptor: descriptor)
        }
        self.pipelines = pipelines

        let tableDescriptor = MTL4ArgumentTableDescriptor()
        tableDescriptor.maxBufferBindCount = 2
        tableDescriptor.maxTextureBindCount = 1
        argumentTable = try device.makeArgumentTable(descriptor: tableDescriptor)

        atlases = SpriteAtlasCache(device: device)
        ring = SpriteInstanceRing(device: device, slots: slots)
        atlases.onInsert = { residency.addAllocation($0); residency.commit() }
        atlases.onEvict = { residency.removeAllocation($0); residency.commit() }
        ring.onReplace = { old, new in
            if let old { residency.removeAllocation(old) }
            residency.addAllocation(new)
            residency.commit()
        }
    }

    func encode(_ frame: SpriteFrame, into encoder: any MTL4RenderCommandEncoder, width: Int, height: Int, slot: Int) {
        guard !frame.quads.isEmpty, let atlas = atlases.texture(for: frame.atlas),
              let buffer = ring.fill(slot: slot, frame: frame, width: width, height: height) else { return }
        encoder.pushDebugGroup("Sprites")
        argumentTable.setAddress(buffer.gpuAddress + UInt64(SpriteShader.instanceOffset), index: 0)
        argumentTable.setAddress(buffer.gpuAddress, index: 1)
        argumentTable.setTexture(atlas.gpuResourceID, index: 0)
        encoder.setArgumentTable(argumentTable, stages: [.vertex, .fragment])
        for batch in spriteBatches(frame.quads) {
            guard let pipeline = pipelines[batch.blend] else { continue }
            encoder.setRenderPipelineState(pipeline)
            encoder.drawPrimitives(primitiveType: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                   instanceCount: batch.range.count, baseInstance: batch.range.lowerBound)
        }
        encoder.popDebugGroup()
    }
}
#endif
