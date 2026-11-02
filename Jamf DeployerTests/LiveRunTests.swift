import Foundation
import Testing
import JTKit
@testable import Jamf_Deployer

/// The rules the app keeps under the live-check switch for what the
/// release check's gateway can't see: OpenTofu's and jamformer's own traffic.
@Suite("Live run rules")
struct LiveRunTests {
    static let environmentA = "6f1c2b3a-4d5e-4f60-8172-93a4b5c6d7e8"
    static let environmentProduction = "0a1b2c3d-4e5f-4a60-8b72-93a4b5c6d7e9"

    static let entries: [LiveLaunch.LaunchFile.Entry] = [
        .init(role: "jamf-test-a", connection: Connection(name: "jamf-test-a (Jamf Pro)", service: .jamfPro,
                                                          signIn: .usernamePassword, serverURL: "https://a.example.com")),
        .init(role: "jamf-test-b", connection: Connection(name: "jamf-test-b (Jamf Platform API)", service: .jamfPlatform,
                                                          region: .us, environmentID: environmentA)),
        .init(role: "jamfpro-production", connection: Connection(name: "jamfpro-production (Jamf Platform API)",
                                                                 service: .jamfPlatform, region: .us,
                                                                 environmentID: environmentProduction)),
    ]

    static func platform(_ id: String) -> [String: String] {
        ["JAMFPLATFORM_BASE_URL": "https://us.api.jamfcloud.com", "JAMFPLATFORM_ENVIRONMENT_ID": id.uppercased()]
    }

    @Test func enginesReachOnlyTheRunsTenants() throws {
        try LiveRun.check(.openTofu, arguments: ["plan"], environment: Self.platform(Self.environmentA), entries: Self.entries)
        try LiveRun.check(.openTofu, arguments: ["apply", "plan.bin"], environment: Self.platform(Self.environmentA), entries: Self.entries)
        try LiveRun.check(.openTofu, arguments: ["apply"], environment: ["JAMFPRO_INSTANCE_FQDN": "https://a.example.com"],
                          entries: Self.entries)
        // jamformer reads production (capture), never anything else
        try LiveRun.check(.jamformer, arguments: [], environment: ["JAMF_URL": "https://us.api.jamfcloud.com",
                                                                    "JAMF_ENVIRONMENT_ID": Self.environmentProduction],
                          entries: Self.entries)
        #expect(throws: LiveRun.Refused.self) {
            try LiveRun.check(.openTofu, arguments: ["plan"], environment: Self.platform(UUID().uuidString), entries: Self.entries)
        }
        #expect(throws: LiveRun.Refused.self) {
            try LiveRun.check(.jamformer, arguments: [], environment: ["JAMF_URL": "https://other.example.com"], entries: Self.entries)
        }
        // Jamf Protect isn't part of live runs
        #expect(throws: LiveRun.Refused.self) {
            try LiveRun.check(.openTofu, arguments: ["plan"], environment: ["JAMFPROTECT_URL": "https://x.protect.jamfcloud.com"],
                              entries: Self.entries)
        }
        // no Jamf at all (fmt, version): nothing to check
        try LiveRun.check(.openTofu, arguments: ["fmt"], environment: [:], entries: Self.entries)
    }

    @Test func readRolesAreNeverWritten() throws {
        try LiveRun.check(.openTofu, arguments: ["plan"], environment: Self.platform(Self.environmentProduction), entries: Self.entries)
        for command in ["apply", "destroy", "import"] {
            #expect(throws: LiveRun.Refused.self) {
                try LiveRun.check(.openTofu, arguments: [command], environment: Self.platform(Self.environmentProduction),
                                  entries: Self.entries)
            }
        }
    }

    @Test func teamModeAndPushesNeverRun() throws {
        #expect(throws: LiveRun.Refused.self) {
            try LiveRun.check(.stateBackend, arguments: [], environment: nil, entries: Self.entries)
        }
        #expect(throws: LiveRun.Refused.self) {
            try LiveRun.check(.git, arguments: ["push", "origin", "main"], environment: nil, entries: Self.entries)
        }
        try LiveRun.check(.git, arguments: ["commit", "-m", "Deploy"], environment: nil, entries: Self.entries)
    }

    @Test func deploysTouchOnlyTestObjects() throws {
        #expect(LiveRun.prefix.hasPrefix("JTKTEST"))
        try LiveRun.requireOnlyTestObjects(["\(LiveRun.prefix) – Category"])
        #expect(throws: LiveRun.Refused.self) { try LiveRun.requireOnlyTestObjects(["\(LiveRun.prefix) – A", "Google Chrome"]) }
    }

    @Test func theRunsConnectionsBecomeTenants() throws {
        let pro = try #require(LiveRun.tenant(for: Self.entries[0]))
        #expect(pro.isJamfPro && pro.jamfProAuth == .userAccount && !pro.isProduction)
        let production = try #require(LiveRun.tenant(for: Self.entries[2]))
        #expect(production.isProduction, "a read role is marked production, so its deploys ask for the typed name")
        #expect(production.environmentID == Self.environmentProduction)
        #expect(production.namePrefix.hasPrefix("JTKTEST"))
    }
}
