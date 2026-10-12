import Foundation
import Testing
@testable import UCFormats

// Synthetic data only: DSI blocks, MPEG-2 headers and ADPCM frames built here bit by bit.

/// Appends little-endian words the way the EE writes them.
private extension Array where Element == UInt8 {
    mutating func appendU32(_ value: UInt32) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24)])
    }
}

/// One DSI block: a header with `chunks` (stream id, payload) laid out from 0x40, then zeros.
private func dsiBlock(_ chunks: [(Int32, [UInt8])]) -> [UInt8] {
    var header: [UInt8] = []
    header.appendU32(UInt32(chunks.count))
    var offset = 0x40
    var payload: [UInt8] = []
    for (stream, bytes) in chunks {
        header.appendU32(UInt32(offset))
        header.appendU32(UInt32(bitPattern: stream))
        header.appendU32(UInt32(bytes.count))
        payload += bytes
        offset += bytes.count
    }
    var block = header + [UInt8](repeating: 0, count: 0x40 - header.count) + payload
    block += [UInt8](repeating: 0, count: DSIMovie.blockSize - block.count)
    return block
}

@Suite("DSI movie container")
struct DSIMovieTests {
    private let video = DSIMovie.StreamID.video
    private let audio = DSIMovie.StreamID.audio

    private func sample() -> [UInt8] {
        dsiBlock([(video, [1, 2, 3]), (audio, [0xA0, 0xA1])])
            + dsiBlock([(video, [4, 5]), (audio, [0xA2])])
            + dsiBlock([(video, [6])])
    }

    @Test("Chunks are concatenated per stream, in block order")
    func demuxInMemory() throws {
        var streams: [Int32: [UInt8]] = [:]
        let movie = try DSIMovie.demux(sample()) { streams[$0, default: []] += $1 }
        #expect(streams[video] == [1, 2, 3, 4, 5, 6])
        #expect(streams[audio] == [0xA0, 0xA1, 0xA2])
        #expect(movie.blocks.count == 3)
        #expect(movie.blocks[0].chunks == [
            DSIMovie.Chunk(offset: 0x40, stream: video, size: 3),
            DSIMovie.Chunk(offset: 0x43, stream: audio, size: 2),
        ])
        #expect(movie.size(of: video) == 6)
        #expect(movie.size(of: audio) == 3)
    }

    @Test("Reading a file block by block gives the same streams, also from an offset")
    func demuxFile() throws {
        let prefix = [UInt8](repeating: 0xEE, count: 0x800)
        let url = FileManager.default.temporaryDirectory.appending(path: "dsi-\(UUID().uuidString).bin")
        try Data(prefix + sample() + [0xEE]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var streams: [Int32: [UInt8]] = [:]
        let movie = try DSIMovie.demux(url: url, offset: 0x800, size: UInt64(3 * DSIMovie.blockSize)) {
            streams[$0, default: []] += $1
        }
        #expect(movie.blocks.count == 3)
        #expect(streams[video] == [1, 2, 3, 4, 5, 6])
        #expect(streams[audio] == [0xA0, 0xA1, 0xA2])
    }

    @Test("Malformed headers are rejected")
    func malformed() {
        let empty = [UInt8](repeating: 0, count: DSIMovie.blockSize)
        #expect(throws: DSIMovie.Failure.badHeader(block: 0)) { try DSIMovie.parseBlock(empty, index: 0) }

        var outside = dsiBlock([(video, [1])])
        outside[0xC] = 0xFF; outside[0xD] = 0xFF; outside[0xE] = 0x04 // size 0x4FFFF > block
        #expect(throws: DSIMovie.Failure.chunkOutOfBounds(block: 2)) { try DSIMovie.parseBlock(outside, index: 2) }

        var overlapping = dsiBlock([(video, [1])])
        overlapping[4] = 0 // chunk offset 0: inside the header itself
        #expect(throws: DSIMovie.Failure.chunkOutOfBounds(block: 0)) { try DSIMovie.parseBlock(overlapping, index: 0) }
    }
}

/// MSB-first bit writer for MPEG syntax.
private struct BitWriter {
    var bytes: [UInt8] = []
    private var bitCount = 0

    mutating func put(_ value: Int, _ bits: Int) {
        for bit in stride(from: bits - 1, through: 0, by: -1) {
            if bitCount % 8 == 0 { bytes.append(0) }
            if value >> bit & 1 != 0 { bytes[bytes.count - 1] |= 0x80 >> UInt8(bitCount % 8) }
            bitCount += 1
        }
    }

    mutating func startCode(_ code: UInt8) {
        precondition(bitCount % 8 == 0)
        bytes += [0, 0, 1, code]
        bitCount += 32
    }

    mutating func align() { while bitCount % 8 != 0 { put(0, 1) } }

    mutating func raw(_ data: [UInt8]) {
        precondition(bitCount % 8 == 0)
        bytes += data
        bitCount += data.count * 8
    }
}

@Suite("MPEG video stream scan")
struct MPEGVideoStreamTests {
    /// 720×576 MPEG-2 MP@ML, 25 fps, interlaced, bit rate value 0x3FFFF + extension 1, PAL
    /// display extension with BT.470 B/G colour, one GOP of I B B P, sequence end.
    private func stream(progressive: Bool) -> [UInt8] {
        var w = BitWriter()
        w.startCode(0xB3)
        w.put(720 & 0xFFF, 12); w.put(576 & 0xFFF, 12)
        w.put(2, 4); w.put(3, 4) // 4:3, 25 fps
        w.put(0x3FFFF, 18); w.put(1, 1); w.put(112, 10); w.put(0, 1); w.put(0, 1); w.put(0, 1)
        w.align()
        w.startCode(0xB5)
        w.put(1, 4); w.put(0x48, 8); w.put(progressive ? 1 : 0, 1); w.put(1, 2) // 4:2:0
        w.put(0, 2); w.put(0, 2); w.put(1, 12); w.put(1, 1); w.put(0, 8); w.put(0, 1); w.put(0, 2); w.put(0, 5)
        w.align()
        w.startCode(0xB5)
        w.put(2, 4); w.put(1, 3); w.put(1, 1); w.put(5, 8); w.put(5, 8); w.put(5, 8)
        w.put(720, 14); w.put(1, 1); w.put(576, 14); w.put(0, 3)
        w.align()
        w.startCode(0xB8)
        w.put(0, 25); w.put(1, 1); w.put(0, 1); w.put(0, 5)
        for (reference, type) in [(0, 1), (2, 3), (3, 3), (1, 2)] {
            w.startCode(0x00)
            w.put(reference, 10); w.put(type, 3); w.put(0xFFFF, 16); w.put(0, 3)
            w.align()
            // A slice with payload bytes that must not be taken for start codes.
            w.startCode(0x01)
            w.raw([0x12, 0x00, 0x00, 0x02, 0x34])
        }
        w.startCode(0xB7)
        return w.bytes
    }

    @Test("Sequence header and extensions are decoded")
    func headers() throws {
        let info = try #require(MPEGVideoStream.scan(stream(progressive: false)))
        #expect(info.width == 720 && info.height == 576)
        #expect(info.aspectRatioCode == 2)
        #expect(info.frameRateCode == 3)
        #expect(info.frameRate?.numerator == 25 && info.frameRate?.denominator == 1)
        #expect(info.bitRate == (1 << 18 | 0x3FFFF) * 400)
        #expect(info.isMPEG2)
        #expect(!info.isProgressive)
        #expect(info.profileAndLevel == 0x48)
        #expect(info.videoFormat == 1)
        #expect(info.colour == MPEGVideoStream.Colour(primaries: 5, transfer: 5, matrix: 5))
        #expect(try #require(MPEGVideoStream.scan(stream(progressive: true))).isProgressive)
    }

    @Test("Pictures, GOPs and the sequence end are counted")
    func counts() throws {
        let info = try #require(MPEGVideoStream.scan(stream(progressive: true)))
        #expect(info.pictures == 4)
        #expect(info.picturesByType == [1: 1, 2: 1, 3: 2])
        #expect(info.groupsOfPictures == 1)
        #expect(info.sequenceHeaders == 1)
        #expect(info.hasSequenceEnd)
        #expect(info.duration == 4.0 / 25.0)
    }

    @Test("Data without a sequence header is not a video stream")
    func notVideo() {
        #expect(MPEGVideoStream.scan([0, 0, 1, 0xB8, 0, 0, 0, 0]) == nil)
        #expect(MPEGVideoStream.scan([]) == nil)
    }
}

/// A 16-byte SPU ADPCM frame with one nibble repeated, or explicit nibbles.
private func adpcmFrame(filter: UInt8, shift: UInt8, nibbles: [UInt8]) -> [UInt8] {
    precondition(nibbles.count == 28)
    return [filter << 4 | shift, 0] + (0 ..< 14).map { nibbles[$0 * 2] & 0xF | nibbles[$0 * 2 + 1] << 4 }
}

@Suite("SPU ADPCM")
struct SPUADPCMTests {
    @Test("Filter 0 scales the sign-extended nibble by the shift")
    func rawNibbles() {
        let nibbles: [UInt8] = [1, 0xF, 7, 8] + Array(repeating: 0, count: 24)
        var decoder = SPUADPCMDecoder()
        var output: [Int16] = []
        decoder.decodeFrame(adpcmFrame(filter: 0, shift: 12, nibbles: nibbles), at: 0, into: &output)
        #expect(output.count == 28)
        #expect(Array(output.prefix(4)) == [1, -1, 7, -8])
        decoder.decodeFrame(adpcmFrame(filter: 0, shift: 0, nibbles: nibbles), at: 0, into: &output)
        #expect(Array(output[28 ..< 32]) == [4096, -4096, 28672, -32768])
    }

    @Test("Prediction carries over frames and clamps to 16 bits")
    func prediction() {
        var decoder = SPUADPCMDecoder()
        var output: [Int16] = []
        // Last sample 16384, then filter 1 (60/64) decays it: 15360, 14400, …
        decoder.decodeFrame(adpcmFrame(filter: 0, shift: 0, nibbles: Array(repeating: 0, count: 27) + [4]), at: 0, into: &output)
        decoder.decodeFrame(adpcmFrame(filter: 1, shift: 12, nibbles: Array(repeating: 0, count: 28)), at: 0, into: &output)
        #expect(output[27] == 16384)
        #expect(output[28] == 15360)
        #expect(output[29] == 14400)
        // Filter 1 on top of an already loud signal overshoots and clamps.
        var loud = SPUADPCMDecoder()
        var clamped: [Int16] = []
        loud.decodeFrame(adpcmFrame(filter: 0, shift: 0, nibbles: Array(repeating: 7, count: 28)), at: 0, into: &clamped)
        loud.decodeFrame(adpcmFrame(filter: 1, shift: 0, nibbles: Array(repeating: 7, count: 28)), at: 0, into: &clamped)
        #expect(clamped[28] == Int16.max)
    }

    @Test("Interleaved channels come out as interleaved PCM")
    func interleave() {
        let left = adpcmFrame(filter: 0, shift: 12, nibbles: Array(repeating: 1, count: 28))
        let right = adpcmFrame(filter: 0, shift: 12, nibbles: Array(repeating: 0xF, count: 28))
        // Interleave of two frames per channel; a trailing partial group is ignored.
        let bytes = left + left + right + right + left + left + right + right + [0, 0, 0]
        let pcm = SPUADPCMDecoder.decodeInterleaved(bytes, channels: 2, interleave: 32)
        #expect(pcm.count == 2 * 28 * 4)
        #expect(pcm.enumerated().allSatisfy { $0.element == ($0.offset % 2 == 0 ? 1 : -1) })
    }

    @Test("WAV header describes 16-bit PCM")
    func wav() {
        let data = [UInt8](WAVFile.pcm16([1, -2, 3, -4], channels: 2, sampleRate: 48_000))
        #expect(data.count == 44 + 8)
        #expect(Array(data[0 ..< 4]) == Array("RIFF".utf8) && Array(data[8 ..< 16]) == Array("WAVEfmt ".utf8))
        let reader = ByteReader(data)
        #expect(reader.u32(at: 4) == 44)
        #expect(reader.u16(at: 22) == 2 && reader.u32(at: 24) == 48_000 && reader.u32(at: 28) == 192_000)
        #expect(reader.u16(at: 34) == 16 && reader.u32(at: 40) == 8)
        #expect(Array(data[44 ..< 48]) == [1, 0, 0xFE, 0xFF])
    }
}
