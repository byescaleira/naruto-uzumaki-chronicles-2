import AVFoundation
import UCFormats

/// Streamed ADX playback on separate music and voice buses, like the game's two ADXT
/// channels (`FUN_0012b8c0`: channel 0 = `XA/XA.AFS`, channel 1 = `XA/XAVOICE.AFS`; one
/// stream at a time on each).
///
/// Each bus is an `AVAudioSourceNode` that decodes ADX directly in its render callback (a few
/// nanoseconds per sample) into its own mixer node; that mixer's input volume on the main
/// mixer is the bus volume. Starting a stream on a bus replaces the previous one, optionally
/// fading it out first; looped streams repeat their header's loop sample-exactly.
///
/// The render callbacks never allocate, lock or touch reference counts: see ``BusRenderer``.
/// Voices that the render thread has let go are freed by ``collect()``, which every call here
/// runs; the engine should also call it now and then (e.g. once per frame).
@MainActor
public final class AudioSystem {
    public enum Bus: Int, CaseIterable, Sendable {
        case music
        case voice
    }

    /// Rate of every bus. All of the game's streams are 48 kHz (`FUN_00127930` also creates
    /// its ADXT handles at 48000).
    public nonisolated static let sampleRate = 48_000.0

    private let engine = AVAudioEngine()
    private let renderers: [BusRenderer]
    private let mixers: [AVAudioMixerNode]
    /// Voices kept alive per bus until the render thread no longer references them.
    private var voices: [[Voice]]
    private var configurationObserver: (any NSObjectProtocol)?

    public init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 2)!
        renderers = Bus.allCases.map { _ in BusRenderer() }
        mixers = Bus.allCases.map { _ in AVAudioMixerNode() }
        voices = Bus.allCases.map { _ in [] }
        for (renderer, mixer) in zip(renderers, mixers) {
            let source = Self.sourceNode(format: format, renderer: renderer)
            engine.attach(source)
            engine.attach(mixer)
            engine.connect(source, to: mixer, format: format)
            engine.connect(mixer, to: engine.mainMixerNode, format: format)
        }
        // Output device changes stop the engine; restart it with the same graph.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { try? self?.start() }
        }
    }

    isolated deinit {
        engine.stop()
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
    }

    /// Built outside the main actor so that the render block is not main-actor isolated
    /// (it runs on the real-time audio thread).
    private nonisolated static func sourceNode(format: AVAudioFormat, renderer: BusRenderer) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { @Sendable _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard let left = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let right = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil
            renderer.render(frames: Int(frameCount), left: left, right: right)
            return noErr
        }
    }

    /// A system that renders on demand instead of to the output device (tests, tools):
    /// call ``start()`` then ``renderOffline(frames:)``.
    public static func offline(maximumFrames: Int = 4096) throws -> AudioSystem {
        let system = AudioSystem()
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        try system.engine.enableManualRenderingMode(.offline, format: format,
                                                    maximumFrameCount: AVAudioFrameCount(maximumFrames))
        return system
    }

    /// Renders the next `frames` frames of the mix (offline systems only).
    public func renderOffline(frames: Int) throws -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                      frameCapacity: AVAudioFrameCount(frames))!
        let status = try engine.renderOffline(AVAudioFrameCount(frames), to: buffer)
        guard status == .success else { throw OfflineFailure.status(status.rawValue) }
        collect()
        return buffer
    }

    public enum OfflineFailure: Error, Equatable {
        case status(Int)
    }

    public var isRunning: Bool { engine.isRunning }

    /// Starts audio output (on iOS/tvOS as an ambient session: it mixes with other audio and
    /// follows the silent switch).
    public func start() throws {
        #if os(iOS) || os(tvOS)
        if !engine.isInManualRenderingMode {
            try AVAudioSession.sharedInstance().setCategory(.ambient)
            try AVAudioSession.sharedInstance().setActive(true)
        }
        #endif
        if !engine.isRunning { try engine.start() }
    }

    public func pause() { engine.pause() }

    /// Plays `track` on `bus`, replacing what plays there. `gain` is linear (see
    /// ``CRIVolume/gain(level:)`` for the game's per-stream volumes); `fadeOut` applies to the
    /// stream being replaced, `fadeIn` to the new one.
    public func play(_ track: ADXTrack, on bus: Bus, loops: Bool = true, gain: Float = 1,
                     fadeIn: Duration = .zero, fadeOut: Duration = .zero) {
        let voice = Voice(track: track, loops: loops, gain: gain, fadeInFrames: Self.frames(fadeIn))
        voices[bus.rawValue].append(voice)
        request(voice.bits, on: bus, fadeOut: fadeOut)
    }

    /// Stops `bus`, fading out over `fadeOut`.
    public func stop(_ bus: Bus, fadeOut: Duration = .zero) {
        request(0, on: bus, fadeOut: fadeOut)
    }

    /// Bus volume (linear, 0…1), applied by the bus's mixer node.
    public func setVolume(_ volume: Float, for bus: Bus) {
        mixers[bus.rawValue].volume = volume
    }

    public func volume(for bus: Bus) -> Float {
        mixers[bus.rawValue].volume
    }

    /// Changes the level of the playing stream (linear), ramped over one render buffer, as the
    /// game does through `FUN_00128010` for its fades.
    public func setStreamGain(_ gain: Float, for bus: Bus) {
        renderers[bus.rawValue].gainBits.store(gain.bitPattern, ordering: .relaxed)
    }

    /// Whether `bus` has a stream requested that has not played to its end.
    public func isPlaying(_ bus: Bus) -> Bool {
        collect()
        let requested = renderers[bus.rawValue].requested.load(ordering: .sequentiallyConsistent)
        guard requested != 0, let voice = voices[bus.rawValue].first(where: { $0.bits == requested }) else {
            return false
        }
        return !voice.finished.load(ordering: .relaxed)
    }

    /// Frees the voices that no render callback can still reach.
    public func collect() {
        for bus in Bus.allCases {
            let (requested, incoming, active) = renderers[bus.rawValue].inUse()
            voices[bus.rawValue].removeAll { voice in
                let bits = voice.bits
                return bits != requested && bits != incoming && bits != active
            }
        }
    }

    private func request(_ bits: UInt, on bus: Bus, fadeOut: Duration) {
        let renderer = renderers[bus.rawValue]
        renderer.fadeOutFrames.store(Self.frames(fadeOut), ordering: .relaxed)
        renderer.requested.store(bits, ordering: .sequentiallyConsistent)
        collect()
    }

    nonisolated static func frames(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        return max(0, Int((Double(seconds) + Double(attoseconds) * 1e-18) * sampleRate))
    }
}
