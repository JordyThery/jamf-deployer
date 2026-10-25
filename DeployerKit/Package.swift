// swift-tools-version: 6.2

// DeployerKit: what is left of Jamf Deployer's first shared package —
// Keychain access (moves to JTKit in ROADMAP step 4) and the version
// comparison used for the bundled components. Everything else moved to JTKit.
import PackageDescription

let package = Package(
    name: "DeployerKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "DeployerKit", targets: ["DeployerKit"])
    ],
    targets: [
        .target(
            name: "DeployerKit",
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("MemberImportVisibility"),
            ]
        ),
        .testTarget(
            name: "DeployerKitTests",
            dependencies: ["DeployerKit"]
        ),
    ]
)
