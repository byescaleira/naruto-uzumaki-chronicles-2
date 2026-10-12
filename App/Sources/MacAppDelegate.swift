#if os(macOS)
import AppKit

/// macOS: the game window always runs in native full screen and re-enters it if the user
/// leaves, so the surface always covers the display.
@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowNeedsFullScreen(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
        center.addObserver(self, selector: #selector(windowNeedsFullScreen(_:)), name: NSWindow.didExitFullScreenNotification, object: nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc private func windowNeedsFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, !window.styleMask.contains(.fullScreen) else { return }
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.toggleFullScreen(nil)
    }
}
#endif
