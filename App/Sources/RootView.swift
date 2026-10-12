import SwiftUI
import UCEngine
import UCFormats
import UniformTypeIdentifiers

/// The Metal surface always fills the screen; the disc flow floats above it in Liquid Glass.
struct RootView: View {
    let runtime: GameRuntime
    let library: DiscLibrary

    var body: some View {
        Group {
            switch library.state {
            case .searching, .loading:
                ProgressView("Reading the disc…")
                    .padding(32)
                    .glassEffect(.regular, in: .rect(cornerRadius: 28))
            case .needsDisc(let problem):
                DiscSetupPanel(library: library, problem: problem)
            case .ready(let data):
                DiscReadyPanel(library: library, data: data)
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

/// First launch: the user points the app at their own copy of the game.
private struct DiscSetupPanel: View {
    let library: DiscLibrary
    let problem: String?
    @State private var choosing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Naruto: Uzumaki Chronicles 2")
                .font(.largeTitle.bold())
            Text("To play, choose your own copy of the game as a disc image (.iso): the European PAL release, SLES-55090. Nothing is copied: the app reads the file where it is.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            #if os(tvOS)
            Text("Importing a disc on Apple TV isn't available yet. Use the app on iPhone, iPad or Mac for now.")
                .font(.callout)
                .foregroundStyle(.secondary)
            #else
            Button {
                choosing = true
            } label: {
                Label("Choose Disc Image", systemImage: "opticaldisc")
                    .font(.headline)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
            .fileImporter(isPresented: $choosing, allowedContentTypes: Self.discTypes) { result in
                if case .success(let url) = result {
                    Task { await library.importDisc(url) }
                }
            }
            #endif
        }
        .frame(maxWidth: 560, alignment: .leading)
        .padding(32)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }

    private static let discTypes: [UTType] = [UTType(filenameExtension: "iso") ?? .diskImage, .diskImage, .folder]
}

/// The disc was recognised: show art decoded from it on this device.
private struct DiscReadyPanel: View {
    let library: DiscLibrary
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
                    .accessibilityLabel("Character portraits decoded from the disc")
            }
            VStack(alignment: .leading, spacing: 14) {
                Label("Disc recognized", systemImage: "checkmark.seal.fill")
                    .font(.title2.bold())
                    .foregroundStyle(.green)
                Text("SLES-55090 · CFC_\(data.language).DIG · \(data.archive.entries.filter { !$0.isEmpty }.count) entries")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                Text("These portraits were decoded on this device from your disc. The game itself is still being rebuilt from the original code, so there's nothing to play yet.")
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                #if !os(tvOS)
                Button("Choose Another Disc") { library.forget() }
                    .buttonStyle(.glass)
                #endif
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
