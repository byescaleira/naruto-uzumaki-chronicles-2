import CoreGraphics
import Testing
@testable import UCEngine

@Suite("Movie scaling")
struct MoviePlayerTests {
    /// MV00's presentation size: 512×448 with 7:6 pixels.
    private let movie = CGSize(width: 512.0 * 7 / 6, height: 448)

    @Test("Covering a wider screen crops the 4:3 movie's top and bottom", arguments: [
        (CGSize(width: 3840, height: 2160), 0.25),      // Apple TV 4K, 16:9
        (CGSize(width: 2622, height: 1206), 0.3866),    // iPhone 17 Pro, landscape
        (CGSize(width: 2560, height: 1600), 1.0 / 6),   // Mac, 16:10
        (CGSize(width: 2732, height: 2048), 0.0),       // iPad Pro 12.9", 4:3
    ])
    func crop(screen: CGSize, expected: Double) {
        #expect(abs(MoviePlayer.cropFraction(content: movie, screen: screen) - expected) < 0.001)
    }

    @Test("Degenerate sizes crop nothing")
    func degenerate() {
        #expect(MoviePlayer.cropFraction(content: .zero, screen: CGSize(width: 16, height: 9)) == 0)
        #expect(MoviePlayer.cropFraction(content: movie, screen: .zero) == 0)
    }
}
