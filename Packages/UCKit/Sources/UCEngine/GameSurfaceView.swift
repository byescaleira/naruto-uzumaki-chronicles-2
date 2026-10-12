import QuartzCore
import UCRender
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
        do {
            renderer = try RendererFactory.make(for: metalLayer)
        } catch {
            assertionFailure("Renderer unavailable: \(error)")
        }
    }

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
    #else
    override public func layoutSubviews() {
        super.layoutSubviews()
        metalLayer.frame = bounds
        updateDrawableSize()
    }

    override public func didMoveToWindow() {
        super.didMoveToWindow()
        window == nil ? stop() : start()
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

    private var hdrOutput: HDROutput {
        #if os(macOS)
        let headroom = window?.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1
        return HDROutput(mode: HDRLayer.outputMode, headroom: Float(headroom))
        #elseif os(tvOS)
        return HDROutput(mode: HDRLayer.outputMode)
        #else
        let headroom = window?.screen.currentEDRHeadroom ?? 1
        return HDROutput(mode: HDRLayer.outputMode, headroom: Float(headroom))
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
        runtime.advance(to: update.targetPresentationTimestamp)
        renderer?.render(runtime.frame(output: hdrOutput), to: update.drawable)
    }
}

extension GameSurfaceView: CAMetalDisplayLinkDelegate {
    nonisolated public func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        // The link is scheduled on the main run loop, so the update never leaves the main thread.
        nonisolated(unsafe) let update = update
        MainActor.assumeIsolated { draw(update) }
    }
}
