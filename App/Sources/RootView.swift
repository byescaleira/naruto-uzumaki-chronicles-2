import SwiftUI
import UCEngine
import UCFormats

/// The Metal surface always fills the screen; status floats above it in Liquid Glass.
struct RootView: View {
    let runtime: GameRuntime
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
            case .ready(let data):
                GameDataPanel(data: data)
            }
        }
        .padding(24)
        // The panel lives inside the screen; it never sizes the surface behind it.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            GameSurface(runtime: runtime)
                .background(.black)
                .ignoresSafeArea()
        }
    }
}

/// The embedded data loaded: show art decoded from it on this device.
private struct GameDataPanel: View {
    let data: GameData
    @State private var faces: CGImage?

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            if let faces {
                Image(decorative: faces, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 240, maxHeight: 240)
                    .accessibilityLabel("Character portraits decoded from the game data")
            }
            VStack(alignment: .leading, spacing: 14) {
                Label("Game data loaded", systemImage: "checkmark.seal.fill")
                    .font(.title2.bold())
                    .foregroundStyle(.green)
                Text("SLES-55090 · CFC_\(data.language).DIG · \(data.archive.entries.filter { !$0.isEmpty }.count) entries")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                Text("These portraits were decoded on this device from the game data embedded in the app. The game itself is still being rebuilt from the original code, so there's nothing to play yet.")
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 420, alignment: .leading)
        }
        .padding(28)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .task(id: data.language) {
            let data = data
            faces = await Task.detached(priority: .userInitiated) {
                (try? data.characterFaces()).flatMap(\.cgImage)
            }.value
        }
    }
}

extension DecodedTexture {
    /// Straight-alpha RGBA8 in sRGB.
    var cgImage: CGImage? {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }
}
