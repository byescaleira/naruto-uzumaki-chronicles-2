// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "UCKit",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
        .tvOS(.v26),
    ],
    products: [
        .library(name: "UCFormats", targets: ["UCFormats"]),
        .library(name: "UCRender", targets: ["UCRender"]),
        .library(name: "UCEngine", targets: ["UCEngine"]),
        .library(name: "UCAudio", targets: ["UCAudio"]),
        .executable(name: "uc-tool", targets: ["UCTool"]),
    ],
    targets: [
        // Original data formats, recovered from SLES_550.90 with REA (see re/NOTES.md).
        .target(
            name: "UCFormats",
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        // Metal renderer: Metal 4 on iOS/iPadOS/macOS, Metal on tvOS; HDR output on all.
        // Its shaders (App/Shaders) are compiled by the app target into the app's default.metallib.
        .target(
            name: "UCRender",
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        // Game runtime: fixed-step loop, input, game state.
        .target(
            name: "UCEngine",
            dependencies: ["UCFormats", "UCRender"],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        // Streamed ADX playback (AVAudioEngine): music and voice buses, seamless loops.
        .target(
            name: "UCAudio",
            dependencies: ["UCFormats"],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        // Command-line asset tool: list / verify / extract the original archives.
        .executableTarget(
            name: "UCTool",
            dependencies: ["UCFormats", "UCAudio"],
            path: "Sources/UCTool"
        ),
        .testTarget(
            name: "UCFormatsTests",
            dependencies: ["UCFormats"]
        ),
        .testTarget(
            name: "UCEngineTests",
            dependencies: ["UCEngine"]
        ),
        .testTarget(
            name: "UCAudioTests",
            dependencies: ["UCAudio", "UCFormats"]
        ),
    ]
)
