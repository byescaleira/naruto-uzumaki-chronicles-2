import Foundation
import Observation
import UCEngine
import UCFormats

/// Finds and remembers the user's disc. The app never ships game data: the user picks their
/// own `.iso` once (Files on iPhone/iPad, Finder on Mac) and the app keeps a security-scoped
/// bookmark to read it in place, without copying 4 GB.
@MainActor
@Observable
final class DiscLibrary {
    enum State {
        case searching
        case needsDisc(problem: String?)
        case loading
        case ready(GameData)
    }

    private(set) var state: State = .searching
    private static let bookmarkKey = "disc.bookmark"
    /// The URL whose security scope is held while the game reads from it.
    private var accessedURL: URL?

    /// Restores the remembered disc, or falls back to development locations.
    func restore() async {
        if let bookmark = UserDefaults.standard.data(forKey: Self.bookmarkKey) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: Self.resolveOptions, relativeTo: nil, bookmarkDataIsStale: &stale) {
                if await open(url, remember: stale) { return }
            }
            UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        }
        for url in Self.developmentLocations where await open(url, remember: false) {
            return
        }
        state = .needsDisc(problem: nil)
    }

    /// Opens a disc the user just picked and remembers it.
    func importDisc(_ url: URL) async {
        _ = await open(url, remember: true)
    }

    func forget() {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = nil
        state = .needsDisc(problem: nil)
    }

    @discardableResult
    private func open(_ url: URL, remember: Bool) async -> Bool {
        state = .loading
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = url.startAccessingSecurityScopedResource() ? url : nil
        do {
            let data = try await Task.detached(priority: .userInitiated) { try GameData(url: url) }.value
            if remember, let bookmark = try? url.bookmarkData(options: Self.bookmarkOptions, includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
            }
            state = .ready(data)
            return true
        } catch {
            accessedURL?.stopAccessingSecurityScopedResource()
            accessedURL = nil
            state = .needsDisc(problem: Self.describe(error))
            return false
        }
    }

    private static func describe(_ error: any Error) -> String {
        switch error {
        case DiscImage.Failure.notISO9660:
            String(localized: "This file isn't a PS2 disc image (ISO 9660).")
        case DiscImage.Failure.wrongGame:
            String(localized: "This disc isn't Naruto: Uzumaki Chronicles 2 (PAL, SLES-55090).")
        case DiscImage.Failure.missingFile(let name):
            String(localized: "The disc is missing \(name).")
        default:
            error.localizedDescription
        }
    }

    private static var developmentLocations: [URL] {
        var urls: [URL] = []
        if let path = ProcessInfo.processInfo.environment["NUC2_DATA"] {
            urls.append(URL(fileURLWithPath: path))
        }
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            urls.append(documents.appending(path: "NUC2", directoryHint: .isDirectory))
        }
        return urls
    }

    #if os(macOS)
    private static let bookmarkOptions: URL.BookmarkCreationOptions = [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
    private static let resolveOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
    #else
    private static let bookmarkOptions: URL.BookmarkCreationOptions = []
    private static let resolveOptions: URL.BookmarkResolutionOptions = []
    #endif
}
