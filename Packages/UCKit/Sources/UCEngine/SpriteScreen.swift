import Foundation
import simd
import UCFormats
import UCRender

/// The textures of one or more sprite files, decoded (or swapped for their high-resolution
/// copies) and packed into an atlas once. Build it off the main actor; screens share it.
public final class SpriteSheet: Sendable {
    public let files: [SpriteFile]
    /// Every texture of every file.
    public let atlas: SpriteAtlas
    /// Per file: the `TEX0` size of each texture (texel coordinates are normalised by it), and
    /// its first layer in ``atlas``.
    public let textureSizes: [[SIMD2<Int>]]
    public let textureBase: [UInt32]

    public init(files: [SpriteFile]) {
        self.files = files
        var textures: [(width: Int, height: Int, rgba: [UInt8])] = []
        var sizes: [[SIMD2<Int>]] = []
        var bases: [UInt32] = []
        var upscaled = false
        var detail: [Float] = []
        for file in files {
            bases.append(UInt32(textures.count))
            var fileSizes: [SIMD2<Int>] = []
            // Decoding replays the whole texture upload; skip it when every texture is replaced.
            let decoded = file.highResolution.count == file.textures.textures.count
                ? [] : file.textures.decode()
            for (n, texture) in file.textures.textures.enumerated() {
                if let hd = file.highResolution[n] {
                    // Same normalised coordinates: the copy is `scale` times the decoded size.
                    fileSizes.append(SIMD2(hd.width / HighResolution.scale, hd.height / HighResolution.scale))
                    textures.append((hd.width, hd.height, hd.rgba))
                    detail.append(Float(HighResolution.scale))
                    upscaled = true
                } else if decoded.indices.contains(n), let image = decoded[n] {
                    fileSizes.append(SIMD2(image.width, image.height))
                    textures.append((image.width, image.height, image.rgba))
                    detail.append(1)
                } else {
                    // Unsupported format: keep the slot so indices stay aligned.
                    let w = texture.tex0.width, h = texture.tex0.height
                    fileSizes.append(SIMD2(w, h))
                    textures.append((w, h, [UInt8](repeating: 0, count: w * h * 4)))
                    detail.append(1)
                }
            }
            sizes.append(fileSizes)
        }
        atlas = SpriteAtlas(textures: textures, mipmapped: upscaled, detail: detail)
        textureSizes = sizes
        textureBase = bases
    }
}

/// A 2D screen: sprite objects drawn from one or more sprite files, advanced once per game
/// frame and turned into a renderer-agnostic ``SpriteFrame``.
public struct SpriteScreen: Sendable {
    public let sheet: SpriteSheet
    public var objects: [SpriteObject] = []
    public var clearColor: SIMD3<Float> = .zero
    /// Screen fade (`FUN_001c4610` / `FUN_001c4650`): 1 = fully shown, 0 = black.
    public var brightness: Float = 1
    public private(set) var frameCount = 0

    public init(sheet: SpriteSheet) {
        self.sheet = sheet
    }

    public init(files: [SpriteFile]) {
        self.init(sheet: SpriteSheet(files: files))
    }

    public var files: [SpriteFile] { sheet.files }
    public var atlas: SpriteAtlas { sheet.atlas }
    public var textureSizes: [[SIMD2<Int>]] { sheet.textureSizes }
    public var textureBase: [UInt32] { sheet.textureBase }

    /// One game frame.
    public mutating func tick() {
        for i in objects.indices { objects[i].tick() }
        frameCount += 1
    }

    public mutating func tick(frames: Int) {
        for _ in 0 ..< max(0, frames) { tick() }
    }

    /// Objects in creation order, each in its own layer order (`FUN_00265180`).
    public var quads: [SpriteQuad] {
        var quads: [SpriteQuad] = []
        for object in objects { object.draw(textureSizes: textureSizes, into: &quads, textureBase: textureBase) }
        return quads
    }

    public func frame(canvas: SpriteCanvas = SpriteCanvas()) -> SpriteFrame {
        var quads = quads
        if brightness < 1 {
            let level = max(0, brightness)
            for i in quads.indices { quads[i].color *= SIMD4(level, level, level, 1) }
        }
        return SpriteFrame(atlas: atlas, quads: quads, canvas: canvas, clearColor: clearColor * max(0, brightness))
    }
}

/// The title screen / main menu (BEGIN! · CONTINUE! · OPTIONS), as the title module builds it.
///
/// Recovered from `SLES_550.90`:
/// - `FUN_002d4120(n)` reads the module's resource handles at `DAT_004da940`
///   (`entry << 16 | sub-file`); handle 1 = `0x00280000`, DIG entry 40 sub-file 0.
/// - `FUN_001a9350` starts the background task `FUN_001a8c30`; in its main-menu mode it adds
///   21 layers playing animations 0–9, 0xC–0x14, 0xA and 0x15 of that file (the blue backdrop,
///   the kanji and fire, the characters, the logo and the copyright).
/// - `FUN_001aac40` creates the three menu items (`FUN_001aa070(i, 0, 0)`, names "NEW GAME",
///   "LOAD GAME", "OPTION" at `0x3523b0`); `FUN_001a9b90` gives each a highlight layer
///   (animation 0x16 anchored on 0x17, moved down 40 px per item, hidden unless selected) and a
///   label layer (animations 0x18–0x1A, held on their dim first key unless selected).
public enum TitleScreen {
    public static let entry = 40
    public static let subfile = 0

    public static let backgroundAnimations = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0xC, 0xD, 0xE, 0xF, 0x10, 0x11, 0x12, 0x13, 0x14, 0xA, 0x15]
    public static let itemLabels = [0x18, 0x19, 0x1A]
    public static let itemSpacing = 0x28
    /// "PRESS START BUTTON" (`FUN_001aa3e0` plays animation 0x1B of the same file).
    public static let pressStart = 0x1B
    /// bg093: `FUN_001aaed0` calls `FUN_00129c60(0, 0x5d, 1, 0, 0)` (channel 0 = music).
    public static let music = 0x5D
    /// Announcer lines (voice indices) from the table at `0x352490`, picked at random by
    /// `FUN_001aae30`.
    public static let announcerVoices = [0x709, 0x731, 0x732, 0x733, 0x734, 0x735, 0x736, 0x737, 0x738, 0x739, 0x73A, 0x73B]

    public enum Phase: Sendable, Equatable {
        /// The backdrop with the blinking "PRESS START BUTTON".
        case pressStart
        /// BEGIN! · CONTINUE! · OPTIONS with one item selected.
        case menu(selection: Int)
    }

    public static func make(_ file: SpriteFile, phase: Phase = .menu(selection: 0)) -> SpriteScreen {
        make(SpriteSheet(files: [file]), phase: phase)
    }

    public static func make(_ sheet: SpriteSheet, phase: Phase = .menu(selection: 0)) -> SpriteScreen {
        let file = sheet.files[0]
        var screen = SpriteScreen(sheet: sheet)
        var background = SpriteObject()
        for (id, animation) in backgroundAnimations.enumerated() {
            background.add(id: id, animation: animation, bank: file.bank)
        }
        // Layer 0 is the full-frame backdrop (blue noise, additive fire, subtractive shade).
        background.setWidescreen(layer: 0, .mirror)
        screen.objects.append(background)
        switch phase {
        case .pressStart:
            var prompt = SpriteObject()
            prompt.add(id: 0, animation: pressStart, bank: file.bank)
            screen.objects.append(prompt)
        case .menu(let selection):
            for (index, label) in itemLabels.enumerated() {
                var item = SpriteObject()
                item.add(id: 0, animation: 0x16, anchorAnimation: 0x17, bank: file.bank)
                item.add(id: 1, animation: label, bank: file.bank)
                item.setPosition(layer: 0, SIMD2(0, index * itemSpacing))
                setSelected(&item, index == selection)
                screen.objects.append(item)
            }
        }
        return screen
    }

    /// Selected: highlight bar shown, label playing its grow-in (0.7 → 1.0, alpha 0x32 → 0x80);
    /// otherwise the bar is hidden and the label held on its dim first key (flags 0x20 / 0xC
    /// as `FUN_001a9b90` sets them).
    static func setSelected(_ item: inout SpriteObject, _ selected: Bool) {
        if selected {
            item.remove(.hidden, layer: 0)
            item.remove([.hold, .paused], layer: 1)
            item.play(layer: 1, animation: item.layers[1].animator.animation, restart: true)
        } else {
            item.insert(.hidden, layer: 0)
            item.insert([.hold, .paused], layer: 1)
        }
    }
}

/// The title flow driven by the pad (`FUN_001aad00`, `FUN_001aaa90`): PRESS START → menu,
/// up / down to move the selection, Cross to confirm, Triangle back to PRESS START.
public struct TitleMenu: Sendable {
    public enum Item: Int, Sendable, CaseIterable {
        case newGame, loadGame, option
    }

    public private(set) var phase: TitleScreen.Phase
    public private(set) var screen: SpriteScreen
    private let sheet: SpriteSheet
    private var previous = InputState()

    /// `FUN_001aac40` opens the menu on LOAD GAME (`+8 = 1`).
    public static let initialSelection = 1

    public init(sheet: SpriteSheet, phase: TitleScreen.Phase = .pressStart) {
        self.sheet = sheet
        self.phase = phase
        screen = TitleScreen.make(sheet, phase: phase)
    }

    public init(file: SpriteFile, phase: TitleScreen.Phase = .pressStart) {
        self.init(sheet: SpriteSheet(files: [file]), phase: phase)
    }

    /// The item the player confirmed (Cross / Start, or a second tap on the selected item).
    /// The flow (``FrontEnd``) reads and clears it.
    public var confirmed: Item?

    /// One game frame with this frame's pad state.
    public mutating func tick(_ input: InputState) {
        defer { previous = input }
        let pressed = input.buttons.subtracting(previous.buttons)
        switch phase {
        case .pressStart:
            if !pressed.isDisjoint(with: [.start, .cross]) { openMenu() }
        case .menu(let selection):
            let down = input.leftStick.y < -0.5 && previous.leftStick.y >= -0.5
            let up = input.leftStick.y > 0.5 && previous.leftStick.y <= 0.5
            let count = TitleScreen.itemLabels.count
            if pressed.contains(.triangle) {
                closeMenu()
            } else if !pressed.isDisjoint(with: [.start, .cross]) {
                confirmed = Item(rawValue: selection)
            } else if up || down {
                select((selection + (down ? 1 : count - 1)) % count)
            }
        }
        screen.tick()
    }

    /// A tap or click at `point` in canvas coordinates (origin at the centre, y down, the
    /// 512×448 space): on PRESS START it opens the menu; on an item it selects it, and a tap on
    /// the item that is already selected confirms it.
    public mutating func tap(at point: SIMD2<Float>) {
        switch phase {
        case .pressStart:
            openMenu()
        case .menu(let selection):
            guard let index = itemFrames.firstIndex(where: { $0.contains(point) }) else { return }
            if index == selection {
                confirmed = Item(rawValue: index)
            } else {
                select(index)
            }
        }
    }

    /// Hit area of each menu item, `(minX, minY, maxX, maxY)` in canvas coordinates: the
    /// label as drawn, widened to the highlight bar's span and to half the item spacing
    /// vertically so neighbouring rows don't leave dead gaps.
    public var itemFrames: [SIMD4<Float>] {
        guard case .menu = phase else { return [] }
        let rows = (0 ..< TitleScreen.itemLabels.count).map { index in
            screen.objects[1 + index].drawnBounds(in: screen)
        }
        let half = Float(TitleScreen.itemSpacing) / 2
        let minX = rows.compactMap { $0?.x }.min() ?? 0, maxX = rows.compactMap { $0?.z }.max() ?? 0
        return rows.map { row in
            guard let row else { return SIMD4(0, 0, -1, -1) }
            let centre = (row.y + row.w) / 2
            return SIMD4(minX, centre - half, maxX, centre + half)
        }
    }

    private mutating func openMenu() {
        // The backdrop keeps running: only the overlay objects change.
        phase = .menu(selection: Self.initialSelection)
        rebuild()
    }

    private mutating func closeMenu() {
        phase = .pressStart
        rebuild()
    }

    private mutating func rebuild() {
        var next = TitleScreen.make(sheet, phase: phase)
        next.objects[0] = screen.objects[0]
        next.brightness = screen.brightness
        screen = next
    }

    private mutating func select(_ next: Int) {
        guard case .menu(let selection) = phase, next != selection else { return }
        TitleScreen.setSelected(&screen.objects[1 + selection], false)
        TitleScreen.setSelected(&screen.objects[1 + next], true)
        phase = .menu(selection: next)
    }

    /// Fade level of the whole screen (``FrontEnd`` drives it).
    public mutating func setBrightness(_ level: Float) { screen.brightness = level }
}

extension SIMD4 where Scalar == Float {
    /// For `(minX, minY, maxX, maxY)` rects.
    func contains(_ point: SIMD2<Float>) -> Bool {
        point.x >= x && point.x <= z && point.y >= y && point.y <= w
    }
}

extension SpriteObject {
    /// `(minX, minY, maxX, maxY)` of the quads the object draws now, or `nil` when it draws none.
    func drawnBounds(in screen: SpriteScreen) -> SIMD4<Float>? {
        var quads: [SpriteQuad] = []
        draw(textureSizes: screen.textureSizes, into: &quads, textureBase: screen.textureBase)
        var lower = SIMD2<Float>(repeating: .infinity), upper = SIMD2<Float>(repeating: -.infinity)
        for quad in quads where quad.color.w > 0 {
            for corner in [quad.corners.0, quad.corners.1, quad.corners.2, quad.corners.3] {
                lower = simd_min(lower, corner)
                upper = simd_max(upper, corner)
            }
        }
        return lower.x.isFinite ? SIMD4(lower.x, lower.y, upper.x, upper.y) : nil
    }
}

extension GameData {
    /// One sub-file of a DIG entry.
    public func subfile(entry index: Int, _ subfile: Int) throws -> [UInt8] {
        let entry = archive.entries[index]
        let data = try archive.read(entry)
        let table = DIGSubfileTable(data, count: Int(entry.subfileCount))
        guard let found = table.subfiles.first(where: { Int($0.index) == subfile }) else {
            throw SpriteFile.Failure.truncated("entry \(index) sub-file \(subfile)")
        }
        return Array(table.slice(found, of: data))
    }

    /// The title screen / main menu, decoded from the disc (``TitleScreen``).
    public func titleScreen(phase: TitleScreen.Phase = .menu(selection: 0)) throws -> SpriteScreen {
        TitleScreen.make(try titleSprites(), phase: phase)
    }

    /// The title / main-menu sprite file (DIG entry 40, sub-file 0).
    public func titleSprites() throws -> SpriteFile {
        try sprites(entry: TitleScreen.entry, TitleScreen.subfile)
    }

    /// A sprite file, with the package's high-resolution textures for it (``HighResolution``).
    public func sprites(entry: Int, _ subfile: Int) throws -> SpriteFile {
        var file = try SpriteFile(try self.subfile(entry: entry, subfile))
        for n in file.textures.textures.indices {
            let path = HighResolution.path(entry: entry, subfile: subfile, texture: n)
            if let url = disc.files[path.uppercased()]?.url, let texture = HighResolution.decode(url) {
                file.highResolution[n] = texture
            }
        }
        return file
    }
}
