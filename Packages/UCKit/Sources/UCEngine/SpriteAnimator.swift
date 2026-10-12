import Foundation
import UCFormats
import UCRender

/// One running sprite animation: the instance `FUN_00262c20` allocates and
/// `FUN_002623f0` advances once per game frame.
///
/// Instance fields (`FUN_00262b50`, `FUN_002627d0`): `+8` animation, `+0xa` key, `+0xc` ticks
/// left in the key, `+0xe` optional-field mask (1 colour, 2 position, 4 scale, 8 rotation /
/// mirror, 0x10 clip) — only the fields the 2D screens use are kept here.
public struct SpriteAnimator: Sendable {
    public let bank: SpriteBank
    public private(set) var animation: Int
    public private(set) var key: Int
    /// Ticks left in the current key.
    public private(set) var remaining: Int
    /// Length of the current key, as drawn: the interpolation factor is `remaining / duration`.
    public private(set) var duration: Int

    /// Instance position (`FUN_00263150`), in pixels.
    public var position: SIMD2<Float> = .zero
    /// Instance colour (`FUN_00263280` / `FUN_00263200`), PS2 units (0x80 = 1).
    public var color: SIMD4<UInt8> = SIMD4(repeating: 0x80)
    /// Optional scale multiplied into the key transform (instance field 4).
    public var scale: SIMD2<Float> = SIMD2(1, 1)
    /// Optional rotation added to the key rotation (instance field 8), 4096 = one turn.
    public var rotation: Int = 0
    /// Instance mirror (field 8, byte 2): bit 0 negates x, bit 1 negates y around the origin.
    public var mirror: UInt8 = 0

    private var random: SpriteRandom

    /// `FUN_002627d0`: start `animation` at its first key.
    public init(bank: SpriteBank, animation: Int, seed: UInt32 = 1) {
        self.bank = bank
        random = SpriteRandom(seed: seed)
        self.animation = 0
        key = 0
        remaining = 0
        duration = 0
        start(animation)
    }

    /// `FUN_002627d0` (the game also accepts `animation == count`, one past the table).
    public mutating func start(_ animation: Int) {
        guard bank.animations.indices.contains(animation) else { return }
        self.animation = animation
        key = bank.animations[animation].firstKey
        duration = keyLength(key)
        remaining = duration
    }

    /// `FUN_002622f0(instance, 0)`: restart and hold on the first key.
    public mutating func rewind() {
        start(animation)
    }

    private mutating func keyLength(_ key: Int) -> Int {
        guard bank.keys.indices.contains(key) else { return 0 }
        let k = bank.keys[key]
        guard k.duration < k.durationMax else { return Int(k.duration) }
        // FUN_001e2fd0 returns rand() & 0xFFF, scaled by >> 10 as the game does.
        return Int(k.duration) + (Int(k.durationMax) - Int(k.duration)) * random.next() / 1024
    }

    /// `FUN_00262570`: leave the current key; returns its event value.
    private mutating func step() -> UInt16 {
        guard bank.keys.indices.contains(key) else { return 0 }
        let k = bank.keys[key]
        if k.nextAnimation == animation {
            key = k.nextKey + bank.animations[animation].firstKey
        } else {
            animation = k.nextAnimation
            // The game indexes the animation table with the *key* index here (`lh 0xa`), not
            // with the new animation; reproduced as is. The draw path (FUN_0025e9d0) instead
            // interpolates towards the new animation's first key.
            key = bank.animations.indices.contains(key) ? bank.animations[key].firstKey : 0
        }
        return k.event
    }

    /// `FUN_002623f0`: one game frame. Returns the event of the last key left, if any.
    @discardableResult
    public mutating func tick() -> UInt16 {
        var event: UInt16 = 0
        remaining -= 1
        var guardSteps = bank.keys.count + 1
        while remaining < 1, guardSteps > 0 {
            event = step()
            duration = keyLength(key)
            remaining = max(0, remaining + duration)
            guardSteps -= 1
        }
        return event
    }

    /// The key the current one interpolates towards (`FUN_0025e9d0`).
    private func targetKey(_ current: SpriteBank.Key) -> Int {
        if current.nextAnimation == animation {
            return current.nextKey + bank.animations[animation].firstKey
        }
        return bank.animations.indices.contains(current.nextAnimation) ? bank.animations[current.nextAnimation].firstKey : key
    }

    /// `FUN_0025e9d0`: the quads of the current frame, in draw order.
    /// `textureSizes` normalises texel coordinates (`TEX0` TW/TH of each texture).
    public func quads(textureSizes: [SIMD2<Int>]) -> [SpriteQuad] {
        guard bank.keys.indices.contains(key), bank.animations.indices.contains(animation) else { return [] }
        let current = bank.keys[key]
        let targetIndex = targetKey(current)
        guard bank.keys.indices.contains(targetIndex) else { return [] }
        let target = bank.keys[targetIndex]

        // Interpolation factor in 1/1024: 1024 at the start of the key, 0 at its end.
        let t = duration == 0 ? 1024 : remaining * 1024 / duration
        let ft = Float(t) / 1024
        var keyScale = target.scale + ft * (current.scale - target.scale)
        var keyTranslation = target.translation + ft * (current.translation - target.translation)
        let keyRotation = Int(target.rotation) + t * (Int(current.rotation) - Int(target.rotation)) / 1024 + rotation
        let keyAlpha = Int(target.alpha) + t * (Int(current.alpha) - Int(target.alpha)) / 1024
        keyScale *= scale
        keyTranslation *= scale

        let pieces = bank.pieces(of: current.frame)
        let morphTargets = bank.animations[animation].morphs ? Array(bank.pieces(of: target.frame)) : []
        var quads: [SpriteQuad] = []
        quads.reserveCapacity(pieces.count)
        for (i, piece) in pieces.enumerated() {
            var corners = Self.corners(piece, scale: keyScale, translation: keyTranslation, rotation: keyRotation, mirror: mirror)
            var pieceAlpha = Int(piece.alpha)
            if i < morphTargets.count {
                let other = Self.corners(morphTargets[i], scale: keyScale, translation: keyTranslation, rotation: keyRotation, mirror: mirror)
                for c in 0 ..< 4 { corners[c] = other[c] + ft * (corners[c] - other[c]) }
                pieceAlpha = Int(morphTargets[i].alpha) + t * (Int(piece.alpha) - Int(morphTargets[i].alpha)) / 1024
            }
            guard piece.texture < textureSizes.count else { continue }
            quads.append(Self.quad(piece, corners: corners.map { $0 + position }, textureSize: textureSizes[piece.texture],
                                   color: color, pieceAlpha: pieceAlpha & 0xFF, keyAlpha: keyAlpha & 0xFF))
        }
        return quads
    }

    /// `FUN_002618d0`: the four corners of a piece (TL, TR, BR, BL before transforms).
    static func corners(_ piece: SpriteBank.Piece, scale: SIMD2<Float>, translation: SIMD2<Float>,
                        rotation: Int, mirror: UInt8) -> [SIMD2<Float>] {
        var half = SIMD2(Float(piece.size.x), Float(piece.size.y)) * 0.5
        var signed = half
        if piece.flip & 1 != 0 { signed.x = -signed.x }
        if piece.flip & 2 != 0 { signed.y = -signed.y }
        var c = [SIMD2(-signed.x, -signed.y), SIMD2(signed.x, -signed.y), SIMD2(signed.x, signed.y), SIMD2(-signed.x, signed.y)]
        half = SIMD2(Float(piece.size.x), Float(piece.size.y)) * 0.5
        if Int(piece.rotation) & 0xFFF != 0 { c = c.map { rotate($0, Int(piece.rotation)) } }
        let origin = half + SIMD2(Float(piece.position.x), Float(piece.position.y))
        c = c.map { $0 + origin }
        let flags = piece.transformFlags
        if flags == 0 {
            c = c.map { $0 * scale }
            if rotation & 0xFFF != 0 { c = c.map { rotate($0, rotation) } }
        } else {
            let pivot = SIMD2(Float(piece.pivot.x), Float(piece.pivot.y))
            c = c.map { $0 - pivot }
            if flags & 1 == 0 { c = c.map { $0 * scale } }
            if flags & 2 == 0, rotation & 0xFFF != 0 { c = c.map { rotate($0, rotation) } }
            var p = pivot
            if flags & 4 == 0 { p *= scale }
            if flags & 8 == 0, rotation != 0 { p = rotate(p, rotation) }
            c = c.map { $0 + p }
        }
        c = c.map { $0 + translation }
        if mirror & 1 != 0 { c = c.map { SIMD2(-$0.x, $0.y) } }
        if mirror & 2 != 0 { c = c.map { SIMD2($0.x, -$0.y) } }
        return c
    }

    static func rotate(_ p: SIMD2<Float>, _ angle: Int) -> SIMD2<Float> {
        let a = Float(angle) * .pi / 2048
        let (s, c) = (sinf(a), cosf(a))
        return SIMD2(c * p.x - s * p.y, s * p.x + c * p.y)
    }

    /// `FUN_00260a40`: texture coordinates, REGION_CLAMP and the vertex colour of a piece.
    static func quad(_ piece: SpriteBank.Piece, corners: [SIMD2<Float>], textureSize: SIMD2<Int>,
                     color: SIMD4<UInt8>, pieceAlpha: Int, keyAlpha: Int) -> SpriteQuad {
        let size = SIMD2(Float(max(textureSize.x, 1)), Float(max(textureSize.y, 1)))
        let u = Float(piece.uv.x), v = Float(piece.uv.y), uw = Float(piece.uv.z), vh = Float(piece.uv.w)
        // ST = (texel · 16 ± 8) / (16 · 2^TW): half a texel in, towards the mirrored side when flipped.
        let s0 = (u + (piece.flip & 1 != 0 ? -0.5 : 0.5)) / size.x
        let t0 = (v + (piece.flip & 2 != 0 ? -0.5 : 0.5)) / size.y
        let uv = SIMD4(s0, t0, s0 + uw / size.x, t0 + vh / size.y)
        // CLAMP_1 = REGION_CLAMP [u, u + w − 1] × [v, v + h − 1], as bilinear sample positions.
        let clamp = SIMD4((u + 0.5) / size.x, (v + 0.5) / size.y, (u + max(uw, 1) - 0.5) / size.x, (v + max(vh, 1) - 0.5) / size.y)
        // RGBAQ: instance RGB; A = piece · instance · key alpha >> 14 (0x80 · 0x80 · 0x80 >> 14 = 0x80).
        let alpha = (pieceAlpha * Int(color.w) * keyAlpha) >> 14
        let rgba = SIMD4(Float(color.x), Float(color.y), Float(color.z), Float(alpha & 0xFF)) / 128
        return SpriteQuad(corners: (corners[0], corners[1], corners[2], corners[3]), uv: uv, clamp: clamp,
                          color: rgba, texture: UInt32(piece.texture), blend: SpriteBlend(rawValue: piece.blend) ?? .blend)
    }
}

/// Deterministic stand-in for the game's `rand() & 0xFFF` (`FUN_001e2fd0`).
struct SpriteRandom: Sendable {
    private var state: UInt32

    init(seed: UInt32) { state = seed == 0 ? 1 : seed }

    mutating func next() -> Int {
        state = state &* 1_103_515_245 &+ 12345
        return Int(state >> 16) & 0xFFF
    }
}
