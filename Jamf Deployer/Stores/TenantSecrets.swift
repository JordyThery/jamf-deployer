import Foundation
import DeployerKit

/// The Keychain items belonging to one tenant. Service names follow the
/// `<bundle id>.<purpose>` convention; the account is the tenant's UUID.
nonisolated struct TenantSecrets: Sendable {
    private static let bundleID = "be.jordythery.jamf-deployer"
    let tenantID: UUID

    init(tenantID: UUID) {
        self.tenantID = tenantID
    }

    var platformClientSecret: KeychainItem {
        item(purpose: "platform-client-secret")
    }

    var protectClientSecret: KeychainItem {
        item(purpose: "protect-client-secret")
    }

    /// Encrypts the tenant record (OpenTofu state). Losing it makes the
    /// record unreadable, so a recovery sheet is required before the first
    /// deploy.
    var statePassphrase: KeychainItem {
        item(purpose: "state-passphrase")
    }

    /// A secret block setting, stored per tenant + block + setting key.
    func blockSetting(blockID: String, key: String) -> KeychainItem {
        KeychainItem(
            service: "\(Self.bundleID).block-setting",
            account: "\(tenantID.uuidString).\(blockID).\(key)"
        )
    }

    func deleteAll() {
        platformClientSecret.delete()
        protectClientSecret.delete()
        statePassphrase.delete()
        KeychainItem.deleteAll(service: "\(Self.bundleID).block-setting", accountPrefix: "\(tenantID.uuidString).")
    }

    private func item(purpose: String) -> KeychainItem {
        KeychainItem(
            service: "\(Self.bundleID).\(purpose)",
            account: tenantID.uuidString
        )
    }
}
