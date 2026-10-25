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
            // Third-party licence texts, unchanged, for About and THIRD-PARTY-NOTICES.md.
            resources: [.copy("Licences")],
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
