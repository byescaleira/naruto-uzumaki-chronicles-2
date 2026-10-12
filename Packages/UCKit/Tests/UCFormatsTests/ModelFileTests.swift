import simd
import Testing
@testable import UCFormats

private extension Array where Element == UInt8 {
    mutating func u16(_ v: Int) { append(UInt8(v & 0xFF)); append(UInt8((v >> 8) & 0xFF)) }
    mutating func u32(_ v: UInt32) { [0, 8, 16, 24].forEach { append(UInt8((v >> UInt32($0)) & 0xFF)) } }
    mutating func f32(_ v: Float) { u32(v.bitPattern) }
    mutating func pad(to alignment: Int) { while count % alignment != 0 { append(0) } }
    mutating func put(_ v: UInt32, at offset: Int) { for k in 0 ..< 4 { self[offset + k] = UInt8((v >> UInt32(8 * k)) & 0xFF) } }
}

/// A two-bone model with one part: three vertices, one skinned across both bones, one normal,
/// three UVs, one textured triangle on material 3 (texture slot 0).
private func syntheticModel() -> [UInt8] {
    var b: [UInt8] = []
    b.u32(0); b.u32(1); b.u32(2); b.u32(10)  // part table offset patched below
    // Bone 0: identity. Bone 1: stored quaternion +90° about Z (applied as its conjugate), at x = 1.
    let s = Float(0.5).squareRoot()
    for (q, t) in [(SIMD4<Float>(0, 0, 0, 1), SIMD3<Float>(0, 0, 0)), (SIMD4<Float>(0, 0, s, s), SIMD3<Float>(1, 0, 0))] {
        [q.x, q.y, q.z, q.w, 1, 1, 1, 1, 0, 0, 0, 1, t.x, t.y, t.z, 1].forEach { b.f32($0) }
    }
    b.u16(0xFFFF); b.u16(0)
    b.pad(to: 16)
    let partTable = b.count
    b.put(UInt32(partTable), at: 0)
    b += [UInt8](repeating: 0, count: 0x20)

    // VIF chunks, one per DMA step.
    var bone0 = VIFPacket()
    bone0.unpack(0x6E, count: 1, address: 0, unsigned: true, payload: [4, 16, 0, 0]); bone0.mscal(0x2E)
    bone0.stcycl(cl: 2, wl: 1)
    bone0.unpack(0x6E, count: 1, address: 0, unsigned: true, payload: [3, 16, 0, 0])
    bone0.unpack(0x62, count: 3, address: 2, unsigned: true, payload: [0, 1, 2])
    var positions: [UInt8] = []
    [0.5, 0, 0, 0.5, 0, 2, 0, 1, 0, 0, 3, 1].forEach { positions.f32($0) }
    bone0.unpack(0x6C, count: 3, address: 1, payload: positions)
    bone0.mscal(0x02)

    var bone1 = VIFPacket()
    bone1.unpack(0x6E, count: 1, address: 0, unsigned: true, payload: [4, 23, 0, 0]); bone1.mscal(0x2E)
    bone1.stcycl(cl: 2, wl: 1)
    bone1.unpack(0x6E, count: 1, address: 0, unsigned: true, payload: [1, 23, 1, 0])
    bone1.unpack(0x62, count: 1, address: 2, unsigned: true, payload: [0])
    var half: [UInt8] = []
    [0, 0, 0, 0.5].forEach { half.f32($0) }  // weight 0.5 at the bone's origin = world (1, 0, 0)
    bone1.unpack(0x6C, count: 1, address: 1, payload: half)
    bone1.mscal(0x1A)
    bone1.stcycl(cl: 1, wl: 1)
    bone1.unpack(0x6E, count: 1, address: 0, unsigned: true, payload: [3, 0, 0, 0])
    bone1.unpack(0x62, count: 3, address: 1, unsigned: true, payload: [0, 1, 2])
    bone1.mscal(0x08)

    var normal = VIFPacket()
    normal.unpack(0x6E, count: 1, address: 0, unsigned: true, payload: [3, 20, 0, 0]); normal.mscal(0x06)
    normal.unpack(0x6E, count: 1, address: 0, unsigned: true, payload: [1, 20, 11, 0])
    var n: [UInt8] = []
    n.f32(0); n.f32(0); n.f32(2); n.u32(0)
    normal.unpack(0x6C, count: 1, address: 1, payload: n)
    normal.mscal(0x20)
    normal.unpack(0x66, count: 2, address: 0, unsigned: true, payload: [1, 15, 0, 0])
    normal.mscal(0x12)
    var uv: [UInt8] = []
    for (s, t, i) in [(Float(0), Float(0), UInt32(0)), (1, 0, 1), (0, 1, 2)] { uv.f32(s); uv.f32(t); uv.u32(i) }
    normal.unpack(0x60, count: 1, address: 0, payload: [3, 0, 0, 0])
    normal.unpack(0x68, count: 3, address: 1, payload: uv)
    normal.mscal(0x0C)

    var material = VIFPacket()
    material.mscal(0x14)
    material.unpack(0x6A, count: 4, address: 0, unsigned: true, payload: [1, 0, 0, 0, 0, 0, 1, 0, 1, 2, 0, 2])
    material.mscal(0x18)

    let chunks = [bone0, bone1, normal, material].map { c -> [UInt8] in var bytes = c.bytes; bytes.pad(to: 16); return bytes }
    let steps: [(kind: UInt8, index: Int)] = [(2, 0), (2, 1), (3, 0), (4, 0)]
    let commands = b.count
    for (step, chunk) in zip(steps, chunks) {
        b.append(step.kind); b.append(0); b.u16(step.index); b.u16(chunk.count / 16)
    }
    b += [0, 0, 0, 0, 0, 0]
    let bindings = b.count
    b.u16(3); b.u16(0)
    b.pad(to: 16)
    let vif = b.count
    chunks.forEach { b += $0 }
    b.put(UInt32(commands), at: partTable)
    b.put(UInt32(vif), at: partTable + 4)
    b.put(UInt32(bindings), at: partTable + 0xC)
    b[partTable + 0x17] = 1
    b.put(UInt32(bindings), at: partTable + 0x18)
    b.put(0x8028_2828, at: partTable + 0x1C)
    return b
}

private func near(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Bool { simd_length(a - b) < 1e-5 }

@Suite("Models")
struct ModelFileTests {
    @Test("Section table: offsets, absent sections and rejection")
    func sectionedFile() throws {
        var bytes: [UInt8] = []
        bytes.u32(3); bytes.u32(28); bytes.u32(4); bytes.u32(0); bytes.u32(0); bytes.u32(32); bytes.u32(2)
        bytes += [1, 2, 3, 4, 5, 6]
        let file = try #require(SectionedFile(bytes))
        #expect(file.section(.model).map(Array.init) == [1, 2, 3, 4])
        #expect(file.section(.textures) == nil)
        #expect(file.section(2).map(Array.init) == [5, 6])
        var bad = bytes
        bad.put(64, at: 4)
        #expect(SectionedFile(bad) == nil)
        #expect(SectionedFile([0, 0, 0, 0]) == nil)
    }

    @Test("Bones chain to their parents with the conjugated quaternion")
    func restPose() throws {
        let model = try ModelFile(syntheticModel()[...])
        #expect(model.bones.map(\.parent) == [nil, 0])
        let pose = model.restPose()
        let p = pose[1] * SIMD4<Float>(1, 0, 0, 1)
        #expect(near(SIMD3(p.x, p.y, p.z), SIMD3(1, -1, 0)))
    }

    @Test("Part records and the DMA command list")
    func parts() throws {
        let model = try ModelFile(syntheticModel()[...])
        let part = try #require(model.parts.first)
        #expect(part.commands.map(\.kind) == [.boneMatrix, .boneMatrix, .normalMatrix, .material])
        #expect(part.material(forSlot: 0) == 3)
        #expect(part.color == 0x8028_2828)
        #expect(part.vif.count == part.commands.reduce(0) { $0 + Int($1.qwords) * 16 })
    }

    @Test("VU1 emulation skins, lights, maps and draws a triangle")
    func geometry() throws {
        let geometry = try ModelGeometry(model: ModelFile(syntheticModel()[...]))
        #expect(geometry.unknownPrograms.isEmpty)
        let mesh = try #require(geometry.meshes.first)
        #expect(geometry.meshes.count == 1 && mesh.material == 3 && mesh.pass == .base)
        #expect(mesh.indices == [0, 1, 2])
        // Vertex 0 = 0.5 · bone0 · (1, 0, 0) + 0.5 · bone1 · (0, 0, 0).
        #expect(near(mesh.vertices[0].position, SIMD3(1, 0, 0)))
        #expect(near(mesh.vertices[1].position, SIMD3(0, 2, 0)))
        #expect(near(mesh.vertices[2].position, SIMD3(0, 0, 3)))
        #expect(near(mesh.vertices[0].normal, SIMD3(0, 0, 1)))
        #expect(mesh.vertices.map(\.uv) == [SIMD2(0, 0), SIMD2(1, 0), SIMD2(0, 1)])
    }

    @Test("Texture table decodes a PSMT8 material through its CLUT")
    func textureTable() throws {
        var b: [UInt8] = []
        b.u32(1); b.u32(2); b.u32(0); b.u32(0)
        b += [UInt8](repeating: 0, count: 0x40)
        let tex0: UInt64 = 0x13 << 20 | 4 << 26 | 4 << 30 | 1 << 34
        b.u32(UInt32(tex0 & 0xFFFF_FFFF)); b.u32(UInt32(tex0 >> 32)); b.u32(6); b.u32(0)
        b.u16(0); b.u16(0xFFFF); b.u16(0xFFFF); b.u16(0xFFFF); b.u16(1); b.append(1); b.append(1); b.u32(0); b.u16(16); b.u16(16)
        let uploads = b.count
        let image = uploads + 32
        let clut = image + 8 * 8 * 4
        b.u32(0); b.u32(UInt32(image - uploads)); b.u16(8); b.u16(8); b.u16(16); b.u16(0)
        b.u32(0); b.u32(UInt32(clut - (uploads + 16))); b.u16(16); b.u16(16); b.u16(64); b.u16(0)
        b += [UInt8](repeating: 0, count: 8 * 8 * 4)
        b += [255, 0, 0, 0x80] + [UInt8](repeating: 0, count: 1020)
        let table = try ModelTextureTable(b[...])
        #expect(table.materials.first?.psm == 0x13)
        #expect(table.materials.first.map { ($0.width, $0.height, $0.usesTextureAlpha) } ?? (0, 0, false) == (16, 16, true))
        let texture = try #require(table.decodeTexture(0))
        #expect(texture.width == 16 && texture.height == 16)
        #expect(texture.rgba.count == 16 * 16 * 4)
        #expect(stride(from: 0, to: texture.rgba.count, by: 4).allSatisfy { texture.rgba[$0 ..< $0 + 4] == [255, 0, 0, 255] })
    }
}
