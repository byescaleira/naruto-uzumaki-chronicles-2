/// Section 1 of a character/stage file: materials and the textures they sample.
///
/// Layout (`FUN_00342f40` / `FUN_00342f50` / `FUN_00342f68` / `FUN_00342f98`, used by the texture
/// uploader `FUN_001d06e0`):
/// - header `{u32 materialCount, u32 uploadCount, u32 0, u32 0}`;
/// - `materialCount` × 0x50 GIF packets: a GIFtag (NLOOP 4, A+D) then CLAMP_1, MIPTBP1_1, TEX1_1
///   and TEX0_1. TBP0/CBP are relative and patched when the texture is uploaded;
/// - `materialCount` × 20-byte texture records `{u16 image[4], u16 clut, u8 levels, u8 hasCLUT,
///   u32 0, u16 width, u16 height}` (unused mip levels are 0xFFFF);
/// - `uploadCount` × 16-byte PSMCT32 uploads `{u32 0, u32 offset, u16 w32, u16 h32, u16 qwords,
///   u16 runtime TBP}`, offset relative to the record (same as ``TextureSet``).
public struct ModelTextureTable: Sendable {
    public enum Failure: Error, Equatable {
        case truncated
        case invalidHeader
    }

    /// GS register state of a material packet.
    public struct Material: Sendable, Hashable {
        public let tex0: UInt64
        public let tex1: UInt64
        public let clamp: UInt64
        public let mipTBP1: UInt64

        /// Pixel storage format (0x13 = PSMT8, 0x14 = PSMT4, 0x00 = PSMCT32).
        public var psm: Int { Int((tex0 >> 20) & 0x3F) }
        public var width: Int { 1 << Int((tex0 >> 26) & 0xF) }
        public var height: Int { 1 << Int((tex0 >> 30) & 0xF) }
        /// Texture colour component: when set the texture alpha is used.
        public var usesTextureAlpha: Bool { (tex0 >> 34) & 1 != 0 }
        /// Texture function: 0 MODULATE, 1 DECAL, 2 HIGHLIGHT, 3 HIGHLIGHT2.
        public var function: Int { Int((tex0 >> 35) & 3) }
        /// CLAMP_1 WMS / WMT: 0 repeat, 1 clamp, 2/3 region modes.
        public var wrapS: Int { Int(clamp & 3) }
        public var wrapT: Int { Int((clamp >> 2) & 3) }
    }

    public struct Texture: Sendable, Hashable {
        /// Upload indices of up to 4 levels (base level first).
        public let levels: [Int]
        public let clut: Int?
        public let width: Int
        public let height: Int
    }

    public struct Upload: Sendable, Hashable {
        /// Byte range of the PSMCT32 pixels inside the section.
        public let data: Range<Int>
        public let width: Int
        public let height: Int
    }

    public let bytes: [UInt8]
    public let materials: [Material]
    /// One record per material.
    public let textures: [Texture]
    public let uploads: [Upload]

    public init(_ section: ArraySlice<UInt8>) throws {
        let bytes = Array(section)
        guard bytes.count >= 0x10 else { throw Failure.truncated }
        let r = ByteReader(bytes)
        let count = Int(r.u32(at: 0)), uploadCount = Int(r.u32(at: 4))
        let records = 0x10 + count * 0x50, uploadTable = records + count * 20
        guard count <= 4096, uploadCount <= 8192, uploadTable + uploadCount * 16 <= bytes.count else { throw Failure.invalidHeader }
        func u64(_ at: Int) -> UInt64 { UInt64(r.u32(at: at)) | UInt64(r.u32(at: at + 4)) << 32 }
        materials = (0 ..< count).map { i in
            let p = 0x10 + i * 0x50
            return Material(tex0: u64(p + 0x40), tex1: u64(p + 0x30), clamp: u64(p + 0x10), mipTBP1: u64(p + 0x20))
        }
        var uploads: [Upload] = []
        for i in 0 ..< uploadCount {
            let p = uploadTable + i * 16
            let w = Int(r.u16(at: p + 8)), h = Int(r.u16(at: p + 10))
            let start = p + Int(r.u32(at: p + 4))
            guard start + w * h * 4 <= bytes.count else { throw Failure.truncated }
            uploads.append(Upload(data: start ..< start + w * h * 4, width: w, height: h))
        }
        textures = try (0 ..< count).map { i in
            let p = records + i * 20
            let levelCount = Int(r.u8(at: p + 10))
            let levels = (0 ..< min(levelCount, 4)).map { Int(r.u16(at: p + $0 * 2)) }
            let clut = r.u8(at: p + 11) != 0 ? Int(r.u16(at: p + 8)) : nil
            guard levels.allSatisfy({ $0 < uploadCount }), (clut ?? 0) < uploadCount else { throw Failure.invalidHeader }
            return Texture(levels: levels, clut: clut, width: Int(r.u16(at: p + 16)), height: Int(r.u16(at: p + 18)))
        }
        self.bytes = bytes
        self.uploads = uploads
    }

    /// Decodes the base level of material `index` to RGBA8 (PSMT8 with a CSM1 CLUT, or PSMCT32).
    public func decodeTexture(_ index: Int) -> DecodedTexture? {
        guard index < textures.count, let level = textures[index].levels.first else { return nil }
        let image = uploads[level]
        switch materials[index].psm {
        case 0x13:
            guard let clutIndex = textures[index].clut, uploads[clutIndex].width * uploads[clutIndex].height == 256 else { return nil }
            let (indices, w, h) = GSSwizzle.indices(fromCT32: bytes[image.data], width: image.width, height: image.height)
            let palette = GSSwizzle.palette(fromCSM1: bytes[uploads[clutIndex].data])
            var rgba = [UInt8](repeating: 0, count: w * h * 4)
            for (i, value) in indices.enumerated() {
                let c = palette[Int(value)]
                rgba[i * 4] = c.x; rgba[i * 4 + 1] = c.y; rgba[i * 4 + 2] = c.z; rgba[i * 4 + 3] = c.w
            }
            return DecodedTexture(width: w, height: h, rgba: rgba)
        case 0x00:
            var rgba = Array(bytes[image.data])
            for i in stride(from: 3, to: rgba.count, by: 4) { rgba[i] = UInt8(min(255, Int(rgba[i]) * 2)) }
            return DecodedTexture(width: image.width, height: image.height, rgba: rgba)
        default:
            return nil
        }
    }
}
