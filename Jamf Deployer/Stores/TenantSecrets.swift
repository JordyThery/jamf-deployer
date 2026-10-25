import Foundation
import DeployerKit
import JTKit

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

    /// This engineer's own client ID or username, when it differs from the
    /// one in the tenant record (Team Mode: each engineer signs in with
    /// their own API client or account).
    var engineerClientID: KeychainItem {
        item(purpose: "engineer-client-id")
    }

    /// Encrypts the tenant's deployment state (OpenTofu state). Losing it
    /// makes the state unreadable, so a recovery sheet is required before
    /// the first deploy.
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
        engineerClientID.delete()
        statePassphrase.delete()
        KeychainItem.deleteAll(service: "\(Self.bundleID).block-setting", accountPrefix: "\(tenantID.uuidString).")
    }

    private func item(purpose: String) -> KeychainItem {
        KeychainItem(
            service: Self.service(purpose: purpose),
            account: tenantID.uuidString
        )
    }

    private static func service(purpose: String) -> String {
        "\(bundleID).\(purpose)"
    }

    /// The Keychain items Settings › Connections reads and writes: the same
    /// items as `platformClientSecret` and `protectClientSecret` (account =
    /// tenant UUID, created "when unlocked" without a label, as
    /// `KeychainItem` does). The other items stay app-only.
    static var connectionSecrets: [ConnectionSecretKind: SecretLocation] {
        [
            .main: SecretLocation(store: KeychainSecretStore(
                service: service(purpose: "platform-client-secret"), accessibility: .whenUnlocked)),
            .protect: SecretLocation(store: KeychainSecretStore(
                service: service(purpose: "protect-client-secret"), accessibility: .whenUnlocked)),
        ]
    }
}

/// The team space's passphrase: in Team Mode it encrypts every tenant
/// record. Shared once through the team's password manager and kept in each
/// engineer's Keychain.
nonisolated enum TeamPassphrase {
    static let item = KeychainItem(service: "be.jordythery.jamf-deployer.team", account: "state-passphrase")

    /// A new passphrase for a new team space.
    static func generate() -> String {
        Data((0..<24).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
    }
}

nonisolated extension Tenant {
    /// The client ID or username this Mac signs in with.
    var engineerClientID: String {
        TenantSecrets(tenantID: id).engineerClientID.load() ?? clientID
    }
}
