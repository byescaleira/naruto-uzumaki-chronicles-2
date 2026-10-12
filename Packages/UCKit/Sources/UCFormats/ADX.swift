import Foundation

/// Header of a CRI `ADX` stream (the entries of `XA/XA.AFS` and `XA/XAVOICE.AFS`, played by
/// the ADXT library linked into `SLES_550.90`, `"ADXT/PS2EE Ver.9.18b"`). Field use follows
/// the game's own parser, `ADXB_DecodeHeaderAdx` = `FUN_00318538` (see re/NOTES.md).
///
/// All fields are big-endian:
///
/// | Offset | Type | Field |
/// | --- | --- | --- |
/// | 0x00 | u16 | `0x8000` |
/// | 0x02 | u16 | copyright offset; `"(c)CRI"` ends there and the frames start at +4 |
/// | 0x04 | u8 | encoding: 2 fixed coefficients, 3 standard, 4 exponential scale, 0x10/0x11 AHX |
/// | 0x05 | u8 | frame size (18) |
/// | 0x06 | u8 | bits per sample (4) |
/// | 0x07 | u8 | channels |
/// | 0x08 | u32 | sample rate |
/// | 0x0C | u32 | samples per channel |
/// | 0x10 | u16 | high-pass cutoff (Hz), source of the prediction coefficients |
/// | 0x12 | u8 | version (3 or 4) |
/// | 0x13 | u8 | flags (8/9 = encrypted) |
///
/// Version 4 adds the initial predictor history at 0x18 (`u16 h1, u16 h2` for channels 0
/// and 1; `FUN_0031a6c0`). The loop block (`FUN_0031a7f8`) sits at 0x14 (version 3) or 0x20
/// (version 4): `u16 inserted samples, u16 loop count (1 = looped), u16, u16 type,
/// u32 start sample, u32 start byte, u32 end sample, u32 end byte`. It only counts when the
/// copyright offset leaves room for it (0x2C / 0x38): short headers (0x24, all the voices)
/// put `"(c)CRI"` where the loop fields would be.
public struct ADXHeader: Sendable, Hashable {
    public enum Encoding: Sendable, Hashable {
        case fixedCoefficients
        case standard
        case exponential
        case ahx
        case unknown(UInt8)

        init(_ raw: UInt8) {
            switch raw {
            case 2: self = .fixedCoefficients
            case 3: self = .standard
            case 4: self = .exponential
            case 0x10, 0x11: self = .ahx
            default: self = .unknown(raw)
            }
        }
    }

    /// Loop region in samples per channel: playback jumps from `end` (exclusive) to `start`.
    public struct Loop: Sendable, Hashable {
        public let start: Int
        public let end: Int
        public let startByte: Int
        public let endByte: Int
    }

    public enum Failure: Error, Equatable {
        case notADX
        case truncated
    }

    /// Header bytes needed to parse every field, loop block included.
    public static let maximumHeaderSize = 0x3C

    public let encodingType: UInt8
    public let frameSize: Int
    public let bitsPerSample: Int
    public let channelCount: Int
    public let sampleRate: Int
    public let sampleCount: Int
    public let highpassCutoff: Int
    public let version: Int
    public let flags: UInt8
    /// Offset of the first frame (copyright offset + 4).
    public let dataOffset: Int
    public let loop: Loop?
    /// Predictor history at the first frame, `(h1, h2)` per channel (version 4, channels 0–1).
    public let initialHistory: [Int16]

    public var encoding: Encoding { Encoding(encodingType) }
    public var samplesPerFrame: Int { (frameSize - 2) * 8 / max(bitsPerSample, 1) }
    public var duration: Double { sampleRate > 0 ? Double(sampleCount) / Double(sampleRate) : 0 }
    public var isEncrypted: Bool { flags == 8 || flags == 9 }

    /// Whether ``ADXDecoder`` can decode this stream: ADPCM (types 2–4), 4-bit samples,
    /// unencrypted, 1…8 channels.
    public var isDecodable: Bool {
        switch encoding {
        case .fixedCoefficients, .standard, .exponential:
            bitsPerSample == 4 && frameSize > 2 && frameSize.isMultiple(of: 2) && !isEncrypted
                && (1 ... ADXDecoder.maximumChannels).contains(channelCount) && sampleRate > 0
        case .ahx, .unknown:
            false
        }
    }

    /// Parses the header at the start of `bytes` (at least the first
    /// ``maximumHeaderSize`` bytes, or the whole stream when shorter).
    public init(_ bytes: some Collection<UInt8>) throws {
        let b = Array(bytes.prefix(Self.maximumHeaderSize))
        guard b.count >= 0x14 else { throw Failure.truncated }
        func u16(_ o: Int) -> Int { Int(b[o]) << 8 | Int(b[o + 1]) }
        func u32(_ o: Int) -> Int { u16(o) << 16 | u16(o + 2) }
        guard b[0] == 0x80, b[1] == 0x00 else { throw Failure.notADX }
        let copyright = u16(2)
        guard copyright >= 0x12 else { throw Failure.notADX }
        encodingType = b[4]
        frameSize = Int(b[5])
        bitsPerSample = Int(b[6])
        channelCount = Int(b[7])
        sampleRate = u32(8)
        sampleCount = u32(0x0C)
        highpassCutoff = u16(0x10)
        version = Int(b[0x12])
        flags = b[0x13]
        dataOffset = copyright + 4

        if version >= 4, copyright >= 0x1C, b.count >= 0x20 {
            initialHistory = (0 ..< 4).map { Int16(truncatingIfNeeded: u16(0x18 + $0 * 2)) }
        } else {
            initialHistory = []
        }

        let loopBase = version == 4 ? 0x20 : 0x14
        if version == 3 || version == 4, copyright >= loopBase + 0x18, b.count >= loopBase + 0x18, u16(loopBase + 2) == 1 {
            let start = u32(loopBase + 8), end = u32(loopBase + 0x10)
            loop = start < end && end <= sampleCount
                ? Loop(start: start, end: end, startByte: u32(loopBase + 0x0C), endByte: u32(loopBase + 0x14))
                : nil
        } else {
            loop = nil
        }
    }

    /// Prediction coefficients (×4096) of the standard and exponential encodings, derived
    /// from the high-pass cutoff as `FUN_0031a240` does: single-precision math, truncated
    /// toward zero (500 Hz at 48 kHz gives 7400, -3342).
    public var coefficients: (Int32, Int32) {
        let z = Float(cos(Double(Float(highpassCutoff) * 6.283185 / Float(sampleRate))))
        let a = Float(1.4142135) - z
        let b = Float(0.41421354)
        let c = (a - ((a + b) * (a - b)).squareRoot()) / b
        return (Int32((c + c) * 4096), Int32(-c * c * 4096))
    }
}

/// Streaming ADX (CRI ADPCM) decoder.
///
/// A frame holds `u16 scale` (big-endian) + 32 signed 4-bit samples, high nibble first; the
/// channels are interleaved frame by frame. As in the game's block decoder (`FUN_0031b430`),
/// each sample is `nibble × ((scale & 0x1FFF) + 1) + (c1 × h1 + c2 × h2) >> 12`, clamped to
/// 16 bits, where `h1`/`h2` are the channel's two previous outputs. A frame whose scale has
/// bit 15 set ends the stream.
///
/// The decoder never allocates after `init`, so it can run on the real-time audio thread.
public struct ADXDecoder: Sendable {
    public static let maximumChannels = 8

    /// Resumable position: next frame and the per-channel predictor history.
    public struct State: Sendable {
        public var frame: Int
        var history: InlineArray<16, Int32>
    }

    public let header: ADXHeader
    public var state: State
    /// Samples per channel decoded by one ``decodeFrame(_:into:)`` call.
    public let samplesPerFrame: Int
    private let coefficient1: Int32
    private let coefficient2: Int32
    private let mode: UInt8
    private let startState: State

    public init(header: ADXHeader) {
        self.header = header
        samplesPerFrame = header.samplesPerFrame
        (coefficient1, coefficient2) = header.coefficients
        mode = header.encodingType
        var history = InlineArray<16, Int32>(repeating: 0)
        for (i, value) in header.initialHistory.enumerated() { history[i] = Int32(value) }
        startState = State(frame: 0, history: history)
        state = startState
    }

    /// Number of whole frames (per channel) that the header's sample count spans.
    public var frameCount: Int { (header.sampleCount + samplesPerFrame - 1) / samplesPerFrame }

    /// Restarts at frame `frame`: with the header's initial history at frame 0, a silent
    /// one elsewhere.
    public mutating func reset(toFrame frame: Int = 0) {
        state = frame == 0 ? startState : State(frame: frame, history: InlineArray(repeating: 0))
    }

    /// Decodes the next frame of every channel into `output`, interleaved
    /// (`output[sample * channels + channel]`, `samplesPerFrame × channels` values).
    ///
    /// `stream` is the whole ADX file. Returns `false` (leaving `output` untouched) at the
    /// end-of-stream frame or when the data runs out.
    public mutating func decodeFrame(_ stream: UnsafeRawBufferPointer, into output: UnsafeMutablePointer<Int16>) -> Bool {
        let channels = header.channelCount
        let frameSize = header.frameSize
        let base = header.dataOffset + state.frame * frameSize * channels
        guard base >= 0, base + frameSize * channels <= stream.count else { return false }
        let bytes = stream.baseAddress!.assumingMemoryBound(to: UInt8.self)
        let samples = samplesPerFrame
        for channel in 0 ..< channels {
            let frame = bytes + base + channel * frameSize
            let rawScale = Int32(frame[0]) << 8 | Int32(frame[1])
            if rawScale & 0x8000 != 0 { return false }
            var scale: Int32
            var c1 = coefficient1, c2 = coefficient2
            switch mode {
            case 4:
                scale = 1 << (12 - min(rawScale, 12))
            case 2:
                scale = (rawScale & 0x1FFF) + 1
                (c1, c2) = Self.fixedCoefficients(Int(frame[0] >> 5) & 3)
            default:
                scale = (rawScale & 0x1FFF) + 1
            }
            var h1 = state.history[channel * 2]
            var h2 = state.history[channel * 2 + 1]
            var out = output + channel
            for i in 0 ..< samples / 2 {
                let byte = Int32(Int8(bitPattern: frame[2 + i]))
                var sample = (byte >> 4) &* scale &+ ((c1 &* h1 &+ c2 &* h2) >> 12)
                sample = min(max(sample, -32768), 32767)
                out.pointee = Int16(truncatingIfNeeded: sample)
                out += channels
                h2 = h1
                h1 = sample
                sample = ((byte << 28) >> 28) &* scale &+ ((c1 &* h1 &+ c2 &* h2) >> 12)
                sample = min(max(sample, -32768), 32767)
                out.pointee = Int16(truncatingIfNeeded: sample)
                out += channels
                h2 = h1
                h1 = sample
            }
            state.history[channel * 2] = h1
            state.history[channel * 2 + 1] = h2
        }
        state.frame += 1
        return true
    }

    /// Prediction pairs (×4096) of encoding 2, selected by the top bits of the frame's scale
    /// (a switch rather than a table: no lazy global on the audio thread).
    static func fixedCoefficients(_ index: Int) -> (Int32, Int32) {
        switch index {
        case 1: (0x0F00, 0)
        case 2: (0x1CC0, -0x0D00)
        case 3: (0x1880, -0x0DC0)
        default: (0, 0)
        }
    }

    /// Decodes a whole stream to interleaved 16-bit PCM, `sampleCount × channels` values.
    /// Frames missing at the end (truncated data) decode as silence.
    public static func decode(_ stream: some ContiguousBytes) throws -> (header: ADXHeader, samples: [Int16]) {
        try stream.withUnsafeBytes { raw in
            let header = try ADXHeader(raw.prefix(ADXHeader.maximumHeaderSize))
            guard header.isDecodable else { throw Failure.unsupported(header.encoding) }
            var decoder = ADXDecoder(header: header)
            let channels = header.channelCount
            let perFrame = decoder.samplesPerFrame * channels
            let total = header.sampleCount * channels
            // Room for the last, partially used frame.
            var samples = [Int16](repeating: 0, count: decoder.frameCount * perFrame)
            samples.withUnsafeMutableBufferPointer { out in
                var o = 0
                while o + perFrame <= out.count, decoder.decodeFrame(raw, into: out.baseAddress! + o) {
                    o += perFrame
                }
            }
            samples.removeLast(samples.count - total)
            return (header, samples)
        }
    }

    public enum Failure: Error, Equatable {
        case unsupported(ADXHeader.Encoding)
    }
}

/// Sequential reader over an ADX stream that follows its loop: when `loops` is on and the
/// header has a loop, reaching `loop.end` jumps back to `loop.start` sample-exactly.
///
/// On the first pass the decoder state at the start of the loop's first frame is saved, and
/// every jump restores it, so each repetition is bit-identical to the first pass (the same
/// strategy as vgmstream). Never allocates: the frame cache is caller-owned
/// (``cacheCount`` values), so the cursor can live on the real-time audio thread.
public struct ADXCursor: Sendable {
    public private(set) var decoder: ADXDecoder
    public var loops: Bool
    /// Next sample (per channel) to be delivered.
    public private(set) var position = 0
    /// The stream ended (no loop, or the data ran out).
    public private(set) var isFinished = false
    private var loopState: ADXDecoder.State?
    /// Sample index of the first value in the frame cache (`-1`: cache empty).
    private var cacheStart = -1

    public init(header: ADXHeader, loops: Bool = true) {
        decoder = ADXDecoder(header: header)
        self.loops = loops
    }

    public var header: ADXHeader { decoder.header }
    /// Int16 values the frame cache passed to ``read(_:count:cache:_:)`` must hold.
    public var cacheCount: Int { decoder.samplesPerFrame * decoder.header.channelCount }

    /// Delivers up to `count` sample frames as runs of interleaved samples to `body` and
    /// returns how many were delivered (fewer only when the stream finished).
    public mutating func read(_ stream: UnsafeRawBufferPointer, count: Int, cache: UnsafeMutablePointer<Int16>,
                              _ body: (UnsafePointer<Int16>, Int) -> Void) -> Int {
        let header = decoder.header
        let perFrame = decoder.samplesPerFrame
        let channels = header.channelCount
        let loop = loops ? header.loop : nil
        let end = loop?.end ?? header.sampleCount
        var delivered = 0
        while delivered < count, !isFinished {
            if position >= end {
                guard let loop else {
                    isFinished = true
                    break
                }
                if let loopState {
                    decoder.state = loopState
                } else {
                    decoder.reset(toFrame: loop.start / perFrame)
                }
                cacheStart = -1
                position = loop.start
            }
            if cacheStart < 0 || position >= cacheStart + perFrame {
                let frame = decoder.state.frame
                if let loop, loopState == nil, frame == loop.start / perFrame {
                    loopState = decoder.state
                }
                guard decoder.decodeFrame(stream, into: cache) else {
                    isFinished = true
                    break
                }
                cacheStart = frame * perFrame
            }
            let n = min(min(cacheStart + perFrame, end) - position, count - delivered)
            body(cache + (position - cacheStart) * channels, n)
            position += n
            delivered += n
        }
        return delivered
    }
}
