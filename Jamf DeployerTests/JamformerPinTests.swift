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
    func versionsMatchFetchScript() throws {
        let pins = try PinnedVersionTests.fetchPins()
        let expected = [
            "jamfplatform": pins["JAMFPLATFORM_VERSION"],
            "jamfpro": pins["JAMFPRO_VERSION"],
            "jamfprotect": pins["JAMFPROTECT_VERSION"],
        ]
        for (provider, version) in expected {
            let pinned = try #require(version, "fetch.sh pins no version for \(provider)")
            #expect(JamformerRunner.bundledProviderVersion(for: provider) == pinned)
        }
    }

    @Test("A launch is pinned, and adds only HOME and PATH", arguments: [0, 1, 2])
    func pinnedLaunchAddsThePin(providerIndex: Int) throws {
        let (provider, version) = Self.providers[providerIndex]
        let launch = try JamformerRunner.pinnedLaunch(arguments: ["-provider", provider],
                                                      environment: ["JAMF_URL": "https://pin.example.invalid"],
                                                      provider: provider)
        #expect(launch.arguments == ["-provider", provider, "-provider-version", version])
        #expect(Set(launch.environment.keys) == ["JAMF_URL", "JAMFORMER_PROVIDER_VERSION", "HOME", "PATH"])
        #expect(launch.environment["JAMFORMER_PROVIDER_VERSION"] == version)
        #expect(throws: JamformerRunner.UnknownProvider.self) {
            _ = try JamformerRunner.pinnedLaunch(arguments: [], environment: [:], provider: "jamfnew")
        }
    }

    @Test("The helper-type retry keeps every argument and is pinned like the first run")
    func helperRetryIsPinned() throws {
        let first = ["-skip-update-check", "-provider", "jamfplatform", "-include-resources", "macos_configuration_profile",
                     "-terraform-path", "/usr/bin/false", "-output", "/tmp/first"]
        let retry = JamformerRunner.helperRetryArguments(first, includeResources: ["macos_configuration_profile"],
                                                         outputPath: "/tmp/retry")
        #expect(retry == ["-skip-update-check", "-provider", "jamfplatform",
                          "-include-resources", "macos_configuration_profile category",
                          "-terraform-path", "/usr/bin/false", "-output", "/tmp/retry"])
        let launch = try JamformerRunner.pinnedLaunch(arguments: retry, environment: [:], provider: "jamfplatform")
        #expect(launch.arguments.filter { $0 == "-provider-version" }.count == 1)
        #expect(launch.arguments.last == EngineInfo.jamfPlatformProviderVersion)
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

    @Test("The percent-encoded form is masked too")
    func encodedSecretIsMasked() {
        let secret = "pa+ss/wo=rd"
        let masked = JamformerRunner.maskedOutput(["GET /login?u=admin&x=pa%2Bss%2Fwo%3Drd failed", "typed pa+ss/wo=rd"],
                                                  secrets: [secret])
        #expect(masked.allSatisfy { !$0.contains("pa%2Bss%2Fwo%3Drd") && !$0.contains(secret) })
    }

    @Test("Longer secrets go first, so none leaves part of another behind")
    func longestFirst() {
        let masked = JamformerRunner.maskedOutput(["echo fake-secret-long"], secrets: ["fake", "fake-secret-long"])
        #expect(masked == ["echo ••••••"])
    }

    @Test("Secrets shorter than 4 characters aren't looked for")
    func shortSecretsAreLeftOut() {
        #expect(JamformerRunner.maskedOutput(["abc xyz"], secrets: ["abc", ""]) == ["abc xyz"])
        #expect(JamformerRunner.maskedOutput(["abcd xyz"], secrets: ["abcd"]) == ["•••••• xyz"])
    }
}
