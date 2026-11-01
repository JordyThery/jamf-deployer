import Foundation
import Testing
import JTKit
import JamfDeployerCore
@testable import Jamf_Deployer

@MainActor
@Suite("Demo Mode switch and screen work")
struct DemoSwitchScreenWorkTests {
    @Test("Exports, discovery, Day 0 steps and rollouts block the Demo Mode switch")
    func screenWorkBlocksTheSwitch() throws {
        let defaults = try #require(UserDefaults(suiteName: "jd-switch-\(UUID().uuidString)"))
        let work = ScreenWork()
        let worlds = AppWorlds(demo: DemoMode(key: "demoMode", defaults: defaults, arguments: ["app"]),
                               activityLog: ActivityLog(), screenWork: work)
        #expect(!worlds.isBusy)
        let token = work.begin("Export")
        #expect(worlds.isBusy)
        work.end(token)
        #expect(!worlds.isBusy)
    }
}

@Suite("Failed-create recovery and objects that existed before")
struct PreexistingObjectTests {
    static func candidate(_ address: String) -> CreateFailureRecovery.Candidate {
        CreateFailureRecovery.Candidate(address: address, resourceType: "jamfpro_policy", name: "JD - Example")
    }

    @Test("Only creates looked up before the apply are recovered")
    func unknownBeforeApplyIsNeverRecovered() {
        let looked = Self.candidate("module.a.jamfpro_policy.one")
        let failed = Self.candidate("module.a.jamfpro_policy.two")
        let missing = Self.candidate("module.a.jamfpro_policy.three")
        var before: [String: Set<String>?] = [looked.address: ["7"]]
        before[failed.address] = .some(nil)
        #expect(TenantDeployService.recoverable([looked, failed, missing], existingBeforeApply: before) == [looked])
    }
}

@Suite("Engineer client ID cache")
struct EngineerClientIDCacheTests {
    @Test("Read once, kept up to date by every save and delete")
    func cacheFollowsWrites() {
        // An account in the reserved fake range: the in-memory vault, never the Keychain.
        let tenantID = UUID(uuidString: DemoSamples.uuid(0xEC01))!
        let item = TenantSecrets(tenantID: tenantID).engineerClientID
        defer { item.delete() }
        #expect(item.save("alex-client"))
        #expect(item.load() == "alex-client")

        // A change behind the cache's back isn't read again…
        DemoSecretVault.save("changed-elsewhere", service: item.service, account: item.account)
        #expect(item.load() == "alex-client")
        // …but every write through the item is.
        #expect(item.save("sam-client"))
        #expect(item.load() == "sam-client")
        item.delete()
        #expect(item.load() == nil)
        #expect(DemoSecretVault.load(service: item.service, account: item.account) == nil)
    }

    @Test("Other items are never cached")
    func onlyTheEngineerIDIsCached() {
        let tenantID = UUID(uuidString: DemoSamples.uuid(0xEC02))!
        let item = TenantSecrets(tenantID: tenantID).protectClientSecret
        defer { item.delete() }
        #expect(item.save("one"))
        DemoSecretVault.save("two", service: item.service, account: item.account)
        #expect(item.load() == "two")
    }
}

@Suite("Team passphrase check")
struct PassphraseCheckTests {
    static let tenantID = UUID(uuidString: "00000000-0000-4000-9000-0000000000ee")!

    @Test("The check lives outside tenants/ and is never taken for a tenant")
    func checkIsNotATenant() {
        let listing = "README.md\n\(StateBackendService.passphraseCheckPath)\ntenants/\(Self.tenantID.uuidString)/terraform.tfstate\n"
        let contents = GitStoreService.TeamStateContents(listing: listing)
        #expect(contents.hasPassphraseCheck)
        #expect(contents.tenantIDs == [Self.tenantID])
        #expect(!StateBackendService.passphraseCheckPath.hasPrefix("tenants/"))
        #expect(GitStoreService.tenantIDs(inStateListing: StateBackendService.passphraseCheckPath).isEmpty)
    }

    @Test("What a check compares against")
    func plan() {
        typealias Contents = GitStoreService.TeamStateContents
        #expect(TenantDeployService.passphraseCheckPlan(Contents(listing: StateBackendService.passphraseCheckPath)) == .passphraseCheck)
        #expect(TenantDeployService.passphraseCheckPlan(
            Contents(listing: "tenants/\(Self.tenantID.uuidString)/terraform.tfstate")) == .tenantState)
        // Only a team space with neither is accepted unverified.
        #expect(TenantDeployService.passphraseCheckPlan(Contents(listing: "README.md")) == .nothingToCompare)
    }

    @Test("The check's state is empty: nothing in it but OpenTofu's bookkeeping")
    func checkStateIsEmpty() throws {
        let data = TenantDeployService.passphraseCheckState(lineage: Self.tenantID)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["version"] as? Int == 4)
        #expect((object["resources"] as? [Any])?.isEmpty == true)
        #expect((object["outputs"] as? [String: Any])?.isEmpty == true)
        #expect(object["lineage"] as? String == Self.tenantID.uuidString.lowercased())
        #expect(Set(object.keys) == ["version", "terraform_version", "serial", "lineage", "outputs", "resources"])
    }

    @Test("The state branch's check is found and kept apart from tenants")
    func checkOnTheStateBranch() async throws {
        let (store, _, teammate, root) = try await TestGit.teamSpace()
        defer { try? FileManager.default.removeItem(at: root) }
        try await store.ensureStateBranch()
        #expect(try await store.teamStateContents() == GitStoreService.TeamStateContents(listing: ""))

        try TestGit.run(["fetch", "-q", "origin", StateBackendService.stateBranch], in: teammate)
        try TestGit.run(["checkout", "-q", "-b", "state", "FETCH_HEAD"], in: teammate)
        try TestGit.write("{\"encrypted\": true}\n", to: StateBackendService.passphraseCheckPath, in: teammate)
        try TestGit.run(["add", "-A"], in: teammate)
        try TestGit.run(["commit", "-qm", "check"], in: teammate)
        try TestGit.run(["push", "-q", "origin", "state:\(StateBackendService.stateBranch)"], in: teammate)

        let contents = try await store.teamStateContents()
        #expect(contents.hasPassphraseCheck)
        #expect(contents.tenantIDs.isEmpty)
        #expect(try await store.tenantIDsWithTeamState().isEmpty)
    }
}
