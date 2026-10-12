import SwiftUI
import UCEngine

@main
struct NarutoUC2App: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    #endif

    @State private var runtime = GameRuntime(data: GameDataLocator.locate())

    var body: some Scene {
        WindowGroup {
            GameScreen(runtime: runtime)
                .ignoresSafeArea()
                #if os(iOS)
                .statusBarHidden()
                #endif
                .persistentSystemOverlays(.hidden)
                #if os(macOS)
                .frame(minWidth: 960, minHeight: 540)
                #endif
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        #endif
    }
}

/// Finds the user's disc data. The app never ships game assets: point it at the mounted
/// ISO or an extracted copy with the `NUC2_DATA` environment variable, or place the files
/// in the app's Documents folder (iOS/iPadOS/tvOS: via Finder file sharing).
enum GameDataLocator {
    static func locate() -> GameData? {
        var candidates: [URL] = []
        if let path = ProcessInfo.processInfo.environment["NUC2_DATA"] {
            candidates.append(URL(fileURLWithPath: path, isDirectory: true))
        }
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            candidates.append(documents.appending(path: "NUC2", directoryHint: .isDirectory))
        }
        for root in candidates {
            if let data = try? GameData(root: root) { return data }
        }
        return nil
    }
}
