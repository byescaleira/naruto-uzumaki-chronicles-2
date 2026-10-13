import simd

/// Mirrors `FrameUniforms` in App/Shaders/Frame.metal (32 bytes).
public struct FrameUniforms: Sendable {
    public var resolution: SIMD2<Float>
    public var time: Float
    public var sdrWhiteNits: Float
    public var headroom: Float
    public var outputMode: UInt32
    public var padding: SIMD2<Float> = .zero

    public init(resolution: SIMD2<Float>, time: Float, output: HDROutput) {
        self.resolution = resolution
        self.time = time
        sdrWhiteNits = output.sdrWhiteNits
        headroom = output.headroom
        outputMode = output.mode.rawValue
    }
}

/// What the presentation layer can show.
public struct HDROutput: Sendable, Equatable {
    public enum Mode: UInt32, Sendable {
        /// Extended linear Display P3 with EDR (iOS, iPadOS, macOS).
        case extendedLinearP3 = 0
        /// PQ BT.2100 / HDR10 signal (tvOS with an HDR TV).
        case pq = 1
        /// sRGB (tvOS with an SDR TV).
        case sdr = 2
    }

    public var mode: Mode
    /// Maximum linear value the display can show above SDR white (EDR only).
    public var headroom: Float
    /// Reference white for PQ output.
    public var sdrWhiteNits: Float

    public init(mode: Mode, headroom: Float = 1, sdrWhiteNits: Float = 203) {
        self.mode = mode
        self.headroom = headroom
        self.sdrWhiteNits = sdrWhiteNits
    }
}

/// The input the renderer needs for one frame.
public struct FrameInput: Sendable {
    public var time: Double
    public var output: HDROutput
    /// 3D layer (stages, characters), drawn first with its own depth buffer.
    public var scene: SceneFrame?
    /// 2D layer (menus, HUD), drawn over the 3D layer (or over a clear when there is none).
    public var sprites: SpriteFrame?

    public init(time: Double, output: HDROutput, scene: SceneFrame? = nil, sprites: SpriteFrame? = nil) {
        self.time = time
        self.output = output
        self.scene = scene
        self.sprites = sprites
    }
}
