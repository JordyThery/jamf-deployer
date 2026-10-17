// swift-tools-version: 6.2

// JamfDeployerCore: the engine-facing, UI-free heart of Jamf Deployer —
// plan/stream models, catalog parsing, workspace generation, preview
// grouping and error translation. Fully testable against fixtures.
import PackageDescription

let package = Package(
    name: "JamfDeployerCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "JamfDeployerCore", targets: ["JamfDeployerCore"])
    ],
    targets: [
        .target(
            name: "JamfDeployerCore",
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("MemberImportVisibility"),
            ]
        ),
        .testTarget(
            name: "JamfDeployerCoreTests",
            dependencies: ["JamfDeployerCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
