import Foundation
import Observation
import UCEngine
import UCFormats

/// Loads the game data embedded in the app bundle (`GameData/`, see scripts/fetch_game_data.sh).
/// Debug builds can point `NUC2_DATA` at a disc image or folder instead.
@MainActor
@Observable
final class GameLibrary {
    enum State {
        case loading
        case ready(GameData)
        case failed(String)
    }

    private(set) var state: State = .loading

    var isReady: Bool {
        if case .ready = state { true } else { false }
    }

    func load() async {
        guard let url = Self.dataURL else {
            state = .failed(String(localized: "This build doesn't include the game data."))
            return
        }
        do {
            let data = try await Task.detached(priority: .userInitiated) { try GameData(url: url) }.value
            state = .ready(data)
        } catch {
            state = .failed(Self.describe(error))
        }
    }

    private static var dataURL: URL? {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["NUC2_DATA"] {
            return URL(fileURLWithPath: path)
        }
        #endif
        return Bundle.main.url(forResource: "GameData", withExtension: nil)
    }

    private static func describe(_ error: any Error) -> String {
        switch error {
        case DiscImage.Failure.wrongGame:
            String(localized: "The embedded data isn't Naruto: Uzumaki Chronicles 2 (PAL, SLES-55090).")
        case DiscImage.Failure.missingFile(let name):
            String(localized: "The embedded data is missing \(name).")
        default:
            error.localizedDescription
        }
    }
}
