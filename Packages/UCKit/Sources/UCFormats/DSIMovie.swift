import Foundation

/// `MV/MV00.DSI`: the game's movie, an interleave of an MPEG-2 video elementary stream and
/// a stereo SPU ADPCM audio stream in fixed 0x40000-byte blocks.
///
/// Recovered from the player at `FUN_00128840` (see re/NOTES.md): it reads the file through a
/// ring of 4 × 0x40000 buffers (`FUN_001bf7f0`) and registers two sinks by stream id
/// (`FUN_001bf7c0`): 0xFFFFC000 → `sceMpeg` video, 0xFFFFE000 → SPU audio. `FUN_001bfa20`
/// finds a sink's chunk in each block through the block header:
///
/// | Offset | Type | Field |
/// | --- | --- | --- |
/// | 0x0 | u32 | chunk count |
/// | 0x4 + 12·i | u32 | chunk offset (from the block start) |
/// | 0x8 + 12·i | s32 | stream id |
/// | 0xC + 12·i | u32 | chunk size |
///
/// The rest of the block is zero padding. Each stream is the concatenation of its chunks.
public struct DSIMovie: Sendable {
    public static let blockSize = 0x40000

    /// Stream ids registered by the player.
    public enum StreamID {
        public static let video: Int32 = -0x4000
        public static let audio: Int32 = -0x2000
    }

    /// Audio layout fed to the SPU: two channels of PS ADPCM interleaved every 0x100 bytes.
    /// The rate is not in the file (the EE passes it to the IOP sound server at run time); at
    /// 48 kHz, the SPU's native rate, MV00's audio (5,245,184 samples per channel = 109.27 s)
    /// is exactly as long as its video (2732 frames at 25 fps = 109.28 s).
    public static let audioChannels = 2
    public static let audioInterleave = 0x100
    public static let audioSampleRate = 48_000

    public struct Chunk: Sendable, Hashable {
        public let offset: Int
        public let stream: Int32
        public let size: Int
    }

    public struct Block: Sendable, Hashable {
        public let index: Int
        public let chunks: [Chunk]
    }

    public enum Failure: Error, Equatable {
        case truncated
        case badHeader(block: Int)
        case chunkOutOfBounds(block: Int)
    }

    public let blocks: [Block]

    public init(blocks: [Block]) { self.blocks = blocks }

    /// Total bytes of one stream over every block.
    public func size(of stream: Int32) -> Int {
        blocks.reduce(0) { total, block in total + block.chunks.filter { $0.stream == stream }.reduce(0) { $0 + $1.size } }
    }

    /// Parses one block header and checks every chunk lies inside the block.
    public static func parseBlock(_ bytes: some RandomAccessCollection<UInt8>, index: Int) throws -> Block {
        let block = ByteReader(Array(bytes))
        guard bytes.count >= 4 else { throw Failure.truncated }
        let count = Int(block.u32(at: 0))
        // A header with no chunk, or more chunks than fit in the 0x40-byte header area of the
        // known files, is not a DSI block.
        guard count > 0, 4 + count * 12 <= min(bytes.count, 0x800) else { throw Failure.badHeader(block: index) }
        let chunks = (0 ..< count).map { i in
            Chunk(offset: Int(block.u32(at: 4 + i * 12)),
                  stream: Int32(bitPattern: block.u32(at: 8 + i * 12)),
                  size: Int(block.u32(at: 12 + i * 12)))
        }
        guard chunks.allSatisfy({ $0.offset >= 4 + count * 12 && $0.offset + $0.size <= bytes.count }) else {
            throw Failure.chunkOutOfBounds(block: index)
        }
        return Block(index: index, chunks: chunks)
    }

    /// Demuxes a movie held in memory, calling `sink` with each chunk in file order.
    @discardableResult
    public static func demux(_ data: [UInt8], _ sink: (Int32, ArraySlice<UInt8>) throws -> Void) throws -> DSIMovie {
        var blocks: [Block] = []
        var start = 0
        while start < data.count {
            let bytes = data[start ..< min(start + blockSize, data.count)]
            let block = try parseBlock(bytes, index: blocks.count)
            for chunk in block.chunks {
                try sink(chunk.stream, bytes[(start + chunk.offset) ..< (start + chunk.offset + chunk.size)])
            }
            blocks.append(block)
            start += blockSize
        }
        return DSIMovie(blocks: blocks)
    }

    /// Demuxes `size` bytes of `url` from `offset` (the movie inside a disc image, or the
    /// file itself), reading one block at a time.
    @discardableResult
    public static func demux(url: URL, offset: UInt64 = 0, size: UInt64? = nil,
                             _ sink: (Int32, ArraySlice<UInt8>) throws -> Void) throws -> DSIMovie {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let total = try size ?? (handle.seekToEnd() - offset)
        try handle.seek(toOffset: offset)
        var blocks: [Block] = []
        var remaining = total
        while remaining > 0 {
            let wanted = Int(min(remaining, UInt64(blockSize)))
            guard let data = try handle.read(upToCount: wanted), data.count == wanted else { throw Failure.truncated }
            let bytes = [UInt8](data)
            let block = try parseBlock(bytes, index: blocks.count)
            for chunk in block.chunks {
                try sink(chunk.stream, bytes[chunk.offset ..< chunk.offset + chunk.size])
            }
            blocks.append(block)
            remaining -= UInt64(wanted)
        }
        return DSIMovie(blocks: blocks)
    }
}
