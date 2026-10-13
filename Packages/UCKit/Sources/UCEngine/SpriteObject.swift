import simd
import UCFormats
import UCRender

/// A 2D object: an ordered list of animation layers sharing a position (the 0x4C-byte object
/// initialised by `FUN_00265ab0`, with 0x94-byte layers added by `FUN_002644f0`).
///
/// Layer flags (`+4`, set / cleared by `FUN_00263410` / `FUN_00263480`): 0x20 hides the layer
/// (draw and update skip `flags & 0x23`), 0x8 pauses its animation, 0x4 holds it on the first
/// key, 0x80 positions it absolutely (ignoring the object), 0x100–0x800 alignment options of
/// `FUN_002644f0`.
public struct SpriteObject: Sendable {
    public struct Flags: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let hold = Flags(rawValue: 0x4)
        public static let paused = Flags(rawValue: 0x8)
        public static let hidden = Flags(rawValue: 0x20)
        public static let absolute = Flags(rawValue: 0x80)
        /// Alignment to the anchor animation's bounds: keep its left / top edge instead of the
        /// centre (0x100 / 0x400), or use the full width / height (0x200 / 0x800).
        public static let anchorLeft = Flags(rawValue: 0x100)
        public static let anchorFullWidth = Flags(rawValue: 0x200)
        public static let anchorTop = Flags(rawValue: 0x400)
        public static let anchorFullHeight = Flags(rawValue: 0x800)
    }

    public struct Layer: Sendable {
        public let id: Int
        public var animator: SpriteAnimator
        public var flags: Flags
        /// Draw pass: `FUN_00265180` draws priority 0 first, then 1, … (`FUN_002634f0`).
        public var priority: Int
        /// `+0x24/+0x28`: centre of the anchor animation's first frame (`FUN_002644f0`).
        public var anchor: SIMD2<Int>
        /// `+0x2c/+0x30`: half-size offsets from the alignment options of `FUN_002644f0`.
        public var alignment: SIMD2<Int>
        /// `+0x34/+0x38`: set by `FUN_00264060`.
        public var position: SIMD2<Int>
        /// The texture set the layer samples (the object's sprite file).
        public let textures: Int
        /// Wide-screen fill (not in the game, which only shows 512 × 448).
        public var widescreen: Widescreen = .none
    }

    /// How a layer covers a screen wider than 4:3. The original backdrops end at x = ±256;
    /// `.mirror` repeats the layer mirrored about both edges (seamless for the game's noise,
    /// fire and pattern backdrops, and never stretched).
    public enum Widescreen: Sendable {
        case none
        case mirror
    }

    /// Half the original frame width: the 4:3 edges the mirrored copies reflect about.
    public static let frameHalfWidth: Float = 256

    /// `+8/+0xc` position and `+0x20/+0x24` origin (both pixels).
    public var position: SIMD2<Int> = .zero
    public var origin: SIMD2<Int> = .zero
    public private(set) var layers: [Layer] = []

    public init(origin: SIMD2<Int> = .zero) {
        self.origin = origin
    }

    /// `FUN_002644f0(object, id, animation, anchor, file, flags, align)`: append a layer playing
    /// `animation`, offset to the centre of `anchorAnimation`'s first frame when given.
    /// `align` bits 0–3 shift by ± half the layer's own bounds (right, down, left, up).
    public mutating func add(id: Int, animation: Int, anchorAnimation: Int? = nil, bank: SpriteBank,
                             textures: Int = 0, flags: Flags = [], align: UInt8 = 0) {
        var animator = SpriteAnimator(bank: bank, animation: animation, seed: UInt32(truncatingIfNeeded: id &* 2654435761 &+ 1))
        var anchor = SIMD2<Int>.zero
        if let anchorAnimation {
            let anchorBounds = SpriteAnimator(bank: bank, animation: anchorAnimation).bounds()
            anchor.x = anchorBounds.x + (flags.contains(.anchorLeft) ? 0 : flags.contains(.anchorFullWidth) ? anchorBounds.z : anchorBounds.z >> 1)
            anchor.y = anchorBounds.y + (flags.contains(.anchorTop) ? 0 : flags.contains(.anchorFullHeight) ? anchorBounds.w : anchorBounds.w >> 1)
        }
        let own = animator.bounds()
        var alignment = SIMD2<Int>.zero
        if align & 1 != 0 { alignment.x = own.z >> 1 } else if align & 4 != 0 { alignment.x = -(own.z >> 1) }
        if align & 2 != 0 { alignment.y = own.w >> 1 } else if align & 8 != 0 { alignment.y = -(own.w >> 1) }
        animator.color.w = 0x80
        var layer = Layer(id: id, animator: animator, flags: flags, priority: 0, anchor: anchor,
                          alignment: alignment, position: .zero, textures: textures)
        place(&layer)
        layers.append(layer)
    }

    private func place(_ layer: inout Layer) {
        var p = layer.alignment &+ layer.anchor &+ layer.position
        if !layer.flags.contains(.absolute) { p &+= position &+ origin }
        layer.animator.position = SIMD2(Float(p.x), Float(p.y))
    }

    private mutating func update(_ id: Int, _ body: (inout Layer) -> Void) {
        guard let i = layers.firstIndex(where: { $0.id == id }) else { return }
        body(&layers[i])
        place(&layers[i])
    }

    /// `FUN_00264060`.
    public mutating func setPosition(layer id: Int, _ p: SIMD2<Int>) { update(id) { $0.position = p } }
    /// `FUN_00263410`.
    public mutating func insert(_ flags: Flags, layer id: Int) { update(id) { $0.flags.formUnion(flags) } }
    /// `FUN_00263480`.
    public mutating func remove(_ flags: Flags, layer id: Int) { update(id) { $0.flags.subtract(flags) } }
    public mutating func setWidescreen(layer id: Int, _ fill: Widescreen) { update(id) { $0.widescreen = fill } }
    /// `FUN_002634f0`.
    public mutating func setPriority(layer id: Int, _ priority: Int) { update(id) { $0.priority = priority } }
    /// `FUN_00263550`: switch a layer to another animation.
    public mutating func play(layer id: Int, animation: Int, restart: Bool = false) {
        update(id) { layer in
            if restart || layer.animator.animation != animation { layer.animator.start(animation) }
        }
    }

    /// `FUN_00263c20`: the instance alpha (0x80 = opaque).
    public mutating func setAlpha(layer id: Int, _ alpha: UInt8) { update(id) { $0.animator.color.w = alpha } }
    /// `FUN_00263880`: the instance scale.
    public mutating func setScale(layer id: Int, _ scale: SIMD2<Float>) { update(id) { $0.animator.scale = scale } }

    public func layer(_ id: Int) -> Layer? { layers.first { $0.id == id } }

    public mutating func setObjectPosition(_ p: SIMD2<Int>) {
        position = p
        for i in layers.indices { place(&layers[i]) }
    }

    /// `FUN_00265390` (animation part): advance every visible layer by one game frame.
    public mutating func tick() {
        for i in layers.indices where layers[i].flags.rawValue & 0x12 == 0 && !layers[i].flags.contains(.hidden) {
            if layers[i].flags.contains(.hold) {
                layers[i].animator.rewind()
            } else if !layers[i].flags.contains(.paused) {
                layers[i].animator.tick()
            }
        }
    }

    /// `FUN_00265180`: quads of the visible layers, priority 0 first, insertion order within one.
    public func draw(textureSizes: [[SIMD2<Int>]], into quads: inout [SpriteQuad], textureBase: [UInt32] = [0]) {
        guard let maxPriority = layers.map(\.priority).max() else { return }
        for priority in 0 ... max(0, maxPriority) {
            for layer in layers where layer.priority == priority && layer.flags.rawValue & 0x23 == 0 {
                let sizes = textureSizes[min(layer.textures, textureSizes.count - 1)]
                let base = textureBase[min(layer.textures, textureBase.count - 1)]
                let own = layer.animator.quads(textureSizes: sizes).map { quad in
                    var q = quad
                    q.texture += base
                    return q
                }
                quads.append(contentsOf: own)
                if layer.widescreen == .mirror {
                    for edge in [-Self.frameHalfWidth, Self.frameHalfWidth] {
                        quads.append(contentsOf: own.map { $0.mirrored(about: edge) })
                    }
                }
            }
        }
    }
}

extension SpriteQuad {
    /// The quad reflected about the vertical line `x = edge` (the texture flips with it).
    func mirrored(about edge: Float) -> SpriteQuad {
        var q = self
        let m = { (p: SIMD2<Float>) in SIMD2(2 * edge - p.x, p.y) }
        q.corners = (m(corners.0), m(corners.1), m(corners.2), m(corners.3))
        return q
    }
}

extension SpriteAnimator {
    /// `FUN_0025de40`: bounding box `(x, y, w, h)` of the current frame's corners, integer pixels,
    /// relative to the instance origin.
    public func bounds() -> SIMD4<Int> {
        guard bank.keys.indices.contains(key) else { return .zero }
        let current = bank.keys[key]
        let pieces = bank.pieces(of: current.frame)
        var lo = SIMD2<Float>(repeating: .infinity), hi = SIMD2<Float>(repeating: -.infinity)
        for piece in pieces {
            for c in Self.corners(piece, scale: current.scale * scale, translation: current.translation * scale,
                                  rotation: Int(current.rotation) + rotation, mirror: mirror) {
                lo = simd_min(lo, c)
                hi = simd_max(hi, c)
            }
        }
        guard !pieces.isEmpty else { return .zero }
        return SIMD4(Int(lo.x), Int(lo.y), Int(hi.x - lo.x), Int(hi.y - lo.y))
    }
}
