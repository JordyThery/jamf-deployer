// swift-tools-version: 6.2

// DeployerKit: the parts shared between Jamf Deployer and Intune Deployer —
// update checking, guided tour, activity log, Keychain access, JSON
// persistence, design-language components and text export.
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
