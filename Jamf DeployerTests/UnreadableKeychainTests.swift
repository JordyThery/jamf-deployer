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
