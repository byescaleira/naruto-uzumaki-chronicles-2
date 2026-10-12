import SwiftUI
import UCEngine
import UCFormats

/// The Metal surface always fills the screen. The intro movie covers it while it plays; the
/// title screen is drawn by the surface itself (the renderer's sprite pass).
struct RootView: View {
    let session: GameSession
    let library: GameLibrary

    var body: some View {
        Group {
            switch library.state {
            case .loading:
                ProgressView("Loading…")
                    .padding(32)
                    .glassEffect(.regular, in: .rect(cornerRadius: 28))
            case .failed(let problem):
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                    .padding(32)
                    .glassEffect(.regular, in: .rect(cornerRadius: 28))
            case .ready:
                Color.clear
            }
        }
        .padding(24)
        // Overlays live inside the screen; they never size the surface behind them.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            GameSurface(runtime: session.runtime)
                .background(.black)
                .ignoresSafeArea()
        }
        .overlay {
            if case .intro(let player) = session.stage {
                MovieSurface(player: player)
                    .ignoresSafeArea()
            }
        }
        .task(id: library.isReady) {
            if case .ready(let data) = library.state {
                await session.start(with: data)
            }
        }
    }
}

/// Hosts the movie player's layer view (full-bleed, aspect fill: no borders).
#if os(macOS)
private struct MovieSurface: NSViewRepresentable {
    let player: MoviePlayer
    func makeNSView(context: Context) -> MovieView { player.view }
    func updateNSView(_ view: MovieView, context: Context) {}
}
#else
private struct MovieSurface: UIViewRepresentable {
    let player: MoviePlayer
    func makeUIView(context: Context) -> MovieView { player.view }
    func updateUIView(_ view: MovieView, context: Context) {}
}
#endif
