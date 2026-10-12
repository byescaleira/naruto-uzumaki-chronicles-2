import AVFoundation
import QuartzCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Plays a movie converted by `uc-tool movie convert` (the intro, `MV/MV00.mp4`) full-bleed,
/// skippable, and reports how it ended.
///
/// The movie is 4:3: 512×448 shown full screen on a 4:3 TV, stored as is with a 7:6 pixel
/// aspect that AVFoundation applies (it presents 597⅓×448). On the 16:9 and wider screens of every target, `.fill` (the default) scales it to
/// cover the screen and crops the top and bottom, with no borders and no stretching; `.fit`
/// shows the whole frame with black pillarbox bars. See ``cropFraction(content:screen:)``.
///
/// ```swift
/// let movie = MoviePlayer(url: dataURL.appending(path: "MV/MV00.mp4"))
/// container.addSubview(movie.view)            // sized to the full screen, safe area ignored
/// let outcome = await movie.play()            // .finished, .skipped or .failed
/// movie.view.removeFromSuperview()
/// ```
@MainActor
public final class MoviePlayer {
    public enum Scaling: Sendable {
        /// Cover the screen, cropping what overflows (no borders).
        case fill
        /// Show the whole frame, with black bars where the aspect ratios differ.
        case fit
    }

    public enum Outcome: Sendable, Equatable {
        case finished
        case skipped
        case failed(String)
    }

    public let view: MovieView
    private let player: AVPlayer
    private let item: AVPlayerItem
    private var completion: (@MainActor (Outcome) -> Void)?
    private var observers: [any NSObjectProtocol] = []
    private var statusObservation: NSKeyValueObservation?

    /// - Parameter skippable: a tap or click on the view (Select on the Siri Remote) skips;
    ///   game controller buttons are left to the caller, which calls ``skip()``.
    public init(url: URL, scaling: Scaling = .fill, skippable: Bool = true) {
        item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        player.allowsExternalPlayback = false
        view = MovieView(player: player, scaling: scaling)
        if skippable { view.onSkip = { [weak self] in self?.skip() } }
    }

    /// Starts playback; `completion` runs once, on the main actor.
    public func play(completion: @escaping @MainActor (Outcome) -> Void) {
        guard self.completion == nil else { return }
        self.completion = completion
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(.finished) }
        })
        observers.append(center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(.failed(self?.item.error?.localizedDescription ?? "playback failed")) }
        })
        // A missing or unreadable file never starts; the item's status says so (on any thread).
        statusObservation = item.observe(\.status) { [weak self] _, _ in
            guard let self else { return }
            Task { @MainActor in self.statusChanged() }
        }
        player.play()
    }

    /// Plays to the end, or until skipped.
    public func play() async -> Outcome {
        await withCheckedContinuation { continuation in
            play { continuation.resume(returning: $0) }
        }
    }

    /// Stops the movie and completes with `.skipped`.
    public func skip() {
        finish(.skipped)
    }

    private func statusChanged() {
        if item.status == .failed {
            finish(.failed(item.error?.localizedDescription ?? "cannot open movie"))
        }
    }

    private func finish(_ outcome: Outcome) {
        guard let completion else { return }
        self.completion = nil
        player.pause()
        statusObservation = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        completion(outcome)
    }

    /// Fraction of the movie's area left out when it covers a screen of a different aspect
    /// ratio with `.fill` (0 when they match). For the 4:3 movie: 25 % on 16:9 (12.5 % at the
    /// top and bottom each), 38.5 % on an iPhone's 19.5:9, 16.7 % on a Mac's 16:10. With
    /// `.fit` the same fraction of the screen is black bars instead.
    public nonisolated static func cropFraction(content: CGSize, screen: CGSize) -> Double {
        guard content.width > 0, content.height > 0, screen.width > 0, screen.height > 0 else { return 0 }
        let contentAspect = content.width / content.height
        let screenAspect = screen.width / screen.height
        return 1 - Double(min(contentAspect, screenAspect) / max(contentAspect, screenAspect))
    }
}

/// A view backed by an `AVPlayerLayer`, black behind the video.
@MainActor
public final class MovieView: PlatformView {
    var onSkip: (() -> Void)?

    #if os(macOS)
    private let playerLayer = AVPlayerLayer()

    override public func makeBackingLayer() -> CALayer { playerLayer }
    #else
    override public class var layerClass: AnyClass { AVPlayerLayer.self }
    // Created by UIKit from `layerClass`.
    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    #endif

    init(player: AVPlayer, scaling: MoviePlayer.Scaling) {
        super.init(frame: .zero)
        #if os(macOS)
        wantsLayer = true
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(skipGesture)))
        #else
        backgroundColor = .black
        let tap = UITapGestureRecognizer(target: self, action: #selector(skipGesture))
        #if os(tvOS)
        tap.allowedPressTypes = [NSNumber(value: UIPress.PressType.select.rawValue),
                                 NSNumber(value: UIPress.PressType.playPause.rawValue)]
        #endif
        addGestureRecognizer(tap)
        #endif
        playerLayer.player = player
        playerLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        playerLayer.videoGravity = scaling == .fill ? .resizeAspectFill : .resizeAspect
        #if os(macOS)
        autoresizingMask = [.width, .height]
        #else
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func skipGesture() { onSkip?() }
}
