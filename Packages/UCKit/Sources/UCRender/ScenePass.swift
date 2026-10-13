import Metal
import simd

enum ModelShader {
    static let vertex = "model_vertex"
    static let fragment = "model_fragment"
    /// Reversed Z: cleared to 0, nearer is larger.
    static let depthFormat: MTLPixelFormat = .depth32Float
}

/// GPU copies of ``SceneModel``s: one vertex and index buffer and one texture per game texture
/// (with a mip chain generated on the GPU), kept while the model is in use.
@MainActor
final class SceneModelCache {
    struct Entry {
        let model: SceneModel
        let vertices: any MTLBuffer
        let indices: any MTLBuffer
        let textures: [any MTLTexture]
        var lastUsed: UInt64
    }

    private let device: any MTLDevice
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var queue: (any MTLCommandQueue)?
    private(set) var white: (any MTLTexture)?
    private var frame: UInt64 = 0
    /// Models unused for this many frames are released.
    private let keepFrames: UInt64 = 300
    var onInsert: ([any MTLAllocation]) -> Void = { _ in }
    var onEvict: ([any MTLAllocation]) -> Void = { _ in }

    init(device: any MTLDevice) {
        self.device = device
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: 1, height: 1, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        white = device.makeTexture(descriptor: descriptor)
        var pixel: [UInt8] = [255, 255, 255, 255]
        white?.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &pixel, bytesPerRow: 4)
    }

    func whiteAllocation() -> [any MTLAllocation] { white.map { [$0] } ?? [] }

    func beginFrame() {
        frame += 1
        let stale = entries.filter { frame - $0.value.lastUsed > keepFrames }
        for (key, entry) in stale {
            entries[key] = nil
            onEvict([entry.vertices, entry.indices] + entry.textures)
        }
    }

    func entry(for model: SceneModel) -> Entry? {
        let key = ObjectIdentifier(model)
        if var entry = entries[key] {
            entry.lastUsed = frame
            entries[key] = entry
            return entry
        }
        guard !model.vertices.isEmpty, !model.indices.isEmpty,
              let vertices = model.vertices.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }),
              let indices = model.indices.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) })
        else { return nil }
        vertices.label = "\(model.name) vertices"
        indices.label = "\(model.name) indices"
        let textures = model.textures.compactMap(makeTexture)
        let entry = Entry(model: model, vertices: vertices, indices: indices, textures: textures, lastUsed: frame)
        entries[key] = entry
        onInsert([vertices, indices] + textures)
        return entry
    }

    private func makeTexture(_ texture: SceneModel.Texture) -> (any MTLTexture)? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: texture.width,
                                                                  height: texture.height, mipmapped: true)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let gpu = device.makeTexture(descriptor: descriptor), texture.rgba.count >= texture.width * texture.height * 4 else { return nil }
        texture.rgba.withUnsafeBytes { raw in
            gpu.replace(region: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0,
                        withBytes: raw.baseAddress!, bytesPerRow: texture.width * 4)
        }
        if gpu.mipmapLevelCount > 1 {
            if queue == nil { queue = device.makeCommandQueue() }
            if let commands = queue?.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() {
                blit.generateMipmaps(for: gpu)
                blit.endEncoding()
                commands.commit()
                commands.waitUntilCompleted()
            }
        }
        return gpu
    }
}

/// One frame's draw list with its uniforms, shared by both passes.
struct SceneDrawList {
    struct Item {
        let entry: SceneModelCache.Entry
        let draw: SceneModel.Draw
        let uniformOffset: Int
    }

    var opaque: [Item] = []
    var additive: [Item] = []

    /// Writes one uniform block per (instance, draw) into `buffer` and sorts the draws by pass.
    @MainActor
    static func build(_ frame: SceneFrame, cache: SceneModelCache, buffer: any MTLBuffer, aspect: Float) -> SceneDrawList {
        var list = SceneDrawList()
        let viewProjection = frame.projection(aspect: aspect) * frame.view
        let light = simd_normalize(-frame.lightDirection)
        var offset = 0
        for instance in frame.instances {
            guard let entry = cache.entry(for: instance.model) else { continue }
            for draw in instance.model.draws {
                guard offset + ModelUniforms.stride <= buffer.length else { return list }
                let texture = draw.texture.flatMap { instance.model.textures.indices.contains($0) ? instance.model.textures[$0] : nil }
                var uniforms = ModelUniforms(
                    clipFromModel: viewProjection * instance.transform,
                    worldFromModel: instance.transform,
                    light: SIMD4(light, frame.ambient),
                    flags: SIMD4(texture == nil ? 0 : 1, texture?.clampS == true ? 1 : 0, texture?.clampT == true ? 1 : 0,
                                 draw.blend == .additive ? 1 : 0))
                buffer.contents().advanced(by: offset).copyMemory(from: &uniforms, byteCount: MemoryLayout<ModelUniforms>.size)
                let item = Item(entry: entry, draw: draw, uniformOffset: offset)
                if draw.blend == .additive { list.additive.append(item) } else { list.opaque.append(item) }
                offset += ModelUniforms.stride
            }
        }
        return list
    }

    static func uniformCapacity(_ frame: SceneFrame) -> Int {
        max(1, frame.instances.reduce(0) { $0 + $1.model.draws.count }) * ModelUniforms.stride
    }
}

enum ScenePipelines {
    static func describe(_ descriptor: MTLRenderPipelineColorAttachmentDescriptor, additive: Bool) {
        descriptor.pixelFormat = HDRLayer.sceneFormat
        guard additive else { return }
        descriptor.isBlendingEnabled = true
        descriptor.sourceRGBBlendFactor = .one
        descriptor.destinationRGBBlendFactor = .one
        descriptor.rgbBlendOperation = .add
        descriptor.sourceAlphaBlendFactor = .zero
        descriptor.destinationAlphaBlendFactor = .one
    }

    static func depthStates(_ device: any MTLDevice) -> (write: any MTLDepthStencilState, test: any MTLDepthStencilState)? {
        let write = MTLDepthStencilDescriptor()
        write.depthCompareFunction = .greaterEqual
        write.isDepthWriteEnabled = true
        let test = MTLDepthStencilDescriptor()
        test.depthCompareFunction = .greaterEqual
        test.isDepthWriteEnabled = false
        guard let a = device.makeDepthStencilState(descriptor: write), let b = device.makeDepthStencilState(descriptor: test) else { return nil }
        return (a, b)
    }

    static func depthTexture(_ device: any MTLDevice, width: Int, height: Int) -> (any MTLTexture)? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: ModelShader.depthFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.storageMode = .private
        let texture = device.makeTexture(descriptor: descriptor)
        texture?.label = "Scene depth"
        return texture
    }
}

/// The 3D layer on the classic Metal queue (tvOS, Simulator, off-screen checks).
@MainActor
final class ScenePass {
    private let device: any MTLDevice
    private let opaque: any MTLRenderPipelineState
    private let additive: any MTLRenderPipelineState
    private let depthWrite: any MTLDepthStencilState
    private let depthTest: any MTLDepthStencilState
    private let cache: SceneModelCache
    private var uniforms: [(any MTLBuffer)?]

    init(device: any MTLDevice, library: any MTLLibrary, slots: Int) throws {
        guard let vertex = library.makeFunction(name: ModelShader.vertex) else { throw RendererError.missingFunction(ModelShader.vertex) }
        guard let fragment = library.makeFunction(name: ModelShader.fragment) else { throw RendererError.missingFunction(ModelShader.fragment) }
        func pipeline(_ additive: Bool) throws -> any MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = additive ? "Model additive" : "Model"
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            ScenePipelines.describe(descriptor.colorAttachments[0], additive: additive)
            descriptor.depthAttachmentPixelFormat = ModelShader.depthFormat
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        guard let states = ScenePipelines.depthStates(device) else { throw RendererError.resourceCreation("depth states") }
        self.device = device
        opaque = try pipeline(false)
        additive = try pipeline(true)
        depthWrite = states.write
        depthTest = states.test
        cache = SceneModelCache(device: device)
        uniforms = Array(repeating: nil, count: slots)
    }

    func encode(_ frame: SceneFrame, into encoder: any MTLRenderCommandEncoder, width: Int, height: Int, slot: Int) {
        cache.beginFrame()
        let needed = SceneDrawList.uniformCapacity(frame)
        if (uniforms[slot]?.length ?? 0) < needed {
            uniforms[slot] = device.makeBuffer(length: max(needed * 2, 64 * 1024), options: .storageModeShared)
            uniforms[slot]?.label = "Model uniforms"
        }
        guard let buffer = uniforms[slot] else { return }
        let list = SceneDrawList.build(frame, cache: cache, buffer: buffer, aspect: Float(width) / Float(max(height, 1)))
        encoder.pushDebugGroup("Models")
        for (items, pipeline, depth) in [(list.opaque, opaque, depthWrite), (list.additive, additive, depthTest)] {
            guard !items.isEmpty else { continue }
            encoder.setRenderPipelineState(pipeline)
            encoder.setDepthStencilState(depth)
            for item in items {
                encoder.setVertexBuffer(item.entry.vertices, offset: 0, index: 0)
                encoder.setVertexBuffer(buffer, offset: item.uniformOffset, index: 1)
                encoder.setFragmentBuffer(buffer, offset: item.uniformOffset, index: 1)
                let texture = item.draw.texture.flatMap { item.entry.textures.indices.contains($0) ? item.entry.textures[$0] : nil } ?? cache.white
                encoder.setFragmentTexture(texture, index: 0)
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: item.draw.indices.count, indexType: .uint32,
                                              indexBuffer: item.entry.indices, indexBufferOffset: item.draw.indices.lowerBound * 4)
            }
        }
        encoder.popDebugGroup()
    }
}

#if !os(tvOS) && !targetEnvironment(simulator)
/// The 3D layer on the Metal 4 queue (iOS, iPadOS, macOS): argument table per draw, residency
/// set for the model buffers and textures.
@MainActor
final class Metal4ScenePass {
    private let device: any MTLDevice
    private let opaque: any MTLRenderPipelineState
    private let additive: any MTLRenderPipelineState
    private let depthWrite: any MTLDepthStencilState
    private let depthTest: any MTLDepthStencilState
    private let argumentTable: any MTL4ArgumentTable
    private let residency: any MTLResidencySet
    private let cache: SceneModelCache
    private var uniforms: [(any MTLBuffer)?]

    init(device: any MTLDevice, compiler: any MTL4Compiler, library: any MTLLibrary, slots: Int, residency: any MTLResidencySet) throws {
        func pipeline(_ additive: Bool) throws -> any MTLRenderPipelineState {
            let vertex = MTL4LibraryFunctionDescriptor()
            vertex.library = library
            vertex.name = ModelShader.vertex
            let fragment = MTL4LibraryFunctionDescriptor()
            fragment.library = library
            fragment.name = ModelShader.fragment
            let descriptor = MTL4RenderPipelineDescriptor()
            descriptor.label = additive ? "Model additive" : "Model"
            descriptor.vertexFunctionDescriptor = vertex
            descriptor.fragmentFunctionDescriptor = fragment
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = HDRLayer.sceneFormat
            if additive {
                attachment.blendingState = .enabled
                attachment.sourceRGBBlendFactor = .one
                attachment.destinationRGBBlendFactor = .one
                attachment.rgbBlendOperation = .add
                attachment.sourceAlphaBlendFactor = .zero
                attachment.destinationAlphaBlendFactor = .one
            }
            return try compiler.makeRenderPipelineState(descriptor: descriptor)
        }
        guard let states = ScenePipelines.depthStates(device) else { throw RendererError.resourceCreation("depth states") }
        let table = MTL4ArgumentTableDescriptor()
        table.maxBufferBindCount = 2
        table.maxTextureBindCount = 1
        self.device = device
        opaque = try pipeline(false)
        additive = try pipeline(true)
        depthWrite = states.write
        depthTest = states.test
        argumentTable = try device.makeArgumentTable(descriptor: table)
        self.residency = residency
        cache = SceneModelCache(device: device)
        uniforms = Array(repeating: nil, count: slots)
        cache.onInsert = { allocations in
            for allocation in allocations { residency.addAllocation(allocation) }
            residency.commit()
        }
        cache.onEvict = { allocations in
            for allocation in allocations { residency.removeAllocation(allocation) }
            residency.commit()
        }
        for allocation in cache.whiteAllocation() { residency.addAllocation(allocation) }
        residency.commit()
    }

    func encode(_ frame: SceneFrame, into encoder: any MTL4RenderCommandEncoder, width: Int, height: Int, slot: Int) {
        cache.beginFrame()
        let needed = SceneDrawList.uniformCapacity(frame)
        if (uniforms[slot]?.length ?? 0) < needed {
            if let old = uniforms[slot] { residency.removeAllocation(old) }
            uniforms[slot] = device.makeBuffer(length: max(needed * 2, 64 * 1024), options: .storageModeShared)
            uniforms[slot]?.label = "Model uniforms"
            if let new = uniforms[slot] { residency.addAllocation(new) }
            residency.commit()
        }
        guard let buffer = uniforms[slot] else { return }
        let list = SceneDrawList.build(frame, cache: cache, buffer: buffer, aspect: Float(width) / Float(max(height, 1)))
        encoder.pushDebugGroup("Models")
        for (items, pipeline, depth) in [(list.opaque, opaque, depthWrite), (list.additive, additive, depthTest)] {
            guard !items.isEmpty else { continue }
            encoder.setRenderPipelineState(pipeline)
            encoder.setDepthStencilState(depth)
            for item in items {
                argumentTable.setAddress(item.entry.vertices.gpuAddress, index: 0)
                argumentTable.setAddress(buffer.gpuAddress + UInt64(item.uniformOffset), index: 1)
                let texture = item.draw.texture.flatMap { item.entry.textures.indices.contains($0) ? item.entry.textures[$0] : nil } ?? cache.white
                if let texture { argumentTable.setTexture(texture.gpuResourceID, index: 0) }
                encoder.setArgumentTable(argumentTable, stages: [.vertex, .fragment])
                encoder.drawIndexedPrimitives(primitiveType: .triangle, indexCount: item.draw.indices.count, indexType: .uint32,
                                              indexBuffer: item.entry.indices.gpuAddress + UInt64(item.draw.indices.lowerBound * 4),
                                              indexBufferLength: item.draw.indices.count * 4)
            }
        }
        encoder.popDebugGroup()
    }
}
#endif
