/// 2D sprite files (menus, HUD, loading screens): DIG sub-files whose first `u32` is the
/// section count 2 — an animation bank and a texture set (see re/NOTES.md, "2D sprites").
///
/// Recovered from `SLES_550.90`:
/// - `FUN_001bf610(file, n)` returns section `n` of a `{u32 count, {u32 offset, u32 size} × count}`
///   table (offsets relative to the table).
/// - `FUN_00262e50(file, animation, flags)` creates an animation instance from section 0 (the
///   bank, used at `+4`) and section 1 (the textures); `FUN_00262b50` / `FUN_002627d0` start it.
/// - `FUN_0025e9d0` draws an instance: per piece `FUN_002618d0` computes the four corners and
///   `FUN_00260a40` emits the GS packet (texture registers, `ALPHA_1`, a textured TRIFAN).
public struct SpriteFile: Sendable {
    public let bank: SpriteBank
    public let textures: SpriteTextureSet
    /// Upscaled copies of some textures (``HighResolution``), by texture index; used instead of
    /// the decoded texture when present.
    public var highResolution: [Int: DecodedTexture] = [:]

    public enum Failure: Error, Equatable {
        case notASpriteFile
        case truncated(String)
    }

    public init(_ bytes: [UInt8]) throws {
        let sections = try SectionTable(bytes)
        guard sections.ranges.count >= 2 else { throw Failure.notASpriteFile }
        bank = try SpriteBank(Array(bytes[sections.ranges[0]]))
        textures = try SpriteTextureSet(Array(bytes[sections.ranges[1]]))
    }

    /// Cheap check used to scan archives: two in-bounds sections, the first one a bank.
    public static func looksLikeSpriteFile(_ bytes: [UInt8]) -> Bool {
        guard let sections = try? SectionTable(bytes), sections.ranges.count == 2 else { return false }
        let bank = sections.ranges[0]
        return bank.count >= 0x30 && ByteReader(bytes).u32(at: bank.lowerBound) == SpriteBank.magic
    }
}

/// `{u32 count, {u32 offset, u32 size} × count}`, offsets relative to the table (`FUN_001bf610`).
public struct SectionTable: Sendable {
    public let ranges: [Range<Int>]

    public init(_ bytes: [UInt8]) throws {
        let r = ByteReader(bytes)
        guard bytes.count >= 4 else { throw SpriteFile.Failure.truncated("section table") }
        let count = Int(r.u32(at: 0))
        guard count > 0, count < 64, 4 + count * 8 <= bytes.count else { throw SpriteFile.Failure.notASpriteFile }
        ranges = try (0 ..< count).map { i in
            let offset = Int(r.u32(at: 4 + i * 8)), size = Int(r.u32(at: 8 + i * 8))
            guard offset >= 4 + count * 8, offset + size <= bytes.count else { throw SpriteFile.Failure.truncated("section \(i)") }
            return offset ..< offset + size
        }
    }
}

/// Section 0 of a sprite file: frames, animations, keys and pieces.
///
/// Layout (all offsets relative to `base` = section + 4, as `FUN_00262b50` stores it):
///
/// | Offset | Field |
/// | --- | --- |
/// | section + 0 | `u32` 0x8001 |
/// | base + 0 | `u16` frame, animation, key, piece counts |
/// | base + 0x10 | `u32` offsets of the frame (12 B), animation (12 B), key (32 B) and piece (32 B) tables |
public struct SpriteBank: Sendable {
    static let magic: UInt32 = 0x8001

    /// A drawable frame: a run of pieces and their bounding box (`FUN_0025de40` recomputes it).
    public struct Frame: Sendable, Hashable {
        public var firstPiece: Int
        public var pieceCount: Int
        public var bounds: SIMD4<Int16>
    }

    /// A sequence of keys.
    public struct Animation: Sendable, Hashable {
        public var firstKey: Int
        public var keyCount: Int
        /// `+8` bit 0: morph — `FUN_0025e9d0` interpolates every piece's corners between the
        /// current frame and the next key's frame instead of only the key transform.
        public var flags: UInt8
        public var morphs: Bool { flags & 1 != 0 }
    }

    /// One key: a frame shown for `duration` ticks, with a transform that is linearly
    /// interpolated towards the next key (`FUN_0025e9d0`).
    public struct Key: Sendable, Hashable {
        public var frame: Int
        /// Ticks the key lasts; when `durationMax > duration`, a random length in between.
        public var duration: UInt16
        public var durationMax: UInt16
        /// Returned by the step function `FUN_00262570` when the key is left (1 on the last key).
        public var event: UInt16
        public var scale: SIMD2<Float>
        public var translation: SIMD2<Float>
        /// 4096 = one turn.
        public var rotation: Int16
        /// Animation to continue with; equal to the key's own animation for an in-animation step.
        public var nextAnimation: Int
        /// Next key, relative to the animation's first key.
        public var nextKey: Int
        /// 0x80 = opaque.
        public var alpha: UInt8
    }

    /// A textured quad of a frame.
    public struct Piece: Sendable, Hashable {
        /// Index into ``SpriteTextureSet/textures``.
        public var texture: Int
        /// Top-left corner, relative to the instance origin (the screen centre by default).
        public var position: SIMD2<Int16>
        /// Texel rectangle `u, v, w, h`, sampled with REGION_CLAMP.
        public var uv: SIMD4<UInt16>
        /// Size on screen.
        public var size: SIMD2<Int16>
        /// `FUN_002618d0` flags: with any bit set the key transform is applied around `pivot`;
        /// bit 0 skips the key scale, bit 1 the key rotation, bit 2 scaling the pivot, bit 3 rotating it.
        public var transformFlags: UInt8
        /// 0x80 = opaque.
        public var alpha: UInt8
        public var pivot: SIMD2<Int16>
        /// 4096 = one turn, around the piece centre.
        public var rotation: Int16
        /// `ALPHA_1` selector (`FUN_00260a40`): 0 = 0x44 blend, 1 = 0x48 additive, 2 = 0x42 subtractive.
        public var blend: UInt8
        /// Bit 0 mirrors horizontally, bit 1 vertically.
        public var flip: UInt8
    }

    public let frames: [Frame]
    public let animations: [Animation]
    public let keys: [Key]
    public let pieces: [Piece]

    /// A bank built in memory (tests, tools).
    public init(frames: [Frame], animations: [Animation], keys: [Key], pieces: [Piece]) {
        self.frames = frames
        self.animations = animations
        self.keys = keys
        self.pieces = pieces
    }

    public init(_ bytes: [UInt8]) throws {
        let r = ByteReader(bytes)
        guard bytes.count >= 0x34, r.u32(at: 0) == Self.magic else { throw SpriteFile.Failure.notASpriteFile }
        let base = 4
        let counts = (0 ..< 4).map { Int(r.u16(at: base + $0 * 2)) }
        let offsets = (0 ..< 4).map { base + Int(r.u32(at: base + 0x10 + $0 * 4)) }
        func table(_ i: Int, stride: Int) throws -> Int {
            guard offsets[i] >= base, offsets[i] + counts[i] * stride <= bytes.count else {
                throw SpriteFile.Failure.truncated("bank table \(i)")
            }
            return offsets[i]
        }
        let f = try table(0, stride: 12), a = try table(1, stride: 12)
        let k = try table(2, stride: 32), p = try table(3, stride: 32)
        frames = (0 ..< counts[0]).map { i in
            let o = f + i * 12
            return Frame(firstPiece: Int(r.u16(at: o)), pieceCount: Int(r.u16(at: o + 2)),
                         bounds: SIMD4(r.i16(at: o + 4), r.i16(at: o + 6), r.i16(at: o + 8), r.i16(at: o + 10)))
        }
        animations = (0 ..< counts[1]).map { i in
            let o = a + i * 12
            return Animation(firstKey: Int(r.u16(at: o)), keyCount: Int(r.u16(at: o + 2)), flags: r.u8(at: o + 8))
        }
        keys = (0 ..< counts[2]).map { i in
            let o = k + i * 32
            return Key(frame: Int(r.i16(at: o)), duration: r.u16(at: o + 2), durationMax: r.u16(at: o + 4),
                       event: r.u16(at: o + 6), scale: SIMD2(r.f32(at: o + 8), r.f32(at: o + 12)),
                       translation: SIMD2(r.f32(at: o + 16), r.f32(at: o + 20)), rotation: r.i16(at: o + 24),
                       nextAnimation: Int(r.u16(at: o + 26)), nextKey: Int(r.u16(at: o + 28)), alpha: r.u8(at: o + 30))
        }
        pieces = (0 ..< counts[3]).map { i in
            let o = p + i * 32
            return Piece(texture: Int(r.u16(at: o)), position: SIMD2(r.i16(at: o + 4), r.i16(at: o + 6)),
                         uv: SIMD4(r.u16(at: o + 8), r.u16(at: o + 10), r.u16(at: o + 12), r.u16(at: o + 14)),
                         size: SIMD2(r.i16(at: o + 16), r.i16(at: o + 18)), transformFlags: r.u8(at: o + 20),
                         alpha: r.u8(at: o + 21), pivot: SIMD2(r.i16(at: o + 22), r.i16(at: o + 24)),
                         rotation: r.i16(at: o + 26), blend: r.u8(at: o + 28), flip: r.u8(at: o + 30))
        }
        for frame in frames where frame.pieceCount > 0 && frame.firstPiece + frame.pieceCount > pieces.count {
            throw SpriteFile.Failure.truncated("frame pieces")
        }
        for animation in animations where animation.keyCount > 0 && animation.firstKey + animation.keyCount > keys.count {
            throw SpriteFile.Failure.truncated("animation keys")
        }
    }

    /// Pieces of a frame (empty when the index is out of range).
    public func pieces(of frame: Int) -> ArraySlice<Piece> {
        guard frames.indices.contains(frame) else { return [] }
        let f = frames[frame]
        return pieces[f.firstPiece ..< f.firstPiece + f.pieceCount]
    }
}

/// Section 1 of a sprite file: GS register packets, texture records and PSMCT32 uploads.
///
/// | Offset | Field |
/// | --- | --- |
/// | 0 | `u32` texture count N, `u32` upload count M |
/// | 0x10 | N × 0x50: GIFtag (A+D ×4) `CLAMP_1, MIPTBP1_1, TEX1_1, TEX0_1` (`FUN_00342f50`) |
/// | 0x10 + 0x50·N | N × 20: `{u16 level[4] (0xFFFF = none), u16 clut, u8 levels, u8 hasClut, u32 0, u16 w, u16 h}` (`FUN_00342f68`) |
/// | 0x10 + 0x64·N | M × 16: `{u32 0, u32 offset (from the record), u16 w, u16 h, u16 blocks, u16 tbp}` (`FUN_00342f98`) |
public struct SpriteTextureSet: Sendable {
    public struct Upload: Sendable, Hashable {
        public let offset: Int
        public let width: Int
        public let height: Int
        /// GS memory needed, in 256-byte blocks (what `FUN_001d1f00` allocates).
        public let blocks: Int
    }

    public struct Texture: Sendable, Hashable {
        public let tex0: GSTex0
        public let clamp: UInt64
        public let tex1: UInt64
        /// Upload indices of the base level and the mipmaps.
        public let levels: [Int]
        public let clut: Int?
    }

    public let textures: [Texture]
    public let uploads: [Upload]
    private let bytes: [UInt8]

    public init(_ bytes: [UInt8]) throws {
        self.bytes = bytes
        let r = ByteReader(bytes)
        guard bytes.count >= 16 else { throw SpriteFile.Failure.truncated("texture header") }
        let n = Int(r.u32(at: 0)), m = Int(r.u32(at: 4))
        let records = 0x10 + n * 0x50, table = 0x10 + n * 0x64
        guard n < 4096, m < 4096, table + m * 16 <= bytes.count else { throw SpriteFile.Failure.truncated("texture tables") }
        uploads = try (0 ..< m).map { i in
            let o = table + i * 16
            let upload = Upload(offset: o + Int(r.u32(at: o + 4)), width: Int(r.u16(at: o + 8)),
                                height: Int(r.u16(at: o + 10)), blocks: Int(r.u16(at: o + 12)))
            guard upload.offset + upload.width * upload.height * 4 <= bytes.count else {
                throw SpriteFile.Failure.truncated("upload \(i)")
            }
            return upload
        }
        textures = try (0 ..< n).map { i in
            var tex0: UInt64 = 0, clamp: UInt64 = 0, tex1: UInt64 = 0
            let packet = 0x10 + i * 0x50
            // GIFtag (NLOOP = 4, A+D), then {data, register} pairs.
            for q in 0 ..< 4 {
                let o = packet + 16 + q * 16
                switch r.u64(at: o + 8) & 0xFF {
                case 0x06: tex0 = r.u64(at: o)
                case 0x08: clamp = r.u64(at: o)
                case 0x14: tex1 = r.u64(at: o)
                default: break
                }
            }
            let o = records + i * 20
            let count = Int(r.u8(at: o + 10))
            let levels = (0 ..< min(count, 4)).map { Int(r.u16(at: o + $0 * 2)) }
            let clut = r.u8(at: o + 11) != 0 ? Int(r.u16(at: o + 8)) : nil
            guard levels.allSatisfy({ $0 < m }), clut.map({ $0 < m }) ?? true else {
                throw SpriteFile.Failure.truncated("texture \(i) uploads")
            }
            return Texture(tex0: GSTex0(tex0), clamp: clamp, tex1: tex1, levels: levels, clut: clut)
        }
    }

    /// Replays the uploads into a private GS memory (one block run per upload, like
    /// `FUN_001d06e0`) and samples every texture back at its `TEX0` size and format.
    /// Textures in formats the sprite path doesn't use come back `nil`.
    public func decode() -> [DecodedTexture?] {
        var bases: [Int] = []
        var next = 0
        for upload in uploads {
            bases.append(next)
            // Page-align each run so the PSMT8/PSMT4 read-back never overlaps a neighbour.
            next += (max(upload.blocks, (upload.width * upload.height * 4 + 255) / 256) + 31) / 32 * 32
        }
        var memory = GSLocalMemory(blocks: next + 32)
        for (upload, base) in zip(uploads, bases) {
            memory.uploadCT32(bytes[upload.offset ..< upload.offset + upload.width * upload.height * 4],
                              dbp: base, dbw: (upload.width + 63) / 64, width: upload.width, height: upload.height)
        }
        return textures.map { texture in
            guard let level = texture.levels.first else { return nil }
            var raw = texture.tex0.raw & ~0x3FFF & ~(UInt64(0x3FFF) << 37)
            raw |= UInt64(bases[level])
            if let clut = texture.clut { raw |= UInt64(bases[clut]) << 37 }
            return GSTex0(raw).read(from: memory)
        }
    }
}
