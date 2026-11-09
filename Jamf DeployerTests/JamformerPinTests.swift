import Foundation
import os
import Testing
import JamfDeployerCore
import JTKit
@testable import Jamf_Deployer

// Capture, Adopt and Clone run jamformer. Left to itself it downloads the
// newest engine plugin, whose attribute names the bundled engine may not
// know yet; every launch must name the bundled plugin version.

/// Every jamformer launch the doorway was asked for.
private final class Launches: Sendable {
    private let launches = OSAllocatedUnfairLock<[ToolDoorway.Launch]>(initialState: [])
    var all: [ToolDoorway.Launch] { launches.withLock { $0 } }
    func record(_ launch: ToolDoorway.Launch) { launches.withLock { $0.append(launch) } }
}

@Suite("jamformer uses the bundled plugin versions")
struct JamformerPinTests {
    static let providers: [(name: String, version: String)] = [
        ("jamfplatform", EngineInfo.jamfPlatformProviderVersion),
        ("jamfpro", EngineInfo.jamfProProviderVersion),
        ("jamfprotect", EngineInfo.jamfProtectProviderVersion),
    ]

    /// Fails unless the launch pins `version`, as an argument and in the environment.
    private func expectPinned(_ launch: ToolDoorway.Launch, to version: String) {
        #expect(launch.tool == .jamformer)
        let index = launch.arguments.firstIndex(of: "-provider-version")
        #expect(index != nil, "launched without -provider-version: \(launch.arguments)")
        if let index {
            #expect(launch.arguments.indices.contains(index + 1) && launch.arguments[index + 1] == version)
        }
        #expect(launch.environment?["JAMFORMER_PROVIDER_VERSION"] == version)
    }

    @Test("Every export and type list names the bundled version", arguments: [0, 1, 2])
    func everyLaunchIsPinned(providerIndex: Int) async {
        let (provider, version) = Self.providers[providerIndex]
        let launches = Launches()
        let runner = JamformerRunner(tools: .trapRecording { launches.record($0) })
        var tenant = Tenant(name: "Pin", region: .us, clientID: "client", environmentID: "env", isProduction: false)
        if provider == "jamfpro" {
            tenant.connection = .jamfPro
            tenant.jamfProURL = "https://pin.example.invalid"
        }

        await #expect(throws: ToolDoorway.Refused.self) {
            _ = try await runner.listResourceTypes(provider: provider)
        }
        await #expect(throws: ToolDoorway.Refused.self) {
            _ = try await runner.export(tenant: tenant, clientSecret: "secret", provider: provider,
                                        includeResources: ["policy"], includePackageFiles: false,
                                        terraformPath: "/usr/bin/false")
        }

        #expect(launches.all.count == 2)
        for launch in launches.all {
            expectPinned(launch, to: version)
        }
    }

    @Test("A provider without a bundled version never starts jamformer")
    func unknownProviderIsRefused() async {
        let launches = Launches()
        let runner = JamformerRunner(tools: .trapRecording { launches.record($0) })
        await #expect(throws: JamformerRunner.UnknownProvider.self) {
            _ = try await runner.listResourceTypes(provider: "jamfnew")
        }
        #expect(launches.all.isEmpty)
    }

    @Test("The bundled versions are the ones fetch.sh pins")
    func versionsMatchEngineInfo() {
        for (provider, version) in Self.providers {
            #expect(JamformerRunner.bundledProviderVersion(for: provider) == version)
        }
    }
}

@Suite("A failed export's output, masked")
struct JamformerFailureOutputTests {
    @Test func secretsAndTokensAreMasked() {
        let lines = [
            "Verifying authentication...",
            "terraform init failed: client_secret=s3cr3t-value-123",
            "Authorization: Bearer abc.def.ghi",
            "echoed s3cr3t-value-123 back",
        ]
        let masked = JamformerRunner.maskedOutput(lines, secrets: ["s3cr3t-value-123"])
        #expect(masked.count == lines.count)
        #expect(masked[0] == "Verifying authentication...")
        #expect(masked.allSatisfy { !$0.contains("s3cr3t-value-123") })
        #expect(!masked[2].contains("abc.def.ghi"))
    }
}
