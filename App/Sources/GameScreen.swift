import SwiftUI
import UCEngine

/// Hosts the Metal surface edge to edge: no safe-area insets, no letterboxing.
struct GameScreen: View {
    let runtime: GameRuntime

    var body: some View {
        GameSurface(runtime: runtime)
            .background(.black)
            .overlay(alignment: .bottomLeading) {
                if runtime.data == nil {
                    Text("Game data not found — set NUC2_DATA to the mounted disc")
                        .font(.caption.monospaced())
                        .foregroundStyle(.white.opacity(0.7))
                        .padding()
                }
            }
    }
}

#if os(macOS)
private struct GameSurface: NSViewRepresentable {
    let runtime: GameRuntime
    func makeNSView(context: Context) -> GameSurfaceView { GameSurfaceView(runtime: runtime) }
    func updateNSView(_ view: GameSurfaceView, context: Context) {}
}
#else
private struct GameSurface: UIViewControllerRepresentable {
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
        #if os(tvOS)
        if let window = view.window { DisplayMode.request4KHDR60(for: window) }
        #endif
    }

    #if os(iOS)
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var prefersInterfaceOrientationLocked: Bool { true }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    #endif
}
#endif
