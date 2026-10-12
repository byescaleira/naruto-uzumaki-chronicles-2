import Foundation
import Testing
@testable import UCFormats

/// Builds ADX streams for the tests (no game data).
enum ADXFixture {
    struct Frame {
        var scale: UInt16
        var nibbles: [Int8]  // 32 values in -8…7
    }

    static func be16(_ v: Int) -> [UInt8] { [UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)] }
    static func be32(_ v: Int) -> [UInt8] { be16(v >> 16) + be16(v) }

    /// Header of `version` 3 or 4; `loop` adds the loop block (and the room it needs).
    static func header(channels: Int, sampleCount: Int, rate: Int = 48000, cutoff: Int = 500, version: UInt8 = 4,
                       encoding: UInt8 = 3, loop: (start: Int, end: Int)? = nil, history: [Int16] = []) -> [UInt8] {
        let loopBase = version == 4 ? 0x20 : 0x14
        // "(c)CRI" starts 2 bytes before the copyright offset, right after the last field.
        let copyright = loop != nil ? loopBase + 0x1A : 0x22
        var h = [UInt8](repeating: 0, count: copyright + 4)
        h.replaceSubrange(0 ..< 0x14, with: [0x80, 0x00] + be16(copyright) + [encoding, 18, 4, UInt8(channels)]
            + be32(rate) + be32(sampleCount) + be16(cutoff) + [version, 0])
        if version == 4 {
            for (i, v) in history.enumerated() { h.replaceSubrange(0x18 + i * 2 ..< 0x1A + i * 2, with: be16(Int(v))) }
        }
        if let loop {
            let block = 18 * channels
            let fields = be16(0) + be16(1) + be16(0) + be16(1) + be32(loop.start)
                + be32(copyright + 4 + loop.start / 32 * block) + be32(loop.end) + be32(copyright + 4 + (loop.end + 31) / 32 * block)
            h.replaceSubrange(loopBase ..< loopBase + 0x18, with: fields)
        }
        h.replaceSubrange(copyright - 2 ..< copyright + 4, with: Array("(c)CRI".utf8))
        return h
    }

    static func frame(_ f: Frame) -> [UInt8] {
        var bytes = be16(Int(f.scale))
        for i in stride(from: 0, to: 32, by: 2) {
            bytes.append(UInt8(UInt8(bitPattern: f.nibbles[i]) & 0xF) << 4 | UInt8(UInt8(bitPattern: f.nibbles[i + 1]) & 0xF))
        }
        return bytes
    }

    static let endFrame: [UInt8] = [0x80, 0x01] + [UInt8](repeating: 0, count: 16)

    /// Reference model of the decoder, written independently from `ADXDecoder`.
    static func reference(_ frames: [Frame], c1: Int, c2: Int, h1: Int = 0, h2: Int = 0) -> [Int16] {
        var h1 = h1, h2 = h2
        var out: [Int16] = []
        for f in frames {
            let scale = Int(f.scale & 0x1FFF) + 1
            for n in f.nibbles {
                let s = max(-32768, min(32767, Int(n) * scale + (c1 * h1 + c2 * h2) >> 12))
                out.append(Int16(s))
                h2 = h1
                h1 = s
            }
        }
        return out
    }

    /// Closed-loop encoder of a mono signal: picks each frame's scale from its residual,
    /// then quantizes against the decoder's own history.
    static func encode(_ pcm: [Int16], c1: Int = 7400, c2: Int = -3342) -> [Frame] {
        var h1 = 0, h2 = 0
        var frames: [Frame] = []
        for start in stride(from: 0, to: pcm.count, by: 32) {
            let block = (0 ..< 32).map { start + $0 < pcm.count ? Int(pcm[start + $0]) : 0 }
            // Open-loop estimate of the residual range.
            var e1 = h1, e2 = h2, peak = 0
            for x in block {
                peak = max(peak, abs(x - (c1 * e1 + c2 * e2) >> 12))
                e2 = e1
                e1 = x
            }
            let scale = max(1, (peak + 6) / 7)
            var nibbles: [Int8] = []
            for x in block {
                let prediction = (c1 * h1 + c2 * h2) >> 12
                let q = max(-8, min(7, Int(((Double(x - prediction) / Double(scale))).rounded())))
                nibbles.append(Int8(q))
                let s = max(-32768, min(32767, q * scale + prediction))
                h2 = h1
                h1 = s
            }
            frames.append(Frame(scale: UInt16(scale - 1), nibbles: nibbles))
        }
        return frames
    }

    static func stream(channels: Int, sampleCount: Int, frames: [[Frame]], loop: (start: Int, end: Int)? = nil,
                       version: UInt8 = 4, history: [Int16] = []) -> [UInt8] {
        var bytes = header(channels: channels, sampleCount: sampleCount, version: version, loop: loop, history: history)
        for i in 0 ..< frames[0].count {
            for c in 0 ..< channels { bytes += frame(frames[c][i]) }
        }
        for _ in 0 ..< channels { bytes += endFrame }
        return bytes
    }

    static func sine(count: Int, period: Double, amplitude: Double = 12000, phase: Double = 0) -> [Int16] {
        (0 ..< count).map { Int16(amplitude * sin(2 * .pi * Double($0) / period + phase)) }
    }
}

@Suite("ADX")
struct ADXTests {
    @Test("Coefficients match FUN_0031a240 (500 Hz at 48 kHz)")
    func coefficients() throws {
        let header = try ADXHeader(ADXFixture.header(channels: 1, sampleCount: 32))
        #expect(header.coefficients == (7400, -3342))
    }

    @Test("Header fields, short header without loop")
    func header() throws {
        let header = try ADXHeader(ADXFixture.header(channels: 2, sampleCount: 1234, rate: 44100))
        #expect(header.channelCount == 2)
        #expect(header.sampleRate == 44100)
        #expect(header.sampleCount == 1234)
        #expect(header.dataOffset == 0x26)
        #expect(header.loop == nil)
        #expect(header.encoding == .standard)
        #expect(header.isDecodable)
    }

    @Test("Loop block of versions 3 and 4", arguments: [UInt8(3), 4])
    func loop(version: UInt8) throws {
        let header = try ADXHeader(ADXFixture.header(channels: 2, sampleCount: 9000, version: version, loop: (320, 8000)))
        let loop = try #require(header.loop)
        #expect(loop.start == 320)
        #expect(loop.end == 8000)
        #expect(loop.startByte == header.dataOffset + 10 * 36)
    }

    @Test("Non-ADX data and AHX are rejected")
    func rejects() throws {
        #expect(throws: ADXHeader.Failure.notADX) { try ADXHeader([UInt8](repeating: 0x41, count: 0x40)) }
        let ahx = try ADXHeader(ADXFixture.header(channels: 1, sampleCount: 32, encoding: 0x11))
        #expect(ahx.encoding == .ahx)
        #expect(!ahx.isDecodable)
        #expect(throws: ADXDecoder.Failure.unsupported(.ahx)) { try ADXDecoder.decode(ADXFixture.header(channels: 1, sampleCount: 32, encoding: 0x11)) }
    }

    @Test("Hand-made frames decode like the reference formula")
    func handMadeFrames() throws {
        let frames = [
            ADXFixture.Frame(scale: 0x00FF, nibbles: (0 ..< 32).map { Int8($0 % 16 - 8) }),
            ADXFixture.Frame(scale: 0x0010, nibbles: (0 ..< 32).map { Int8(7 - $0 % 16) }),
            // Large scale saturates: exercises the 16-bit clamp.
            ADXFixture.Frame(scale: 0x1FFF, nibbles: Array(repeating: 7, count: 32)),
        ]
        let bytes = ADXFixture.stream(channels: 1, sampleCount: 96, frames: [frames])
        let (_, samples) = try ADXDecoder.decode(bytes)
        #expect(samples == ADXFixture.reference(frames, c1: 7400, c2: -3342))
        #expect(samples.last == 32767)
    }

    @Test("First samples by hand: scale 0 is a step of 1")
    func firstSamples() throws {
        var nibbles = [Int8](repeating: 0, count: 32)
        nibbles[0] = 1
        nibbles[1] = -2
        let bytes = ADXFixture.stream(channels: 1, sampleCount: 32, frames: [[.init(scale: 0, nibbles: nibbles)]])
        let (_, samples) = try ADXDecoder.decode(bytes)
        // s0 = 1; s1 = -2 + (7400·1) >> 12 = -2 + 1 = -1; s2 = (7400·-1 - 3342·1) >> 12 = -3.
        #expect(Array(samples.prefix(3)) == [1, -1, -3])
    }

    @Test("Stereo frames interleave per frame; output interleaves per sample")
    func stereo() throws {
        let left = ADXFixture.encode(ADXFixture.sine(count: 320, period: 50))
        let right = ADXFixture.encode(ADXFixture.sine(count: 320, period: 23, amplitude: 4000))
        let bytes = ADXFixture.stream(channels: 2, sampleCount: 320, frames: [left, right])
        let (header, samples) = try ADXDecoder.decode(bytes)
        #expect(header.channelCount == 2)
        #expect(samples.count == 640)
        let l = ADXFixture.reference(left, c1: 7400, c2: -3342)
        let r = ADXFixture.reference(right, c1: 7400, c2: -3342)
        #expect(stride(from: 0, to: 640, by: 2).map { samples[$0] } == l)
        #expect(stride(from: 1, to: 640, by: 2).map { samples[$0] } == r)
    }

    @Test("A round trip through the test encoder tracks the signal")
    func roundTrip() throws {
        let pcm = ADXFixture.sine(count: 4800, period: 120)
        let bytes = ADXFixture.stream(channels: 1, sampleCount: pcm.count, frames: [ADXFixture.encode(pcm)])
        let (_, samples) = try ADXDecoder.decode(bytes)
        let error = zip(pcm, samples).map { abs(Int($0) - Int($1)) }.max() ?? .max
        #expect(samples.count == pcm.count)
        #expect(error < 400)
    }

    @Test("Version 4 initial history seeds the predictor")
    func initialHistory() throws {
        let frames = [ADXFixture.Frame(scale: 0, nibbles: Array(repeating: 0, count: 32))]
        let bytes = ADXFixture.stream(channels: 1, sampleCount: 32, frames: [frames], history: [1000, 900])
        let (_, samples) = try ADXDecoder.decode(bytes)
        #expect(samples == ADXFixture.reference(frames, c1: 7400, c2: -3342, h1: 1000, h2: 900))
        #expect(samples[0] == Int16((7400 * 1000 - 3342 * 900) >> 12))
    }

    @Test("The end-of-stream frame stops decoding")
    func endOfStream() throws {
        let frames = ADXFixture.encode(ADXFixture.sine(count: 64, period: 30))
        var bytes = ADXFixture.header(channels: 1, sampleCount: 96)
        bytes += ADXFixture.frame(frames[0]) + ADXFixture.frame(frames[1]) + ADXFixture.endFrame
        let header = try ADXHeader(bytes)
        var decoder = ADXDecoder(header: header)
        var out = [Int16](repeating: 0, count: 32)
        let results = bytes.withUnsafeBytes { raw in
            out.withUnsafeMutableBufferPointer { o in (0 ..< 3).map { _ in decoder.decodeFrame(raw, into: o.baseAddress!) } }
        }
        #expect(results == [true, true, false])
        // decode() pads the missing tail with silence.
        let (_, samples) = try ADXDecoder.decode(bytes)
        #expect(samples.count == 96)
        #expect(samples[64...].allSatisfy { $0 == 0 })
    }

    @Test("The cursor repeats the loop bit-exactly, splitting reads anywhere")
    func cursorLoop() throws {
        let pcm = ADXFixture.sine(count: 3200, period: 77)
        let loop = (start: 640, end: 2900)
        let bytes = ADXFixture.stream(channels: 1, sampleCount: pcm.count, frames: [ADXFixture.encode(pcm)], loop: loop)
        let header = try ADXHeader(bytes)
        let (_, linear) = try ADXDecoder.decode(bytes)

        var cursor = ADXCursor(header: header)
        var cache = [Int16](repeating: 0, count: cursor.cacheCount)
        var out: [Int16] = []
        let total = loop.end + 2 * (loop.end - loop.start) + 100
        bytes.withUnsafeBytes { raw in
            cache.withUnsafeMutableBufferPointer { cache in
                var chunk = 1
                while out.count < total {
                    // Odd-sized reads that straddle frames and the loop point.
                    let n = min(chunk, total - out.count)
                    let got = cursor.read(raw, count: n, cache: cache.baseAddress!) { run, count in
                        out.append(contentsOf: UnsafeBufferPointer(start: run, count: count))
                    }
                    #expect(got == n)
                    chunk = chunk % 97 + 13
                }
            }
        }
        let body = Array(linear[loop.start ..< loop.end])
        #expect(Array(out[0 ..< loop.end]) == Array(linear[0 ..< loop.end]))
        #expect(Array(out[loop.end ..< loop.end + body.count]) == body)
        #expect(Array(out[loop.end + body.count ..< loop.end + 2 * body.count]) == body)
        #expect(!cursor.isFinished)
    }

    @Test("Without looping the cursor stops at the sample count")
    func cursorEnd() throws {
        let pcm = ADXFixture.sine(count: 1000, period: 40)
        let bytes = ADXFixture.stream(channels: 1, sampleCount: pcm.count, frames: [ADXFixture.encode(pcm)], loop: (0, 960))
        var cursor = ADXCursor(header: try ADXHeader(bytes), loops: false)
        var cache = [Int16](repeating: 0, count: cursor.cacheCount)
        let got = bytes.withUnsafeBytes { raw in
            cache.withUnsafeMutableBufferPointer { cache in cursor.read(raw, count: 5000, cache: cache.baseAddress!) { _, _ in } }
        }
        #expect(got == 1000)
        #expect(cursor.isFinished)
    }

    @Test("CRIVolume follows FUN_00128090")
    func volume() {
        #expect(CRIVolume.attenuation(level: 128) == 0)
        #expect(CRIVolume.attenuation(level: 64) == 64)
        #expect(CRIVolume.attenuation(level: 32) == 128)
        #expect(CRIVolume.attenuation(level: 16) == 192)
        #expect(CRIVolume.attenuation(level: 1) == 942)
        #expect(CRIVolume.attenuation(level: 0) == 999)
        #expect(CRIVolume.gain(level: 0) == 0)
        #expect(abs(CRIVolume.gain(level: 64) - 0.4786) < 0.001)  // -6.4 dB
        #expect(CRIVolume.level(streamVolume: 0x6F) == 0x6F)
    }

    @Test("Sound table records")
    func soundTable() throws {
        var file = [UInt8](repeating: 0, count: 0x30)
        func put32(_ v: Int, at o: Int) { file.replaceSubrange(o ..< o + 4, with: (0 ..< 4).map { UInt8(truncatingIfNeeded: v >> ($0 * 8)) }) }
        put32(0x30, at: 0x08)
        file[0x10] = 2  // music
        file[0x12] = 0  // movies
        put32(0x40, at: 0x18)
        put32(0x40, at: 0x1C)
        file[0x28] = 1  // voices
        // Music records at 0x30, voice record at 0x40, names after.
        file += [0x48, 0, 0, 0, 0, 0x10, 0x6F, 2] + [0x4E, 0, 0, 0, 0, 0x10, 0x5A, 2]
        file += [0x54, 0, 0, 0, 0, 0x10, 0x50, 1]
        file += Array("bg000\0bg001\0xavoi0000\0".utf8)
        let table = try SoundTable(file)
        #expect(table.music.map(\.volume) == [0x6F, 0x5A])
        #expect(table.music.map(\.name) == ["bg000", "bg001"])
        #expect(table.voices.first?.name == "xavoi0000")
        #expect(table.voices.first?.channels == 1)
    }
}
