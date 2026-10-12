/// PS2 GS local-memory addressing: the game stores 8-bit textures as PSMCT32 uploads that
/// the GS samples as PSMT8, so their bytes are swizzled. These tables mirror the GS block
/// and column layouts (see re/scripts/gs.py for the reference implementation).
public enum GSSwizzle {
    static let block32: [[Int]] = [
        [0, 1, 4, 5, 16, 17, 20, 21],
        [2, 3, 6, 7, 18, 19, 22, 23],
        [8, 9, 12, 13, 24, 25, 28, 29],
        [10, 11, 14, 15, 26, 27, 30, 31],
    ]
    static let column32: [[Int]] = [
        [0, 1, 4, 5, 8, 9, 12, 13],
        [2, 3, 6, 7, 10, 11, 14, 15],
        [16, 17, 20, 21, 24, 25, 28, 29],
        [18, 19, 22, 23, 26, 27, 30, 31],
        [32, 33, 36, 37, 40, 41, 44, 45],
        [34, 35, 38, 39, 42, 43, 46, 47],
        [48, 49, 52, 53, 56, 57, 60, 61],
        [50, 51, 54, 55, 58, 59, 62, 63],
    ]
    static let column8: [[Int]] = [
        [0, 4, 16, 20, 32, 36, 48, 52, 2, 6, 18, 22, 34, 38, 50, 54],
        [8, 12, 24, 28, 40, 44, 56, 60, 10, 14, 26, 30, 42, 46, 58, 62],
        [33, 37, 1, 5, 49, 53, 17, 21, 35, 39, 3, 7, 51, 55, 19, 23],
        [41, 45, 9, 13, 57, 61, 25, 29, 43, 47, 11, 15, 59, 63, 27, 31],
        [96, 100, 112, 116, 64, 68, 80, 84, 98, 102, 114, 118, 66, 70, 82, 86],
        [104, 108, 120, 124, 72, 76, 88, 92, 106, 110, 122, 126, 74, 78, 90, 94],
        [65, 69, 81, 85, 97, 101, 113, 117, 67, 71, 83, 87, 99, 103, 115, 119],
        [73, 77, 89, 93, 105, 109, 121, 125, 75, 79, 91, 95, 107, 111, 123, 127],
        [128, 132, 144, 148, 160, 164, 176, 180, 130, 134, 146, 150, 162, 166, 178, 182],
        [136, 140, 152, 156, 168, 172, 184, 188, 138, 142, 154, 158, 170, 174, 186, 190],
        [161, 165, 129, 133, 177, 181, 145, 149, 163, 167, 131, 135, 179, 183, 147, 151],
        [169, 173, 137, 141, 185, 189, 153, 157, 171, 175, 139, 143, 187, 191, 155, 159],
        [224, 228, 240, 244, 192, 196, 208, 212, 226, 230, 242, 246, 194, 198, 210, 214],
        [232, 236, 248, 252, 200, 204, 216, 220, 234, 238, 250, 254, 202, 206, 218, 222],
        [193, 197, 209, 213, 225, 229, 241, 245, 195, 199, 211, 215, 227, 231, 243, 247],
        [201, 205, 217, 221, 233, 237, 249, 253, 203, 207, 219, 223, 235, 239, 251, 255],
    ]

    /// Byte address of a PSMCT32 pixel (base 0, buffer width in 64-pixel units).
    @inline(__always)
    static func address32(x: Int, y: Int, bufferWidth: Int) -> Int {
        let page = (x >> 6) + (y >> 5) * bufferWidth
        let block = block32[(y >> 3) & 3][(x >> 3) & 7]
        return (page * 2048 + block * 64 + column32[y & 7][x & 7]) * 4
    }

    /// Byte address of a PSMT8 pixel (buffer width in 64-pixel units, even).
    @inline(__always)
    static func address8(x: Int, y: Int, bufferWidth: Int) -> Int {
        let page = (x >> 7) + (y >> 6) * (bufferWidth >> 1)
        let block = block32[(y >> 4) & 3][(x >> 4) & 7]
        return page * 8192 + block * 256 + column8[y & 15][x & 15]
    }

    /// Pixels uploaded as a `w32 × h32` PSMCT32 rect, read back as `2w32 × 2h32` PSMT8 indices.
    public static func indices(fromCT32 data: ArraySlice<UInt8>, width w32: Int, height h32: Int) -> (indices: [UInt8], width: Int, height: Int) {
        let bufferWidth = max(1, (w32 + 63) / 64)
        let w8 = w32 * 2, h8 = h32 * 2
        let memorySize = max(address32(x: w32 - 1, y: h32 - 1, bufferWidth: bufferWidth) + 4, address8(x: w8 - 1, y: h8 - 1, bufferWidth: max(2, bufferWidth * 2)) + 1)
        var memory = [UInt8](repeating: 0, count: memorySize)
        let base = data.startIndex
        for y in 0 ..< h32 {
            for x in 0 ..< w32 {
                let a = address32(x: x, y: y, bufferWidth: bufferWidth)
                let i = base + (y * w32 + x) * 4
                memory[a] = data[i]; memory[a + 1] = data[i + 1]; memory[a + 2] = data[i + 2]; memory[a + 3] = data[i + 3]
            }
        }
        let tbw = max(2, bufferWidth * 2)
        var indices = [UInt8](repeating: 0, count: w8 * h8)
        for y in 0 ..< h8 {
            for x in 0 ..< w8 {
                indices[y * w8 + x] = memory[address8(x: x, y: y, bufferWidth: tbw)]
            }
        }
        return (indices, w8, h8)
    }

    /// 16×16 PSMCT32 CLUT in CSM1 order → 256 RGBA8 colours (PS2 alpha 0x80 → 255).
    public static func palette(fromCSM1 data: ArraySlice<UInt8>) -> [SIMD4<UInt8>] {
        let base = data.startIndex
        return (0 ..< 256).map { i in
            let j = (i & 0xE7) | ((i & 0x08) << 1) | ((i & 0x10) >> 1)
            let o = base + j * 4
            return SIMD4(data[o], data[o + 1], data[o + 2], UInt8(min(255, Int(data[o + 3]) * 2)))
        }
    }
}

/// An RGBA8 texture decoded from the disc.
public struct DecodedTexture: Sendable {
    public let width: Int
    public let height: Int
    /// Straight (non-premultiplied) RGBA8, row-major, top row first.
    public let rgba: [UInt8]
}

/// Texture sets embedded in UI / sprite sub-files (see re/NOTES.md, "Textures"):
/// a table of `{image, clut, w, h}` (20 bytes each) followed by a table of PSMCT32 uploads
/// `{0, offset, w32, h32, w32·h32/64}` (16 bytes each, offset relative to the record).
public enum TextureSet {
    struct Upload { let offset: Int; let width: Int; let height: Int }

    public static func decode(_ bytes: [UInt8]) -> [DecodedTexture] {
        let reader = ByteReader(bytes)
        var textures: [DecodedTexture] = []
        var offset = 0
        while offset + 32 <= bytes.count {
            guard let uploads = uploadTable(reader, bytes.count, at: offset) else {
                offset += 4
                continue
            }
            for (image, clut, _, _) in textureTable(reader, endingAt: offset, uploads: uploads.count) {
                let pixels = uploads[image], colours = uploads[clut]
                guard colours.width == 16, colours.height == 16 else { continue }
                let (indices, w, h) = GSSwizzle.indices(
                    fromCT32: bytes[pixels.offset ..< pixels.offset + pixels.width * pixels.height * 4],
                    width: pixels.width, height: pixels.height
                )
                let palette = GSSwizzle.palette(fromCSM1: bytes[colours.offset ..< colours.offset + 1024])
                var rgba = [UInt8](repeating: 0, count: w * h * 4)
                for (i, index) in indices.enumerated() {
                    let c = palette[Int(index)]
                    rgba[i * 4] = c.x; rgba[i * 4 + 1] = c.y; rgba[i * 4 + 2] = c.z; rgba[i * 4 + 3] = c.w
                }
                textures.append(DecodedTexture(width: w, height: h, rgba: rgba))
            }
            offset += uploads.count * 16
        }
        return textures
    }

    private static func isUpload(_ r: ByteReader, _ count: Int, at p: Int) -> Upload? {
        guard p + 16 <= count, r.u32(at: p) == 0 else { return nil }
        let relative = Int(r.u32(at: p + 4)), w = Int(r.u16(at: p + 8)), h = Int(r.u16(at: p + 10))
        let qwords = Int(r.u32(at: p + 12))
        guard w > 0, h > 0, w <= 512, h <= 512, qwords == w * h / 64, qwords > 0,
              p + relative + w * h * 4 <= count else { return nil }
        return Upload(offset: p + relative, width: w, height: h)
    }

    private static func uploadTable(_ r: ByteReader, _ count: Int, at offset: Int) -> [Upload]? {
        var uploads: [Upload] = []
        var p = offset
        while let upload = isUpload(r, count, at: p) {
            uploads.append(upload)
            p += 16
        }
        return uploads.count >= 2 ? uploads : nil
    }

    private static func textureTable(_ r: ByteReader, endingAt end: Int, uploads: Int) -> [(Int, Int, Int, Int)] {
        var table: [(Int, Int, Int, Int)] = []
        var p = end - 20
        while p >= 0 {
            let image = Int(r.u16(at: p)), clut = Int(r.u16(at: p + 8))
            guard r.u16(at: p + 2) == 0xFFFF, r.u16(at: p + 4) == 0xFFFF, r.u16(at: p + 6) == 0xFFFF,
                  r.u8(at: p + 10) == 1, r.u32(at: p + 12) == 0, image < uploads, clut < uploads,
                  r.u16(at: p + 16) > 0, r.u16(at: p + 18) > 0 else { break }
            table.insert((image, clut, Int(r.u16(at: p + 16)), Int(r.u16(at: p + 18))), at: 0)
            p -= 20
        }
        return table
    }
}
