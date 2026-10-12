import SwiftUI
import UCEngine

@main
struct NarutoUC2App: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    #endif

    @State private var runtime = GameRuntime()
    @State private var library = GameLibrary()

    var body: some Scene {
        WindowGroup {
            RootView(runtime: runtime, library: library)
                .ignoresSafeArea()
                #if os(iOS)
                .statusBarHidden()
                #endif
                .persistentSystemOverlays(.hidden)
                #if os(macOS)
                .frame(minWidth: 960, minHeight: 540)
                #endif
                .task { await library.load() }
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        #endif
    }
}
