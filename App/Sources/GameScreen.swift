import SwiftUI
import UCEngine

#if os(macOS)
/// The Metal surface, edge to edge: no safe-area insets, no letterboxing.
struct GameSurface: NSViewRepresentable {
    let runtime: GameRuntime
    func makeNSView(context: Context) -> GameSurfaceView { GameSurfaceView(runtime: runtime) }
    func updateNSView(_ view: GameSurfaceView, context: Context) {}
}
#else
/// The Metal surface, edge to edge: no safe-area insets, no letterboxing.
struct GameSurface: UIViewControllerRepresentable {
    let runtime: GameRuntime
    func makeUIViewController(context: Context) -> GameViewController { GameViewController(runtime: runtime) }
    func updateUIViewController(_ controller: GameViewController, context: Context) {}
}

/// Owns the surface so it can lock orientation, hide the home indicator and defer
/// system edge gestures (so they don't fire during play).
final class GameViewController: UIViewController {
    private let runtime: GameRuntime

    init(runtime: GameRuntime) {
        self.runtime = runtime
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        view = GameSurfaceView(runtime: runtime)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        #if os(iOS)
        keepSceneFullScreen()
        #endif
    }

    #if os(iOS)
    /// iPadOS 26 windowing can resize the scene; asking for the full screen size as the minimum
    /// keeps the game edge to edge (UIRequiresFullScreen, the old way, is deprecated).
    private func keepSceneFullScreen() {
        guard traitCollection.userInterfaceIdiom == .pad, let scene = view.window?.windowScene else { return }
        let bounds = scene.screen.bounds
        scene.sizeRestrictions?.minimumSize = CGSize(
            width: max(bounds.width, bounds.height),
            height: min(bounds.width, bounds.height)
        )
    }
    #endif

    #if os(iOS)
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var prefersInterfaceOrientationLocked: Bool { true }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    #endif
}
#endif
