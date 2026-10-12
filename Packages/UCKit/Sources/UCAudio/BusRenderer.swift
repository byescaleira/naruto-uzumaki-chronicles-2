import Synchronization
import UCFormats

/// One playback of an ``ADXTrack``: decoder position, frame cache and per-play settings.
///
/// Created on the main actor; once published to a ``BusRenderer`` its mutable state is only
/// touched by the render thread. All storage is allocated in `init`, freed in `deinit`, and
/// `deinit` only ever runs on the main actor (see ``BusRenderer``).
final class Voice: @unchecked Sendable {
    let track: ADXTrack
    /// Linear gain of this play (the stream table's volume, see ``CRIVolume``).
    let gain: Float
    let fadeInFrames: Int
    /// Set by the render thread when a non-looping stream has played to its end.
    let finished = Atomic<Bool>(false)

    // Render-thread state, plus the track's bytes and layout cached so that the render
    // thread never loads (and retains) `track`.
    let cursor: UnsafeMutablePointer<ADXCursor>
    let cache: UnsafeMutablePointer<Int16>
    let stream: UnsafeRawBufferPointer
    let channels: Int

    init(track: ADXTrack, loops: Bool, gain: Float, fadeInFrames: Int) {
        self.track = track
        self.gain = gain
        self.fadeInFrames = fadeInFrames
        let cursor = ADXCursor(header: track.header, loops: loops)
        self.cursor = .allocate(capacity: 1)
        self.cursor.initialize(to: cursor)
        cache = .allocate(capacity: cursor.cacheCount)
        cache.initialize(repeating: 0, count: cursor.cacheCount)
        stream = UnsafeRawBufferPointer(track.bytes)
        channels = track.header.channelCount
    }

    deinit {
        cursor.deinitialize(count: 1)
        cursor.deallocate()
        cache.deallocate()
    }

    var bits: UInt { UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque()) }
}

/// Lock-free state shared by the main actor and one bus's render callback.
///
/// The main actor keeps every ``Voice`` alive and publishes the one to play in `requested`.
/// The render thread adopts it with a hazard-pointer handshake: it announces the candidate in
/// `incoming`, re-checks `requested`, then moves it to `active`. The main actor frees a voice
/// only when it is in none of the three slots (read in the order `requested`, `incoming`,
/// `active`), so the render thread never sees freed memory and never retains, releases,
/// allocates or locks.
final class BusRenderer: @unchecked Sendable {
    let requested = Atomic<UInt>(0)
    let incoming = Atomic<UInt>(0)
    let active = Atomic<UInt>(0)
    /// Fade applied to the playing voice before switching to a new request (frames).
    let fadeOutFrames = Atomic<Int>(0)
    /// Bit pattern of the bus's track-level gain (`Float`), smoothed per buffer.
    let gainBits = Atomic<UInt32>(Float(1).bitPattern)

    // Render-thread state.
    private var current: UInt = 0
    private var level: Float = 0
    private var levelStep: Float = 0
    private var levelTarget: Float = 1
    private var fadingOut = false
    private var smoothedGain: Float = 1

    /// Fills `frames` frames of planar float output (`right` nil for a mono bus).
    func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?) {
        left.update(repeating: 0, count: frames)
        right?.update(repeating: 0, count: frames)

        let wanted = requested.load(ordering: .sequentiallyConsistent)
        // Every play creates a new voice, so a request never returns to `current`.
        if wanted != current, !fadingOut {
            let fade = fadeOutFrames.load(ordering: .relaxed)
            if current != 0, fade > 0, level > 0 {
                fadingOut = true
                levelTarget = 0
                levelStep = 1 / Float(fade)
            } else {
                adopt(wanted)
            }
        } else if fadingOut, level <= 0 {
            fadingOut = false
            adopt(wanted)
        }

        let targetGain = Float(bitPattern: gainBits.load(ordering: .relaxed))
        guard current != 0, let pointer = UnsafeRawPointer(bitPattern: current) else {
            smoothedGain = targetGain
            return
        }
        // Locals: no class-property access (and exclusivity checks) per sample.
        var level = level, gain = smoothedGain
        let levelStep = levelStep, levelTarget = levelTarget
        let gainStep = (targetGain - gain) / Float(max(frames, 1))
        Unmanaged<Voice>.fromOpaque(pointer)._withUnsafeGuaranteedRef { voice in
            guard !voice.finished.load(ordering: .relaxed) else {
                // Nothing left to fade: a pending switch happens on the next buffer.
                level = levelTarget
                return
            }
            let channels = voice.channels
            let trackGain = voice.gain / 32768
            var o = 0
            let delivered = voice.cursor.pointee.read(voice.stream, count: frames, cache: voice.cache) { run, n in
                for i in 0 ..< n {
                    // Linear fade toward `levelTarget`, times the smoothed bus gain.
                    if level != levelTarget {
                        level = levelTarget > level ? min(level + levelStep, levelTarget) : max(level - levelStep, levelTarget)
                    }
                    gain += gainStep
                    let g = level * gain * trackGain
                    let l = Float(run[i * channels]) * g
                    left[o] = l
                    if let right { right[o] = channels > 1 ? Float(run[i * channels + 1]) * g : l }
                    o += 1
                }
            }
            if delivered < frames, voice.cursor.pointee.isFinished {
                voice.finished.store(true, ordering: .relaxed)
                level = levelTarget
            }
        }
        self.level = level
        smoothedGain = targetGain
    }

    private func adopt(_ candidate: UInt) {
        incoming.store(candidate, ordering: .sequentiallyConsistent)
        guard requested.load(ordering: .sequentiallyConsistent) == candidate else {
            // Superseded meanwhile: keep the current voice and retry next buffer.
            incoming.store(0, ordering: .sequentiallyConsistent)
            return
        }
        active.store(candidate, ordering: .sequentiallyConsistent)
        incoming.store(0, ordering: .sequentiallyConsistent)
        current = candidate
        if let pointer = UnsafeRawPointer(bitPattern: candidate) {
            let fadeIn = Unmanaged<Voice>.fromOpaque(pointer)._withUnsafeGuaranteedRef { $0.fadeInFrames }
            level = fadeIn > 0 ? 0 : 1
            levelStep = fadeIn > 0 ? 1 / Float(fadeIn) : 0
            levelTarget = 1
        }
    }

    /// Voice pointers the render thread may still touch (main actor side).
    func inUse() -> (UInt, UInt, UInt) {
        let r = requested.load(ordering: .sequentiallyConsistent)
        let i = incoming.load(ordering: .sequentiallyConsistent)
        let a = active.load(ordering: .sequentiallyConsistent)
        return (r, i, a)
    }
}
