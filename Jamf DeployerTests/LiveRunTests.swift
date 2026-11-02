import Foundation
import Testing
import JTKit
import JamfDeployerCore
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

    static func change(_ name: String, type: String = "jamfplatform_pro_category") -> ObjectChange {
        ObjectChange(address: "module.x.\(type).this", resourceType: type, displayName: name, kind: .create, fieldDiffs: [])
    }

    @Test func deploysTouchOnlyTestObjects() throws {
        #expect(LiveRun.prefix.hasPrefix("JTKTEST"))
        try LiveRun.requireOnlyTestObjects([Self.change("\(LiveRun.prefix) – Category")])
        #expect(throws: LiveRun.Refused.self) {
            try LiveRun.requireOnlyTestObjects([Self.change("\(LiveRun.prefix) – A"), Self.change("Google Chrome")])
        }
        // Review finding 7: tenant-wide settings have no name to prefix.
        try LiveRun.requireOnlyTestObjects([Self.change("this", type: "jamfplatform_pro_computer_check_in_settings")])
        #expect(throws: LiveRun.Refused.self) {
            try LiveRun.requireOnlyTestObjects([Self.change("this", type: "jamfplatform_pro_policy")])
        }
    }

    @Test func theRoleGateReadsTheCommandAfterGlobalFlags() {
        #expect(LiveRun.command(["-chdir=generated", "apply", "plan.bin"]) == "apply")
        #expect(throws: LiveRun.Refused.self) {
            try LiveRun.check(.openTofu, arguments: ["-chdir=generated", "apply"],
                              environment: Self.platform(Self.environmentProduction), entries: Self.entries)
        }
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

/// Review finding 2: an adopted secret setting can be entered on another
/// Mac, and the error says where.
@MainActor
@Suite("Adopted secret settings")
struct AdoptedSecretSettingsTests {
    @Test func theMissingValueErrorPointsToTheSection() {
        let text = TenantDeployService.DeployError.missingAdoptedSecret("secret_wifi_office").errorDescription ?? ""
        #expect(text.contains("Adopted secret settings"))
        #expect(text.contains("Wifi office"))
        #expect(!text.contains("Adopt the object again"), "discovery never lists an object already adopted")
    }

    @Test func namesReadAsTitles() {
        #expect(AdoptedSecretSettings.title("secret_wifi_office") == "Wifi office")
        #expect(AdoptedSecretSettings.title("vpn_shared_secret") == "Vpn shared secret")
        #expect(AdoptedSecretSettings.title("secret_") == "secret_")
    }

    @Test func theSectionWritesTheItemAdoptUses() {
        // Same service and account as Adopt's (`_adopted` block): the deploy finds it.
        let tenantID = UUID()
        let item = TenantSecrets(tenantID: tenantID).adoptedVariable("secret_wifi_office")
        #expect(item.account.hasPrefix(tenantID.uuidString))
        #expect(item.account.contains("_adopted"))
    }
}

/// Review finding 4: a menu command runs only for the tenant it was issued for.
@MainActor
@Suite("Menu requests")
struct MenuRequestTests {
    @Test func aTenantsCommandIsDroppedOnAnotherTenant() {
        let state = AppState()
        let a = UUID(), b = UUID()
        state.selection = .tenant(a)
        state.request(.baselineUpdates)
        // the editor for A isn't on screen; B's page appears first
        state.selection = .tenant(b)
        #expect(!state.isWaiting(.baselineUpdates, for: b))
        #expect(state.menuRequest == nil, "dropped, so A's later editor doesn't run it either")

        state.selection = .tenant(a)
        state.request(.adopt)
        #expect(state.take([.adopt], for: b) == nil)
        #expect(state.menuRequest == nil)

        state.request(.adopt)
        #expect(state.take([.adopt], for: a) == .adopt)
    }

    @Test func commandsWithoutATenantStillRun() {
        let state = AppState()
        state.selection = .fleet
        state.request(.rollOut)
        #expect(state.take([.rollOut]) == .rollOut)
        state.request(.adopt)
        #expect(state.take([.adopt], for: UUID()) == nil, "a tenant command issued with no tenant selected")
    }
}

@Suite("Preflight block permissions")
struct PreflightBlockPermissionTests {
    @Test func aPackageUploadIsNamedOnPlatformTenants() {
        let rows = PreflightService.blockPermissionRows(["packages:create", BlockCapture.jamfCloudUploadPermission], connection: .platform)
        #expect(rows.map(\.id) == ["jcds-upload"])
        #expect(rows.first?.outcome == .warn)
        #expect(rows.first?.detail.contains(BlockCapture.jamfCloudUploadPermission) == true)
        #expect(PreflightService.blockPermissionRows(["packages:create"], connection: .platform).isEmpty)
        #expect(PreflightService.blockPermissionRows([BlockCapture.jamfCloudUploadPermission], connection: .jamfPro).isEmpty)
    }
}

@Suite("Store review wording")
struct StoreReviewWordingTests {
    /// Review finding 10: in Team Mode the bulk confirmation says the files go to the team.
    @Test func markAllSaysTheFilesAreShared() {
        #expect(StoreSecretsSheet.markAllMessage(isTeamMode: true).contains("shared with your team on the next sync"))
        #expect(!StoreSecretsSheet.markAllMessage(isTeamMode: false).contains("team"))
    }
}

@MainActor
@Suite("Menu dimming")
struct MenuDimmingTests {
    /// Review finding 12: menu commands dim while any main-window sheet is open.
    @Test func sheetsDimTheMenus() {
        let state = AppState()
        #expect(!state.isSheetOpen)
        state.sheet("tenant", isOpen: true)
        state.sheet("window", isOpen: true)
        state.sheet("tenant", isOpen: false)
        #expect(state.isSheetOpen, "the store review is still open")
        state.sheet("window", isOpen: false)
        #expect(!state.isSheetOpen)
    }

    @Test func previewNeedsSomethingToPreview() {
        let fixture = DeployServiceGuardTests.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var tenant = DeployServiceGuardTests.tenant()
        fixture.tenantStore.add(tenant)
        #expect(!fixture.service.canPreview(tenant), "no blocks, nothing adopted")
        tenant.blockSelections = [BlockSelection(blockID: "categories")]
        #expect(fixture.service.canPreview(tenant))
        tenant.mode = .handedOver
        #expect(!fixture.service.canPreview(tenant))
    }
}
