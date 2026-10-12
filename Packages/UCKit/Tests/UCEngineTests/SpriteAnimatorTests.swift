import simd
import Testing
@testable import UCEngine
@testable import UCFormats
import UCRender

private typealias Piece = SpriteBank.Piece
private typealias Key = SpriteBank.Key

private func piece(at p: SIMD2<Int16> = SIMD2(-4, -2), size: SIMD2<Int16> = SIMD2(8, 6), flip: UInt8 = 0,
                   flags: UInt8 = 0, pivot: SIMD2<Int16> = .zero, blend: UInt8 = 0) -> Piece {
    Piece(texture: 0, position: p, uv: SIMD4(16, 32, 8, 4), size: size, transformFlags: flags, alpha: 0x80,
          pivot: pivot, rotation: 0, blend: blend, flip: flip)
}

private func key(frame: Int = 0, duration: UInt16, next: Int, translation: SIMD2<Float> = .zero,
                 rotation: Int16 = 0, alpha: UInt8 = 0x80, event: UInt16 = 0) -> Key {
    Key(frame: frame, duration: duration, durationMax: 0, event: event, scale: SIMD2(1, 1), translation: translation,
        rotation: rotation, nextAnimation: 0, nextKey: next, alpha: alpha)
}

/// A bank with one animation of the given keys over frames of one piece each.
private func bank(keys: [Key], pieces: [Piece] = [piece()], morph: Bool = false) -> SpriteBank {
    SpriteBank(frames: pieces.indices.map { SpriteBank.Frame(firstPiece: $0, pieceCount: 1, bounds: .zero) },
               animations: [SpriteBank.Animation(firstKey: 0, keyCount: keys.count, flags: morph ? 1 : 0)],
               keys: keys, pieces: pieces)
}

private func corners(_ q: SpriteQuad) -> [SIMD2<Float>] { [q.corners.0, q.corners.1, q.corners.2, q.corners.3] }

private func close(_ a: [SIMD2<Float>], _ b: [SIMD2<Float>]) -> Bool {
    zip(a, b).allSatisfy { simd_length($0 - $1) < 1e-3 }
}

@Suite("Sprite animator")
struct SpriteAnimatorTests {
    @Test("Keys last their duration, then step and loop; the event of the left key is returned")
    func stepping() {
        var a = SpriteAnimator(bank: bank(keys: [key(duration: 3, next: 1), key(duration: 2, next: 0, event: 1)]), animation: 0)
        #expect(a.key == 0 && a.remaining == 3)
        #expect(a.tick() == 0 && a.tick() == 0)
        #expect(a.tick() == 0 && a.key == 1 && a.remaining == 2)
        a.tick()
        #expect(a.tick() == 1 && a.key == 0 && a.remaining == 3)
    }

    @Test("Transforms interpolate linearly towards the next key")
    func interpolation() {
        var a = SpriteAnimator(bank: bank(keys: [key(duration: 4, next: 1), key(duration: 4, next: 0, translation: SIMD2(100, 40), alpha: 0)]), animation: 0)
        let sizes = [SIMD2(64, 64)]
        #expect(close(corners(a.quads(textureSizes: sizes)[0]), [SIMD2(-4, -2), SIMD2(4, -2), SIMD2(4, 4), SIMD2(-4, 4)]))
        a.tick(); a.tick()
        let half = a.quads(textureSizes: sizes)[0]
        #expect(close(corners(half), [SIMD2(46, 18), SIMD2(54, 18), SIMD2(54, 24), SIMD2(46, 24)]))
        // A = piece · instance · key >> 14: 0x80 · 0x80 · 0x40 >> 14 = 0x40.
        #expect(half.color.w == 0.5)
    }

    @Test("Rotation turns around the instance origin (4096 = one turn)")
    func rotation() {
        let a = SpriteAnimator(bank: bank(keys: [key(duration: 1, next: 0, rotation: 1024)]), animation: 0)
        // A quarter turn maps (x, y) → (−y, x).
        #expect(close(corners(a.quads(textureSizes: [SIMD2(64, 64)])[0]), [SIMD2(2, -4), SIMD2(2, 4), SIMD2(-4, 4), SIMD2(-4, -4)]))
    }

    @Test("Pivot pieces scale and rotate around the pivot")
    func pivot() {
        var k = key(duration: 1, next: 0, rotation: 2048)
        k.scale = SIMD2(2, 2)
        let a = SpriteAnimator(bank: bank(keys: [k], pieces: [piece(at: SIMD2(0, 0), size: SIMD2(2, 2), flags: 4, pivot: SIMD2(1, 1))]), animation: 0)
        // Corners around the pivot (1, 1), doubled and half-turned; the pivot itself unscaled
        // (flag 4) but rotated: (1, 1) → (−1, −1).
        #expect(close(corners(a.quads(textureSizes: [SIMD2(64, 64)])[0]), [SIMD2(1, 1), SIMD2(-3, 1), SIMD2(-3, -3), SIMD2(1, -3)]))
    }

    @Test("Texture coordinates sit half a texel in; flips mirror geometry and shift the start")
    func textureCoordinates() {
        let sizes = [SIMD2(64, 32)]
        let plain = SpriteAnimator(bank: bank(keys: [key(duration: 1, next: 0)]), animation: 0).quads(textureSizes: sizes)[0]
        #expect(plain.uv == SIMD4(16.5 / 64, 32.5 / 32, 24.5 / 64, 36.5 / 32))
        #expect(plain.clamp == SIMD4(16.5 / 64, 32.5 / 32, 23.5 / 64, 35.5 / 32))
        let flipped = SpriteAnimator(bank: bank(keys: [key(duration: 1, next: 0)], pieces: [piece(flip: 1, blend: 1)]), animation: 0)
            .quads(textureSizes: sizes)[0]
        #expect(flipped.uv.x == 15.5 / 64 && flipped.blend == .add)
        #expect(close(corners(flipped), [SIMD2(4, -2), SIMD2(-4, -2), SIMD2(-4, 4), SIMD2(4, 4)]))
    }

    @Test("Morph animations blend the corners of consecutive frames")
    func morph() {
        let b = bank(keys: [key(frame: 0, duration: 2, next: 1), key(frame: 1, duration: 2, next: 0)],
                     pieces: [piece(at: SIMD2(0, 0)), piece(at: SIMD2(10, 0))], morph: true)
        var a = SpriteAnimator(bank: b, animation: 0)
        a.tick()
        #expect(corners(a.quads(textureSizes: [SIMD2(64, 64)])[0])[0] == SIMD2(5, 0))
    }
}

@Suite("Sprite objects and screens")
struct SpriteObjectTests {
    @Test("Layers draw by priority, skip hidden ones and add position offsets")
    func layers() {
        let b = bank(keys: [key(duration: 1, next: 0)])
        var object = SpriteObject()
        object.add(id: 0, animation: 0, bank: b)
        object.add(id: 1, animation: 0, bank: b)
        object.setPosition(layer: 1, SIMD2(100, 0))
        object.setPriority(layer: 0, 1)
        var quads: [SpriteQuad] = []
        object.draw(textureSizes: [[SIMD2(64, 64)]], into: &quads)
        #expect(quads.map(\.corners.0.x) == [96, -4])
        object.insert(.hidden, layer: 1)
        quads = []
        object.draw(textureSizes: [[SIMD2(64, 64)]], into: &quads)
        #expect(quads.count == 1)
    }

    @Test("Mirror fill adds copies reflected about the 4:3 edges")
    func widescreen() {
        var object = SpriteObject()
        object.add(id: 0, animation: 0, bank: bank(keys: [key(duration: 1, next: 0)]))
        object.setWidescreen(layer: 0, .mirror)
        var quads: [SpriteQuad] = []
        object.draw(textureSizes: [[SIMD2(64, 64)]], into: &quads)
        #expect(quads.map(\.corners.0.x) == [-4, -508, 516])
    }

    @Test("The canvas fills the height and widens with the screen, never stretching")
    func canvas() {
        let canvas = SpriteCanvas()
        #expect(simd_length(canvas.visibleHalfExtent(width: 1600, height: 1200) - SIMD2(256, 224)) < 1e-3)
        let wide = canvas.visibleHalfExtent(width: 1920, height: 1080)
        #expect(abs(wide.x - 224 * (16.0 / 9.0) * 6 / 7) < 1e-3 && wide.y == 224)
        let narrow = canvas.visibleHalfExtent(width: 1000, height: 1000)
        #expect(narrow.x == 256 && narrow.y > 224)
        let t = canvas.transform(width: 1600, height: 1200)
        #expect(simd_length(t.scale - SIMD2(1 / 256, -1 / 224)) < 1e-6)
    }
}

