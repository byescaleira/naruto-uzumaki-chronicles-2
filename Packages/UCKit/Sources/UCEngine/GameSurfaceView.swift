import QuartzCore
import UCRender
#if DEBUG
import os
#endif
#if os(tvOS)
import AVFoundation
#endif
#if os(macOS)
import AppKit
public typealias PlatformView = NSView
#else
import UIKit
public typealias PlatformView = UIView
#endif

/// Full-bleed Metal surface paced by `CAMetalDisplayLink` at 60 Hz.
@MainActor
public final class GameSurfaceView: PlatformView {
    public static let frameRate = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)

    private let metalLayer = CAMetalLayer()
    private var renderer: (any Renderer)?
    /// The output the layer, pipelines and shader were configured for; they always change together.
    private var outputMode = HDRLayer.outputMode
    private var displayLink: CAMetalDisplayLink?
    private let runtime: GameRuntime

    public init(runtime: GameRuntime) {
        self.runtime = runtime
        super.init(frame: .zero)
        #if os(macOS)
        wantsLayer = true
        layer = metalLayer
        #else
        metalLayer.frame = bounds
        layer.addSublayer(metalLayer)
        #endif
        makeRenderer()
        installPointerControls()
        #if os(tvOS)
        // The TV (or its HDR setting) can change while the app runs.
        NotificationCenter.default.addObserver(
            self, selector: #selector(hdrEligibilityChanged),
            name: AVPlayer.eligibleForHDRPlaybackDidChangeNotification, object: nil
        )
        #endif
    }

    /// Touch (iPhone/iPad) and clicks (Mac) for screens without a controller: a tap is
    /// Cross/Start, a vertical swipe moves the menu selection. tvOS uses the Siri Remote
    /// through GameController instead.
    private func installPointerControls() {
        #if os(iOS)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        for direction in [UISwipeGestureRecognizer.Direction.up, .down] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            swipe.direction = direction
            addGestureRecognizer(swipe)
        }
        #elseif os(macOS)
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(tapped(_:))))
        #endif
    }

    #if os(iOS)
    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        runtime.tap(at: SIMD2(Float(point.x), Float(point.y)), in: SIMD2(Float(bounds.width), Float(bounds.height)))
    }
    #elseif os(macOS)
    @objc private func tapped(_ gesture: NSClickGestureRecognizer) {
        // AppKit views are y-up; the canvas is y-down.
        let point = gesture.location(in: self)
        runtime.tap(at: SIMD2(Float(point.x), Float(bounds.height - point.y)), in: SIMD2(Float(bounds.width), Float(bounds.height)))
    }
    #endif

    #if os(iOS)
    @objc private func swiped(_ gesture: UISwipeGestureRecognizer) {
        runtime.press(stick: SIMD2(0, gesture.direction == .up ? 1 : -1))
    }
    #endif

    private func makeRenderer() {
        outputMode = HDRLayer.outputMode
        do {
            renderer = try RendererFactory.make(for: metalLayer, mode: outputMode)
        } catch {
            assertionFailure("Renderer unavailable: \(error)")
        }
        #if os(tvOS)
        if let window { DisplayMode.request(for: window, output: outputMode) }
        #endif
    }

    #if os(tvOS)
    /// Posted on an arbitrary thread; the renderer is rebuilt on the main actor.
    @objc nonisolated private func hdrEligibilityChanged() {
        Task { @MainActor in
            guard HDRLayer.outputMode != self.outputMode else { return }
            self.makeRenderer()
        }
    }
    #endif

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Layout

    #if os(macOS)
    override public func layout() {
        super.layout()
        updateDrawableSize()
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window == nil ? stop() : start()
    }

    /// Moving the window to a display with another scale must resize the drawable, or the
    /// image is resampled (blurry) by the compositor.
    override public func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }
    #else
    override public func layoutSubviews() {
        super.layoutSubviews()
        metalLayer.frame = bounds
        updateDrawableSize()
    }

    override public func didMoveToWindow() {
        super.didMoveToWindow()
        window == nil ? stop() : start()
        #if os(tvOS)
        if let window { DisplayMode.request(for: window, output: outputMode) }
        #endif
    }
    #endif

    private var backingScale: CGFloat {
        #if os(macOS)
        window?.backingScaleFactor ?? 2
        #else
        // Native pixels (e.g. 3840×2160 on Apple TV 4K, full panel resolution on iPhone).
        window?.screen.nativeScale ?? 2
        #endif
    }

    private func updateDrawableSize() {
        let scale = backingScale
        metalLayer.contentsScale = scale
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        if size.width > 0, size.height > 0, metalLayer.drawableSize != size {
            metalLayer.drawableSize = size
        }
    }

    /// Read every frame: the headroom available *now* (it drops with screen brightness, Low
    /// Power Mode or other EDR content), not the potential maximum, so highlights are never
    /// rendered brighter than the display will show and then clipped by the compositor.
    private var hdrOutput: HDROutput {
        #if os(macOS)
        let headroom = window?.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1
        return HDROutput(mode: outputMode, headroom: Float(headroom))
        #elseif os(tvOS)
        return HDROutput(mode: outputMode)
        #else
        let headroom = window?.screen.currentEDRHeadroom ?? 1
        return HDROutput(mode: outputMode, headroom: Float(headroom))
        #endif
    }

    // MARK: Frame pacing

    private func start() {
        guard displayLink == nil else { return }
        let link = CAMetalDisplayLink(metalLayer: metalLayer)
        link.preferredFrameRateRange = Self.frameRate
        link.preferredFrameLatency = 2
        link.delegate = self
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    fileprivate func draw(_ update: CAMetalDisplayLink.Update) {
        #if DEBUG
        let started = CACurrentMediaTime()
        #endif
        runtime.advance(to: update.targetPresentationTimestamp)
        renderer?.render(runtime.frame(output: hdrOutput), to: update.drawable)
        #if DEBUG
        stats.record(time: update.targetPresentationTimestamp, tick: runtime.tick, pacer: runtime.pacer,
                     output: hdrOutput, frameCPU: CACurrentMediaTime() - started, frameGPU: renderer?.lastGPUTime ?? 0)
        #endif
    }

    #if DEBUG
    private var stats = PacingStats()
    #endif
}

extension GameSurfaceView: CAMetalDisplayLinkDelegate {
    nonisolated public func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        // The link is scheduled on the main run loop, so the update never leaves the main thread.
        nonisolated(unsafe) let update = update
        MainActor.assumeIsolated { draw(update) }
    }
}

#if DEBUG
/// Logs real pacing every two seconds (Console / `log stream --predicate 'subsystem == "com.byescaleira.nuc2"'`).
private struct PacingStats {
    private static let logger = Logger(subsystem: "com.byescaleira.nuc2", category: "pacing")
    private var windowStart: Double?
    private var startTick: UInt64 = 0
    private var frames = 0
    private var cpu = 0.0
    private var gpu = 0.0

    mutating func record(time: Double, tick: UInt64, pacer: FramePacer, output: HDROutput, frameCPU: Double, frameGPU: Double) {
        guard let start = windowStart else {
            windowStart = time
            startTick = tick
            return
        }
        frames += 1
        cpu += frameCPU
        gpu += frameGPU
        let elapsed = time - start
        guard elapsed >= 2 else { return }
        let fps = Double(frames) / elapsed
        let tps = Double(tick - startTick) / elapsed
        let refresh = String(format: "%.2f", pacer.refreshRate)
        let message = String(format: "display %.2f fps, game %.2f ticks/s, frame CPU %.2f ms, GPU %.2f ms", fps, tps, cpu / Double(frames) * 1000, gpu / Double(frames) * 1000)
        Self.logger.info("\(message, privacy: .public), refresh \(refresh, privacy: .public) Hz, vsync lock \(pacer.isVsyncLocked), output \(output.mode.rawValue) headroom \(output.headroom)")
        windowStart = time
        startTick = tick
        frames = 0
        cpu = 0
        gpu = 0
    }
}
#endif
