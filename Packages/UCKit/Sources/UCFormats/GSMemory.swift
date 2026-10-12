/// A slice of PS2 GS local memory, enough to replay how the game uploads sprite textures and
/// how the GS samples them back.
///
/// Recovered from `SLES_550.90`:
/// - `FUN_001d0bc0` builds every texture upload as an IMAGE transfer with
///   `BITBLTBUF.DPSM = PSMCT32`, `DBW = ⌈w/64⌉` and `TRXREG = w × h` — the game never uploads in
///   the sampled format, so 8-bit and 4-bit textures arrive swizzled.
/// - `FUN_001d06e0` assigns each upload its own block pointer (`FUN_001d1f00`) and patches
///   `TEX0.TBP0` / `TEX0.CBP` / `MIPTBP1` of the texture's register packet with them.
///
/// Addresses are in bytes; block pointers in 256-byte blocks, buffer widths in 64-pixel units
/// (GS conventions). Page/block/column layouts follow the GS manual tables.
public struct GSLocalMemory: Sendable {
    public static let blockBytes = 256

    public private(set) var bytes: [UInt8]

    public init(blocks: Int) {
        bytes = [UInt8](repeating: 0, count: max(1, blocks) * Self.blockBytes)
    }

    /// Byte address of a PSMCT32 pixel relative to its buffer base.
    @inline(__always)
    static func offset32(x: Int, y: Int, bufferWidth: Int) -> Int {
        GSSwizzle.address32(x: x, y: y, bufferWidth: max(1, bufferWidth))
    }

    /// Byte address of a PSMT8 pixel relative to its buffer base.
    @inline(__always)
    static func offset8(x: Int, y: Int, bufferWidth: Int) -> Int {
        GSSwizzle.address8(x: x, y: y, bufferWidth: max(2, bufferWidth))
    }

    /// Nibble address of a PSMT4 pixel relative to its buffer base (page 128×128, block 32×16).
    @inline(__always)
    static func nibble4(x: Int, y: Int, bufferWidth: Int) -> Int {
        let page = (x >> 7) + (y >> 7) * max(1, bufferWidth >> 1)
        let block = GSSwizzle.block4[(y >> 4) & 7][(x >> 5) & 3]
        return page * 16384 + block * 512 + GSSwizzle.column4[y & 15][x & 31]
    }

    /// IMAGE transfer of a `width × height` PSMCT32 rect, row-major RGBA8 source, to `(dbp, dbw)`.
    public mutating func uploadCT32(_ data: ArraySlice<UInt8>, dbp: Int, dbw: Int, width: Int, height: Int) {
        let base = dbp * Self.blockBytes
        let source = data.startIndex
        for y in 0 ..< height {
            for x in 0 ..< width {
                let a = base + Self.offset32(x: x, y: y, bufferWidth: dbw)
                let i = source + (y * width + x) * 4
                guard a + 4 <= bytes.count, i + 4 <= data.endIndex else { continue }
                bytes[a] = data[i]; bytes[a + 1] = data[i + 1]; bytes[a + 2] = data[i + 2]; bytes[a + 3] = data[i + 3]
            }
        }
    }

    func ct32(x: Int, y: Int, bp: Int, bw: Int) -> SIMD4<UInt8> {
        let a = bp * Self.blockBytes + Self.offset32(x: x, y: y, bufferWidth: bw)
        guard a + 4 <= bytes.count else { return .zero }
        return SIMD4(bytes[a], bytes[a + 1], bytes[a + 2], bytes[a + 3])
    }

    func t8(x: Int, y: Int, bp: Int, bw: Int) -> Int {
        let a = bp * Self.blockBytes + Self.offset8(x: x, y: y, bufferWidth: bw)
        return a < bytes.count ? Int(bytes[a]) : 0
    }

    func t4(x: Int, y: Int, bp: Int, bw: Int) -> Int {
        let n = bp * Self.blockBytes * 2 + Self.nibble4(x: x, y: y, bufferWidth: bw)
        guard n >> 1 < bytes.count else { return 0 }
        return Int(bytes[n >> 1] >> UInt8((n & 1) << 2)) & 0xF
    }
}

/// The fields of a `TEX0_1` register value the sprite textures use.
public struct GSTex0: Sendable, Hashable {
    public enum PixelFormat: UInt8, Sendable {
        case ct32 = 0x00
        case ct24 = 0x01
        case t8 = 0x13
        case t4 = 0x14
    }

    public let raw: UInt64

    public init(_ raw: UInt64) { self.raw = raw }

    public var tbp0: Int { Int(raw & 0x3FFF) }
    public var tbw: Int { Int(raw >> 14 & 0x3F) }
    public var psm: UInt8 { UInt8(raw >> 20 & 0x3F) }
    public var pixelFormat: PixelFormat? { PixelFormat(rawValue: psm) }
    /// log2 of the texture width / height.
    public var tw: Int { Int(raw >> 26 & 0xF) }
    public var th: Int { Int(raw >> 30 & 0xF) }
    /// Texture colour component: 1 = RGBA, 0 = RGB (alpha from the vertex).
    public var tcc: Bool { raw >> 34 & 1 != 0 }
    /// Texture function: 0 = MODULATE, 1 = DECAL, 2 = HIGHLIGHT, 3 = HIGHLIGHT2.
    public var tfx: Int { Int(raw >> 35 & 3) }
    public var cbp: Int { Int(raw >> 37 & 0x3FFF) }
    public var cpsm: Int { Int(raw >> 51 & 0xF) }
    public var csm: Int { Int(raw >> 55 & 1) }
    public var csa: Int { Int(raw >> 56 & 0x1F) }
    public var width: Int { 1 << tw }
    public var height: Int { 1 << th }

    /// Reads a texture back from GS memory the way the GS samples it (CSM1, PSMCT32 CLUTs).
    /// Returns straight RGBA8 with the PS2 alpha scale (0x80 = opaque) mapped to 0…255.
    public func read(from memory: GSLocalMemory) -> DecodedTexture? {
        guard let format = pixelFormat, tw <= 10, th <= 10 else { return nil }
        let w = width, h = height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        var palette: [SIMD4<UInt8>] = []
        switch format {
        case .t8:
            // CSM1: 16×16 entries, index bits 3 and 4 swapped.
            palette = (0 ..< 256).map { i in
                let j = (i & 0xE7) | ((i & 0x08) << 1) | ((i & 0x10) >> 1)
                return memory.ct32(x: j & 15, y: j >> 4, bp: cbp, bw: 1)
            }
        case .t4:
            // CSM1 4-bit: 8×2 entries; CSA selects a 16-entry group.
            palette = (0 ..< 16).map { i in
                let j = csa * 16 + i
                return memory.ct32(x: j & 7, y: j >> 3, bp: cbp, bw: 1)
            }
        case .ct32, .ct24:
            break
        }
        for y in 0 ..< h {
            for x in 0 ..< w {
                let c: SIMD4<UInt8>
                switch format {
                case .t8: c = palette[memory.t8(x: x, y: y, bp: tbp0, bw: tbw)]
                case .t4: c = palette[memory.t4(x: x, y: y, bp: tbp0, bw: tbw)]
                case .ct32: c = memory.ct32(x: x, y: y, bp: tbp0, bw: tbw)
                case .ct24:
                    var v = memory.ct32(x: x, y: y, bp: tbp0, bw: tbw)
                    v.w = 0x80
                    c = v
                }
                let o = (y * w + x) * 4
                rgba[o] = c.x; rgba[o + 1] = c.y; rgba[o + 2] = c.z
                rgba[o + 3] = tcc ? UInt8(min(255, Int(c.w) * 2)) : 255
            }
        }
        return DecodedTexture(width: w, height: h, rgba: rgba)
    }
}

extension GSSwizzle {
    /// PSMT4 block arrangement inside a 128×128 page (8 rows × 4 columns of 32×16 blocks).
    static let block4: [[Int]] = [
        [0, 2, 8, 10],
        [1, 3, 9, 11],
        [4, 6, 12, 14],
        [5, 7, 13, 15],
        [16, 18, 24, 26],
        [17, 19, 25, 27],
        [20, 22, 28, 30],
        [21, 23, 29, 31],
    ]

    /// PSMT4 nibble order inside a 32×16 block.
    static let column4: [[Int]] = [
        [0, 8, 32, 40, 64, 72, 96, 104, 2, 10, 34, 42, 66, 74, 98, 106, 4, 12, 36, 44, 68, 76, 100, 108, 6, 14, 38, 46, 70, 78, 102, 110],
        [16, 24, 48, 56, 80, 88, 112, 120, 18, 26, 50, 58, 82, 90, 114, 122, 20, 28, 52, 60, 84, 92, 116, 124, 22, 30, 54, 62, 86, 94, 118, 126],
        [65, 73, 97, 105, 1, 9, 33, 41, 67, 75, 99, 107, 3, 11, 35, 43, 69, 77, 101, 109, 5, 13, 37, 45, 71, 79, 103, 111, 7, 15, 39, 47],
        [81, 89, 113, 121, 17, 25, 49, 57, 83, 91, 115, 123, 19, 27, 51, 59, 85, 93, 117, 125, 21, 29, 53, 61, 87, 95, 119, 127, 23, 31, 55, 63],
        [192, 200, 224, 232, 128, 136, 160, 168, 194, 202, 226, 234, 130, 138, 162, 170, 196, 204, 228, 236, 132, 140, 164, 172, 198, 206, 230, 238, 134, 142, 166, 174],
        [208, 216, 240, 248, 144, 152, 176, 184, 210, 218, 242, 250, 146, 154, 178, 186, 212, 220, 244, 252, 148, 156, 180, 188, 214, 222, 246, 254, 150, 158, 182, 190],
        [129, 137, 161, 169, 193, 201, 225, 233, 131, 139, 163, 171, 195, 203, 227, 235, 133, 141, 165, 173, 197, 205, 229, 237, 135, 143, 167, 175, 199, 207, 231, 239],
        [145, 153, 177, 185, 209, 217, 241, 249, 147, 155, 179, 187, 211, 219, 243, 251, 149, 157, 181, 189, 213, 221, 245, 253, 151, 159, 183, 191, 215, 223, 247, 255],
        [256, 264, 288, 296, 320, 328, 352, 360, 258, 266, 290, 298, 322, 330, 354, 362, 260, 268, 292, 300, 324, 332, 356, 364, 262, 270, 294, 302, 326, 334, 358, 366],
        [272, 280, 304, 312, 336, 344, 368, 376, 274, 282, 306, 314, 338, 346, 370, 378, 276, 284, 308, 316, 340, 348, 372, 380, 278, 286, 310, 318, 342, 350, 374, 382],
        [321, 329, 353, 361, 257, 265, 289, 297, 323, 331, 355, 363, 259, 267, 291, 299, 325, 333, 357, 365, 261, 269, 293, 301, 327, 335, 359, 367, 263, 271, 295, 303],
        [337, 345, 369, 377, 273, 281, 305, 313, 339, 347, 371, 379, 275, 283, 307, 315, 341, 349, 373, 381, 277, 285, 309, 317, 343, 351, 375, 383, 279, 287, 311, 319],
        [448, 456, 480, 488, 384, 392, 416, 424, 450, 458, 482, 490, 386, 394, 418, 426, 452, 460, 484, 492, 388, 396, 420, 428, 454, 462, 486, 494, 390, 398, 422, 430],
        [464, 472, 496, 504, 400, 408, 432, 440, 466, 474, 498, 506, 402, 410, 434, 442, 468, 476, 500, 508, 404, 412, 436, 444, 470, 478, 502, 510, 406, 414, 438, 446],
        [385, 393, 417, 425, 449, 457, 481, 489, 387, 395, 419, 427, 451, 459, 483, 491, 389, 397, 421, 429, 453, 461, 485, 493, 391, 399, 423, 431, 455, 463, 487, 495],
        [401, 409, 433, 441, 465, 473, 497, 505, 403, 411, 435, 443, 467, 475, 499, 507, 405, 413, 437, 445, 469, 477, 501, 509, 407, 415, 439, 447, 471, 479, 503, 511],
    ]
}
