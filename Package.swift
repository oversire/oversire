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
    // The AgentBinder product only: it has no dependencies.
    dependencies: [
        .package(url: "https://github.com/oversire/agent-binder.git", from: "0.2.1"),
    ],
    targets: [
        .target(name: "OverSireCore"),
        .target(name: "OverSireSync", dependencies: ["OverSireCore"]),
        .target(name: "OverSireAI", dependencies: ["OverSireCore"]),
        // The assistant chat: the loop, the tools, the permissions and the chat store. No AppKit.
        .target(name: "OverSireAssistant", dependencies: ["OverSireCore", "OverSireAI"]),
        // The local CLI engine. It keeps OverSireAI free of AgentBinder.
        .target(name: "AIEngineAgentBinder", dependencies: ["OverSireCore", "OverSireAI", .product(name: "AgentBinder", package: "agent-binder")]),
        .target(name: "GitHubKit", dependencies: ["OverSireCore"]),
        .target(name: "TrackerPlane", dependencies: ["OverSireCore"], path: "Sources/Providers/TrackerPlane"),
        .target(name: "CodeHostGitHub", dependencies: ["OverSireCore", "GitHubKit"], path: "Sources/Providers/CodeHostGitHub"),
        .target(name: "CIGitHubActions", dependencies: ["OverSireCore", "GitHubKit"], path: "Sources/Providers/CIGitHubActions"),
        .target(name: "RuntimeOrca", dependencies: ["OverSireCore"], path: "Sources/Providers/RuntimeOrca"),
        // Skeletons for new adapters. The app does not register them. See docs/adding-a-provider.md.
        .target(name: "TrackerTemplate", dependencies: ["OverSireCore"], path: "Sources/Providers/TrackerTemplate"),
        .target(name: "CodeHostTemplate", dependencies: ["OverSireCore"], path: "Sources/Providers/CodeHostTemplate"),
        .target(name: "CITemplate", dependencies: ["OverSireCore"], path: "Sources/Providers/CITemplate"),
        .target(name: "RuntimeTemplate", dependencies: ["OverSireCore"], path: "Sources/Providers/RuntimeTemplate"),
        .executableTarget(
            name: "OverSireApp",
            dependencies: ["OverSireCore", "OverSireSync", "OverSireAI", "OverSireAssistant", "AIEngineAgentBinder", "GitHubKit",
                           "TrackerPlane", "CodeHostGitHub", "CIGitHubActions", "RuntimeOrca",
                           .product(name: "AgentBinder", package: "agent-binder")],
            // The UI code predates strict concurrency. It moves to .v6 page by page.
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: ["Cocoa", "UserNotifications", "Network", "Carbon", "WebKit", "ScreenCaptureKit", "Speech", "CoreImage"].map { .linkedFramework($0) }
        ),
        .target(name: "OverSireTestKit", dependencies: ["OverSireCore", "OverSireSync", "OverSireAI", "OverSireAssistant"]),

        .testTarget(name: "OverSireAppTests", dependencies: ["OverSireApp", "OverSireSync", "OverSireTestKit"], exclude: ["Fixtures"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "OverSireCoreTests", dependencies: ["OverSireCore", "OverSireTestKit"]),
        .testTarget(name: "OverSireSyncTests", dependencies: ["OverSireSync", "OverSireTestKit"]),
        .testTarget(name: "OverSireAITests", dependencies: ["OverSireAI", "OverSireTestKit"], exclude: ["Fixtures"]),
        .testTarget(name: "OverSireAssistantTests", dependencies: ["OverSireAssistant", "OverSireTestKit"]),
        .testTarget(name: "AIEngineAgentBinderTests", dependencies: ["AIEngineAgentBinder", "OverSireTestKit", .product(name: "AgentBinder", package: "agent-binder")]),
        .testTarget(name: "OverSireTestKitTests", dependencies: ["OverSireTestKit"]),
        .testTarget(name: "TrackerPlaneTests", dependencies: ["TrackerPlane", "OverSireTestKit"], exclude: ["Fixtures"]),
        .testTarget(name: "CodeHostGitHubTests", dependencies: ["CodeHostGitHub", "OverSireTestKit"], exclude: ["Fixtures"]),
        .testTarget(name: "CIGitHubActionsTests", dependencies: ["CIGitHubActions", "OverSireTestKit"]),
        .testTarget(name: "RuntimeOrcaTests", dependencies: ["RuntimeOrca", "OverSireTestKit"]),
        .testTarget(name: "TemplateTests", dependencies: ["TrackerTemplate", "CodeHostTemplate", "CITemplate", "RuntimeTemplate", "OverSireTestKit"]),
        .testTarget(name: "ContractTests", dependencies: ["OverSireCore", "OverSireAI"]),
        .testTarget(name: "LiveTests", dependencies: ["OverSireAI", "OverSireAssistant", "AIEngineAgentBinder", .product(name: "AgentBinder", package: "agent-binder"), "TrackerPlane", "CodeHostGitHub", "CIGitHubActions", "RuntimeOrca", "OverSireTestKit"]),
    ],
    swiftLanguageModes: [.v6]
)
