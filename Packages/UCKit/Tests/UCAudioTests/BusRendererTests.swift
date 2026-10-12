import Foundation
import Testing
@testable import UCAudio
import UCFormats

/// A synthetic 48 kHz ADX stream: `frames` pseudo-random frames per channel, optional loop.
private func makeADX(channels: Int, frames: Int, loop: (start: Int, end: Int)? = nil) -> [UInt8] {
    func be16(_ v: Int) -> [UInt8] { [UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)] }
    func be32(_ v: Int) -> [UInt8] { be16(v >> 16) + be16(v) }
    let copyright = loop != nil ? 0x3A : 0x22
    var bytes = [UInt8](repeating: 0, count: copyright + 4)
    bytes.replaceSubrange(0 ..< 0x14, with: [0x80, 0] + be16(copyright) + [3, 18, 4, UInt8(channels)]
        + be32(48000) + be32(frames * 32) + be16(500) + [4, 0])
    if let loop {
        bytes.replaceSubrange(0x20 ..< 0x38, with: be16(0) + be16(1) + be16(0) + be16(1) + be32(loop.start)
            + be32(copyright + 4 + loop.start / 32 * 18 * channels) + be32(loop.end) + be32(0))
    }
    bytes.replaceSubrange(copyright - 2 ..< copyright + 4, with: Array("(c)CRI".utf8))
    var seed: UInt32 = 0x1234_5678
    for _ in 0 ..< frames * channels {
        bytes += be16(0x0080)
        for _ in 0 ..< 16 {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            bytes.append(UInt8(truncatingIfNeeded: seed >> 24))
        }
    }
    return bytes + [0x80, 0x01] + [UInt8](repeating: 0, count: 16)
}

// Atomics are non-copyable: read them outside `#expect`.
private func active(_ renderer: BusRenderer) -> UInt { renderer.active.load(ordering: .relaxed) }
private func finished(_ voice: Voice) -> Bool { voice.finished.load(ordering: .relaxed) }

/// Renders `count` frames in buffers of `chunk` frames.
private func render(_ renderer: BusRenderer, count: Int, chunk: Int = 512) -> (left: [Float], right: [Float]) {
    var left = [Float](repeating: 0, count: count)
    var right = [Float](repeating: 0, count: count)
    var done = 0
    while done < count {
        let n = min(chunk, count - done)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                renderer.render(frames: n, left: l.baseAddress! + done, right: r.baseAddress! + done)
            }
        }
        done += n
    }
    return (left, right)
}

@Suite("Bus renderer")
struct BusRendererTests {
    @Test("Stereo output is the decoded PCM, scaled by the stream gain")
    func stereo() throws {
        let bytes = makeADX(channels: 2, frames: 40)
        let (_, pcm) = try ADXDecoder.decode(bytes)
        let renderer = BusRenderer()
        let voice = Voice(track: try ADXTrack(bytes), loops: false, gain: 0.5, fadeInFrames: 0)
        renderer.requested.store(voice.bits, ordering: .sequentiallyConsistent)
        let (left, right) = render(renderer, count: 1280, chunk: 333)
        for i in 0 ..< 1280 {
            #expect(left[i] == Float(pcm[2 * i]) * 0.5 / 32768)
            #expect(right[i] == Float(pcm[2 * i + 1]) * 0.5 / 32768)
        }
        #expect(active(renderer) == voice.bits)
        #expect(!finished(voice))
        _ = render(renderer, count: 1)
        #expect(finished(voice))
    }

    @Test("Mono streams play on both channels")
    func mono() throws {
        let bytes = makeADX(channels: 1, frames: 4)
        let renderer = BusRenderer()
        let voice = Voice(track: try ADXTrack(bytes), loops: false, gain: 1, fadeInFrames: 0)
        renderer.requested.store(voice.bits, ordering: .sequentiallyConsistent)
        let (left, right) = render(renderer, count: 200)
        #expect(left == right)
        #expect(left[128...].allSatisfy { $0 == 0 })
        #expect(left.contains { $0 != 0 })
    }

    @Test("Looping continues seamlessly across render buffers")
    func loop() throws {
        let loop = (start: 96, end: 1000)
        let bytes = makeADX(channels: 1, frames: 40, loop: loop)
        let (_, pcm) = try ADXDecoder.decode(bytes)
        let renderer = BusRenderer()
        let voice = Voice(track: try ADXTrack(bytes), loops: true, gain: 1, fadeInFrames: 0)
        renderer.requested.store(voice.bits, ordering: .sequentiallyConsistent)
        let count = loop.end + 3 * (loop.end - loop.start)
        let (left, _) = render(renderer, count: count, chunk: 471)
        let expected = Array(pcm[0 ..< loop.end]) + Array(repeating: Array(pcm[loop.start ..< loop.end]), count: 3).joined()
        #expect(left == expected.map { Float($0) / 32768 })
    }

    @Test("A new request fades the old stream out, then starts the new one")
    func fadeSwitch() throws {
        let bytes = makeADX(channels: 1, frames: 200)
        let (_, pcm) = try ADXDecoder.decode(bytes)
        let track = try ADXTrack(bytes)
        let renderer = BusRenderer()
        let first = Voice(track: track, loops: false, gain: 1, fadeInFrames: 0)
        renderer.requested.store(first.bits, ordering: .sequentiallyConsistent)
        _ = render(renderer, count: 256, chunk: 256)

        let second = Voice(track: track, loops: false, gain: 1, fadeInFrames: 0)
        renderer.fadeOutFrames.store(256, ordering: .relaxed)
        renderer.requested.store(second.bits, ordering: .sequentiallyConsistent)
        let (fading, _) = render(renderer, count: 256, chunk: 256)
        // Still the first stream, under a linear ramp down to silence.
        #expect(active(renderer) == first.bits)
        for i in 0 ..< 256 {
            let level = max(0, 1 - Float(i + 1) / 256)
            #expect(abs(fading[i] - Float(pcm[256 + i]) / 32768 * level) < 1e-6)
        }
        let (next, _) = render(renderer, count: 256, chunk: 256)
        #expect(active(renderer) == second.bits)
        #expect(next == pcm[0 ..< 256].map { Float($0) / 32768 })
    }

    @Test("Stopping releases the voice and outputs silence")
    func stop() throws {
        let bytes = makeADX(channels: 2, frames: 10)
        let renderer = BusRenderer()
        let voice = Voice(track: try ADXTrack(bytes), loops: true, gain: 1, fadeInFrames: 0)
        renderer.requested.store(voice.bits, ordering: .sequentiallyConsistent)
        _ = render(renderer, count: 100)
        renderer.fadeOutFrames.store(0, ordering: .relaxed)
        renderer.requested.store(0, ordering: .sequentiallyConsistent)
        let (left, right) = render(renderer, count: 100)
        #expect(left.allSatisfy { $0 == 0 } && right.allSatisfy { $0 == 0 })
        #expect(renderer.inUse() == (0, 0, 0))
    }

    @Test("Fade-in ramps from silence")
    func fadeIn() throws {
        let bytes = makeADX(channels: 1, frames: 10)
        let (_, pcm) = try ADXDecoder.decode(bytes)
        let renderer = BusRenderer()
        let voice = Voice(track: try ADXTrack(bytes), loops: false, gain: 1, fadeInFrames: 100)
        renderer.requested.store(voice.bits, ordering: .sequentiallyConsistent)
        let (left, _) = render(renderer, count: 200)
        for i in 0 ..< 200 {
            let level = min(1, Float(i + 1) / 100)
            #expect(abs(left[i] - Float(pcm[i]) / 32768 * level) < 1e-6)
        }
    }

    @Test("Tracks at other rates are refused")
    func sampleRate() {
        var bytes = makeADX(channels: 1, frames: 1)
        bytes.replaceSubrange(8 ..< 12, with: [0, 0, 0xAC, 0x44])
        #expect(throws: ADXTrack.Failure.unsupportedSampleRate(44100)) { try ADXTrack(bytes) }
    }
}

@Suite("Audio system")
@MainActor
struct AudioSystemTests {
    @Test("Voices are kept while requested and freed once replaced")
    func collect() throws {
        let system = AudioSystem()
        weak var first: ADXTrack?
        do {
            let track = try ADXTrack(makeADX(channels: 2, frames: 10))
            first = track
            system.play(track, on: .music)
        }
        #expect(first != nil)
        #expect(system.isPlaying(.music))
        #expect(!system.isPlaying(.voice))
        // The engine isn't running, so no render callback holds the first voice: replacing
        // it frees the voice and with it the track.
        system.play(try ADXTrack(makeADX(channels: 1, frames: 10)), on: .music)
        #expect(first == nil)
        system.stop(.music)
        #expect(!system.isPlaying(.music))
        system.setVolume(0.25, for: .voice)
        #expect(system.volume(for: .voice) == 0.25)
    }

    @Test("The engine mixes both buses, with their volumes, bit-exactly at 48 kHz")
    func offlineMix() throws {
        let music = makeADX(channels: 2, frames: 40, loop: (start: 64, end: 1000))
        let voice = makeADX(channels: 1, frames: 8)
        let (_, musicPCM) = try ADXDecoder.decode(music)
        let (_, voicePCM) = try ADXDecoder.decode(voice)
        let system = try AudioSystem.offline()
        try system.start()
        system.setVolume(0.5, for: .voice)
        system.play(try ADXTrack(music), on: .music)
        system.play(try ADXTrack(voice), on: .voice, loops: false)
        var left: [Float] = [], right: [Float] = []
        for _ in 0 ..< 3 {
            let buffer = try system.renderOffline(frames: 512)
            left += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
            right += UnsafeBufferPointer(start: buffer.floatChannelData![1], count: Int(buffer.frameLength))
        }
        #expect(left.count == 1536)
        let musicLoop = Array(musicPCM[0 ..< 2000]) + Array(musicPCM[128 ..< 2000])
        for i in 0 ..< 1536 {
            let v = i < 256 ? Float(voicePCM[i]) / 32768 * 0.5 : 0
            #expect(abs(left[i] - (Float(musicLoop[2 * i]) / 32768 + v)) < 1e-5)
            #expect(abs(right[i] - (Float(musicLoop[2 * i + 1]) / 32768 + v)) < 1e-5)
        }
        #expect(!system.isPlaying(.voice))
        #expect(system.isPlaying(.music))
    }

    @Test("Durations convert to frames at 48 kHz")
    func frames() {
        #expect(AudioSystem.frames(.seconds(1)) == 48000)
        #expect(AudioSystem.frames(.milliseconds(500)) == 24000)
        #expect(AudioSystem.frames(.zero) == 0)
    }
}
