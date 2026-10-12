import Testing
@testable import UCFormats

/// Little-endian byte builder for synthetic files.
struct Bytes {
    var data: [UInt8] = []
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { data += [UInt8(v & 0xFF), UInt8(v >> 8)] }
    mutating func i16(_ v: Int16) { u16(UInt16(bitPattern: v)) }
    mutating func u32(_ v: UInt32) { for i in 0 ..< 4 { data.append(UInt8(truncatingIfNeeded: v >> (8 * UInt32(i)))) } }
    mutating func u64(_ v: UInt64) { u32(UInt32(truncatingIfNeeded: v)); u32(UInt32(truncatingIfNeeded: v >> 32)) }
    mutating func f32(_ v: Float) { u32(v.bitPattern) }
    mutating func pad(to n: Int) { while data.count < n { data.append(0) } }
}

/// A sprite file with one frame (two pieces), one two-key animation and one 8×8 PSMCT32 texture.
func syntheticSpriteFile(textureFormat: UInt64 = 0x00) -> [UInt8] {
    var bank = Bytes()
    bank.u32(0x8001)
    // base = 4: counts (frames, animations, keys, pieces), 8 reserved bytes, table offsets.
    bank.u16(1); bank.u16(1); bank.u16(2); bank.u16(2)
    bank.u32(0); bank.u32(0)
    let frames = 0x30, animations = frames + 12, keys = animations + 12, pieces = keys + 64
    for offset in [frames, animations, keys, pieces] { bank.u32(UInt32(offset - 4)) }
    bank.pad(to: frames)
    bank.u16(0); bank.u16(2); bank.i16(-10); bank.i16(-20); bank.i16(30); bank.i16(40)
    bank.u16(0); bank.u16(2); bank.u32(0); bank.u8(0); bank.u8(0); bank.u16(0)
    for (i, x) in [(0, Float(0)), (1, Float(100))] {
        bank.i16(0); bank.u16(i == 0 ? 10 : 5); bank.u16(0); bank.u16(UInt16(i))
        bank.f32(1); bank.f32(1); bank.f32(x); bank.f32(-x)
        bank.i16(Int16(i * 1024)); bank.u16(0); bank.u16(i == 0 ? 1 : 0); bank.u8(i == 0 ? 0x80 : 0x40); bank.u8(0)
    }
    for flip: UInt8 in [0, 1] {
        bank.u16(0); bank.u16(0); bank.i16(-4); bank.i16(-2)
        bank.u16(1); bank.u16(2); bank.u16(4); bank.u16(3)
        bank.i16(8); bank.i16(6); bank.u8(0); bank.u8(0x80)
        bank.i16(0); bank.i16(0); bank.i16(0); bank.u8(flip == 0 ? 0 : 1); bank.u8(0); bank.u8(flip); bank.u8(0)
    }

    var textures = Bytes()
    textures.u32(1); textures.u32(1); textures.u32(0); textures.u32(0)
    // Register packet: GIFtag, then CLAMP_1, MIPTBP1_1, TEX1_1, TEX0_1 as A+D.
    textures.u64(0x1000_0000_0000_8004); textures.u64(0x0E)
    let tex0: UInt64 = 1 << 14 | textureFormat << 20 | 3 << 26 | 3 << 30 | 1 << 34
    for (value, register) in [(UInt64(5), UInt64(0x08)), (0, 0x34), (0x60, 0x14), (tex0, 0x06)] {
        textures.u64(value); textures.u64(register)
    }
    // Texture record: level 0 = upload 0, no CLUT, 8×8.
    textures.u16(0); textures.u16(0xFFFF); textures.u16(0xFFFF); textures.u16(0xFFFF)
    textures.u16(0); textures.u8(1); textures.u8(0); textures.u32(0); textures.u16(8); textures.u16(8)
    // Upload record (relative offset 16 → pixels right after it).
    textures.u32(0); textures.u32(16); textures.u16(8); textures.u16(8); textures.u16(1); textures.u16(0)
    for i in 0 ..< 64 { textures.u8(UInt8(i)); textures.u8(UInt8(i * 2 & 0xFF)); textures.u8(7); textures.u8(0x40) }

    var file = Bytes()
    file.u32(2)
    let bankOffset = 0x20, textureOffset = 0x20 + (bank.data.count + 15) / 16 * 16
    file.u32(UInt32(bankOffset)); file.u32(UInt32(bank.data.count))
    file.u32(UInt32(textureOffset)); file.u32(UInt32(textures.data.count))
    file.pad(to: bankOffset)
    file.data += bank.data
    file.pad(to: textureOffset)
    file.data += textures.data
    return file.data
}

@Suite("Sprite files")
struct SpriteFileTests {
    @Test("Section table, bank tables and texture records parse")
    func parse() throws {
        let bytes = syntheticSpriteFile()
        #expect(SpriteFile.looksLikeSpriteFile(bytes))
        let file = try SpriteFile(bytes)
        let bank = file.bank
        #expect(bank.frames == [SpriteBank.Frame(firstPiece: 0, pieceCount: 2, bounds: SIMD4(-10, -20, 30, 40))])
        #expect(bank.animations.first?.keyCount == 2)
        #expect(bank.keys[1].translation == SIMD2(100, -100))
        #expect(bank.keys[1].rotation == 1024)
        #expect(bank.keys[0].nextKey == 1 && bank.keys[1].alpha == 0x40)
        #expect(bank.pieces[1].flip == 1 && bank.pieces[1].blend == 1)
        #expect(bank.pieces[0].uv == SIMD4(1, 2, 4, 3) && bank.pieces[0].size == SIMD2(8, 6))
        let texture = try #require(file.textures.textures.first)
        #expect(texture.tex0.pixelFormat == .ct32 && texture.tex0.width == 8 && texture.tex0.tbw == 1)
        #expect(texture.clut == nil && texture.levels == [0])
    }

    @Test("PSMCT32 textures read back through GS memory unchanged, alpha scaled")
    func ct32() throws {
        let decoded = try #require(try SpriteFile(syntheticSpriteFile()).textures.decode().first ?? nil)
        #expect(decoded.width == 8 && decoded.height == 8)
        for i in [0, 9, 63] {
            #expect(Array(decoded.rgba[i * 4 ..< i * 4 + 4]) == [UInt8(i), UInt8(i * 2), 7, 0x80])
        }
    }

    @Test("Truncated or foreign data is rejected")
    func rejects() {
        var bytes = syntheticSpriteFile()
        bytes.removeLast(40)
        #expect(throws: SpriteFile.Failure.self) { try SpriteFile(bytes) }
        #expect(!SpriteFile.looksLikeSpriteFile([1, 0, 0, 0]))
    }
}

@Suite("GS local memory")
struct GSMemoryTests {
    /// The widely used PSMCT32 → PSMT8 unswizzle formula, independent of the GS tables.
    private func classic8(_ x: Int, _ y: Int, width w: Int) -> Int {
        let block = (y & ~0xF) * w + (x & ~0xF) * 2
        let swap = ((y + 2) >> 2 & 1) * 4
        let row = ((y & ~3) >> 1 + (y & 1)) & 7
        let column = row * w * 2 + ((x + swap) & 7) * 4
        return block + column + ((y >> 1) & 1) + ((x >> 2) & 2)
    }

    @Test("PSMT8 read-back of a PSMCT32 upload matches the reference unswizzle")
    func psmt8() {
        let w32 = 64, h32 = 32
        let source = (0 ..< w32 * h32 * 4).map { UInt8(truncatingIfNeeded: $0 * 7 + $0 >> 8) }
        var memory = GSLocalMemory(blocks: 64)
        memory.uploadCT32(source[...], dbp: 0, dbw: 1, width: w32, height: h32)
        for y in 0 ..< h32 * 2 {
            for x in 0 ..< w32 * 2 {
                #expect(memory.t8(x: x, y: y, bp: 0, bw: 2) == Int(source[classic8(x, y, width: w32 * 2)]))
            }
        }
    }

    @Test("PSMT4 addressing covers a page exactly once")
    func psmt4() {
        var seen = Set<Int>()
        for y in 0 ..< 128 {
            for x in 0 ..< 128 { seen.insert(GSLocalMemory.nibble4(x: x, y: y, bufferWidth: 2)) }
        }
        #expect(seen.count == 128 * 128 && seen.min() == 0 && seen.max() == 128 * 128 - 1)
        for row in GSSwizzle.column4 { #expect(row.count == 32) }
        #expect(Set(GSSwizzle.column4.joined()).count == 512)
    }

    @Test("PSMT4 nibbles: even address = low nibble")
    func nibbles() {
        var memory = GSLocalMemory(blocks: 32)
        memory.uploadCT32([0x21, 0, 0, 0][...], dbp: 0, dbw: 1, width: 1, height: 1)
        #expect(memory.t4(x: 0, y: 0, bp: 0, bw: 2) == 1)
        let second = (0 ..< 128 * 128).first { GSLocalMemory.nibble4(x: $0 % 128, y: $0 / 128, bufferWidth: 2) == 1 }!
        #expect(memory.t4(x: second % 128, y: second / 128, bp: 0, bw: 2) == 2)
    }

    @Test("TEX0 fields")
    func tex0() {
        let t = GSTex0(0x2000_0006_2131_0000)
        #expect(t.psm == 0x13 && t.tbw == 4 && t.width == 256 && t.height == 256 && t.tcc && t.tfx == 0)
    }
}
