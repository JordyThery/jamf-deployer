import Foundation
import Testing
import JTKit
@testable import Jamf_Deployer

// A Keychain that can't be read right now (locked, the prompt cancelled)
// is never treated as "no secret": nothing is offered for entry over it,
// saved over it or deleted.

@Suite("A Keychain that can't be read")
struct UnreadableKeychainTests {
    @Test("Stored, none and unreadable are three different answers")
    func presenceHasThreeStates() {
        #expect(SecretPresence(reading: { "fake-passphrase" }) == .stored)
        #expect(SecretPresence(reading: { nil }) == .none)
        let unreadable = SecretPresence(reading: { throw SecretStoreError(status: -25308) })
        #expect(unreadable == .unreadable(SecretStoreError(status: -25308).localizedDescription))
    }

    @Test("An unreadable item throws from read() and counts as unreadable")
    func unreadableItemThrows() {
        let item = TenantSecrets(tenantID: UUID()).statePassphrase
        item.setUnreadableForTests(true)
        defer { item.setUnreadableForTests(false) }
        #expect(throws: SecretStoreError.self) { _ = try item.read() }
        #expect(item.load() == nil, "load() is for display only")
        guard case .unreadable = SecretPresence(reading: { try item.read() }) else {
            Issue.record("an unreadable item must not read as none")
            return
        }
    }

    @Test("Update Client Secret… never saves while this Mac's client ID can't be read")
    func clientSecretSheetWaitsForTheClientID() {
        // With the record's ID as the fallback, a save would otherwise delete this Mac's own ID.
        #expect(!ClientSecretUpdate.canSave(isTeamMode: true, isSavedIDReadable: false, savedID: "record-id",
                                            typedID: "record-id", secret: "fake-secret", passphrase: ""))
        #expect(!ClientSecretUpdate.canSave(isTeamMode: false, isSavedIDReadable: false, savedID: "record-id",
                                            typedID: "record-id", secret: "fake-secret", passphrase: "fake"))
        #expect(ClientSecretUpdate.canSave(isTeamMode: true, isSavedIDReadable: true, savedID: "record-id",
                                           typedID: "record-id", secret: "fake-secret", passphrase: ""))
    }

    @MainActor
    @Test("No recovery sheet is written when the passphrase can't be read")
    func recoverySheetNeedsAReadablePassphrase() throws {
        let fixture = DeployServiceGuardTests.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let tenant = DeployServiceGuardTests.tenant("Locked")
        fixture.tenantStore.add(tenant)
        let item = TenantSecrets(tenantID: tenant.id).statePassphrase
        item.setUnreadableForTests(true)
        defer {
            item.setUnreadableForTests(false)
            item.delete()
        }
        #expect(throws: SecretStoreError.self) { _ = try fixture.service.recoverySheetText(for: tenant) }
        #expect(throws: SecretStoreError.self) { _ = try fixture.service.statePassphrase(for: tenant) }
        // A locked Keychain never produces a fresh passphrase.
        item.setUnreadableForTests(false)
        #expect(try item.read() == nil)
    }

    @Test("The recovery step says the passphrase can't be read, not that it's missing")
    func recoveryWording() {
        let error = SecretStoreError(status: -25308).localizedDescription
        for isTeamMode in [true, false] {
            let text = RecoveryEscrow.missingPassphraseText(isTeamMode: isTeamMode, unreadable: error)
            #expect(text.hasPrefix(error))
            #expect(text.contains("can’t be read right now"))
            #expect(!text.contains("doesn’t have"))
            #expect(!text.contains("Enter it"))
        }
        #expect(RecoveryEscrow.missingPassphraseText(isTeamMode: false).contains("doesn’t have"))
    }
}

// Removing a tenant deletes its Keychain items first; when the Keychain
// refuses, the tenant stays and the message names the item.

@MainActor
@Suite("Removing a tenant while the Keychain refuses")
struct TenantRemovalKeychainTests {
    @Test("A refused delete keeps the tenant and says which item, and which were already deleted")
    func refusedDeleteKeepsTheTenant() async throws {
        let fixture = DeployServiceGuardTests.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let tenant = DeployServiceGuardTests.tenant("Refused")
        fixture.tenantStore.add(tenant)
        let secrets = TenantSecrets(tenantID: tenant.id)
        secrets.platformClientSecret.save("fake-client-secret")
        secrets.engineerClientID.setUndeletableForTests(true)
        defer {
            secrets.engineerClientID.setUndeletableForTests(false)
            secrets.deleteAll()
        }

        await #expect {
            try await fixture.service.removeTenant(tenant)
        } throws: { error in
            guard let refused = error as? TenantSecrets.DeletionRefused else { return false }
            return refused.item == "own client ID or username" && !refused.whileReading
                && refused.alreadyDeleted == ["client secret or password", "Jamf Protect client secret"]
        }
        #expect(fixture.tenantStore.tenant(id: tenant.id) != nil, "the tenant stays")
        #expect(try secrets.platformClientSecret.read() == nil, "items deleted before the refusal stay deleted")

        // Once the Keychain lets go, removing it again works.
        secrets.engineerClientID.setUndeletableForTests(false)
        try await fixture.service.removeTenant(tenant)
        #expect(fixture.tenantStore.tenant(id: tenant.id) == nil)
    }

    @Test("A Keychain that can't be read stops the removal before anything is deleted")
    func unreadableItemStopsBeforeAnything() async throws {
        let fixture = DeployServiceGuardTests.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let tenant = DeployServiceGuardTests.tenant("Locked")
        fixture.tenantStore.add(tenant)
        let secrets = TenantSecrets(tenantID: tenant.id)
        secrets.platformClientSecret.save("fake-client-secret")
        secrets.statePassphrase.setUnreadableForTests(true)
        defer {
            secrets.statePassphrase.setUnreadableForTests(false)
            secrets.deleteAll()
        }

        await #expect {
            try await fixture.service.removeTenant(tenant)
        } throws: { error in
            guard let refused = error as? TenantSecrets.DeletionRefused else { return false }
            return refused.item == "state passphrase" && refused.whileReading && refused.alreadyDeleted.isEmpty
        }
        #expect(fixture.tenantStore.tenant(id: tenant.id) != nil)
        #expect(try secrets.platformClientSecret.read() == "fake-client-secret", "nothing was deleted")
    }

    @Test("The refusal is shown as it is, never as a team space failure")
    func refusalWording() {
        let reading = TenantSecrets.DeletionRefused(item: "state passphrase", status: -25308, alreadyDeleted: [], whileReading: true)
        #expect(SidebarView.removalErrorText(reading) == reading.errorDescription)
        #expect(reading.errorDescription?.contains("nothing was removed") == true)
        let deleting = TenantSecrets.DeletionRefused(item: "state passphrase", status: nil, alreadyDeleted: ["client secret or password"])
        #expect(SidebarView.removalErrorText(deleting).contains("Its client secret or password was already deleted."))
    }
}
