// swift-tools-version: 6.0
import PackageDescription

// Only OverSireApp imports AppKit and knows the concrete adapters.
// Provider targets import only OverSireCore (and GitHubKit).
let package = Package(
    name: "OverSire",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "oversire", targets: ["OverSireApp"]),
    ],
    targets: [
        .target(name: "OverSireCore"),
        .target(name: "OverSireSync", dependencies: ["OverSireCore"]),
        .target(name: "OverSireAI", dependencies: ["OverSireCore"]),
        .target(name: "GitHubKit", dependencies: ["OverSireCore"]),
        .target(name: "TrackerPlane", dependencies: ["OverSireCore"], path: "Sources/Providers/TrackerPlane"),
        .target(name: "CodeHostGitHub", dependencies: ["OverSireCore", "GitHubKit"], path: "Sources/Providers/CodeHostGitHub"),
        .target(name: "CIGitHubActions", dependencies: ["OverSireCore", "GitHubKit"], path: "Sources/Providers/CIGitHubActions"),
        .target(name: "RuntimeOrca", dependencies: ["OverSireCore"], path: "Sources/Providers/RuntimeOrca"),
        .executableTarget(
            name: "OverSireApp",
            dependencies: ["OverSireCore", "OverSireSync", "OverSireAI", "GitHubKit",
                           "TrackerPlane", "CodeHostGitHub", "CIGitHubActions", "RuntimeOrca"],
            // The UI code predates strict concurrency. It moves to .v6 page by page.
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: ["Cocoa", "UserNotifications", "Network", "Carbon", "WebKit"].map { .linkedFramework($0) }
        ),
        .target(name: "OverSireTestKit", dependencies: ["OverSireCore", "OverSireSync", "OverSireAI"]),

        .testTarget(name: "OverSireAppTests", dependencies: ["OverSireApp", "OverSireSync", "OverSireTestKit"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "OverSireCoreTests", dependencies: ["OverSireCore", "OverSireTestKit"]),
        .testTarget(name: "OverSireSyncTests", dependencies: ["OverSireSync", "OverSireTestKit"]),
        .testTarget(name: "OverSireAITests", dependencies: ["OverSireAI", "OverSireTestKit"]),
        .testTarget(name: "OverSireTestKitTests", dependencies: ["OverSireTestKit"]),
        .testTarget(name: "TrackerPlaneTests", dependencies: ["TrackerPlane", "OverSireTestKit"]),
        .testTarget(name: "CodeHostGitHubTests", dependencies: ["CodeHostGitHub", "OverSireTestKit"]),
        .testTarget(name: "CIGitHubActionsTests", dependencies: ["CIGitHubActions", "OverSireTestKit"]),
        .testTarget(name: "RuntimeOrcaTests", dependencies: ["RuntimeOrca", "OverSireTestKit"]),
        .testTarget(name: "ContractTests", dependencies: ["OverSireCore", "OverSireAI"]),
        .testTarget(name: "LiveTests", dependencies: ["TrackerPlane", "CodeHostGitHub", "CIGitHubActions", "RuntimeOrca", "OverSireTestKit"]),
    ],
    swiftLanguageModes: [.v6]
)
