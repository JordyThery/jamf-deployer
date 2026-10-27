import Foundation
import JTKit

/// One of the app's Keychain items, read and written through JTKit's
/// `KeychainSecretStore`. New items are created "when unlocked" without a
/// label, as DeployerKit's `KeychainItem` did, so every existing item keeps
/// being found under the same service and account.
///
/// Saving an empty value deletes the item. Every save or delete of a
/// tenant's item (account = tenant UUID) drops that tenant's API client, so
/// the next request signs in with what is saved now.
///
/// A demo tenant's items (account in JTKit's fake range) never reach the
/// Keychain: they live in `DemoSecretVault` for the launch.
nonisolated struct KeychainItem: Sendable {
    let service: String
    let account: String

    init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    private var store: KeychainSecretStore {
        KeychainSecretStore(service: service, accessibility: .whenUnlocked)
    }

    func load() -> String? {
        if DemoSecretVault.keepsInMemory(account: account) { return DemoSecretVault.load(service: service, account: account) }
        return store.secret(for: account)
    }

    /// Saves the value, replacing any existing one; an empty value deletes
    /// the item (and counts as saved, as before).
    @discardableResult
    func save(_ value: String) -> Bool {
        guard !value.isEmpty else {
            delete()
            return true
        }
        if DemoSecretVault.keepsInMemory(account: account) {
            DemoSecretVault.save(value, service: service, account: account)
            TenantClients.shared.secretChanged(account: account)
            return true
        }
        let saved = store.setSecret(value, for: account)
        TenantClients.shared.secretChanged(account: account)
        return saved
    }

    func delete() {
        if DemoSecretVault.keepsInMemory(account: account) {
            DemoSecretVault.save(nil, service: service, account: account)
        } else {
            store.setSecret(nil, for: account)
        }
        TenantClients.shared.secretChanged(account: account)
    }

    /// Deletes every item of `service` whose account starts with `prefix`.
    static func deleteAll(service: String, accountPrefix prefix: String) {
        if DemoSecretVault.keepsInMemory(account: prefix) {
            DemoSecretVault.deleteAll(service: service, accountPrefix: prefix)
            return
        }
        KeychainSecretStore(service: service, accessibility: .whenUnlocked).deleteSecrets(withAccountPrefix: prefix)
    }
}

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

    /// Block ID under which the adopted configuration's sensitive values
    /// are stored. No block can have it: block IDs start with a letter or digit.
    static let adoptedBlockID = "_adopted"

    /// A sensitive value of the tenant's adopted configuration (one of the
    /// variables in `adopted/adopted_sensitive_variables.tf`).
    func adoptedVariable(_ name: String) -> KeychainItem {
        blockSetting(blockID: Self.adoptedBlockID, key: name)
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

    fileprivate static func service(purpose: String) -> String {
        "\(bundleID).\(purpose)"
    }

    /// The Keychain items Settings › Connections reads and writes: the same
    /// items as `platformClientSecret` and `protectClientSecret` (account =
    /// tenant UUID, created "when unlocked" without a label). A change made
    /// there drops the tenant's API client too.
    static var connectionSecrets: [ConnectionSecretKind: SecretLocation] {
        [
            .main: SecretLocation(store: ReportingSecretStore(base: KeychainSecretStore(
                service: service(purpose: "platform-client-secret"), accessibility: .whenUnlocked))),
            .protect: SecretLocation(store: ReportingSecretStore(base: KeychainSecretStore(
                service: service(purpose: "protect-client-secret"), accessibility: .whenUnlocked))),
        ]
    }
}

extension TenantSecrets {
    /// Settings › Connections in a sandbox run: the same items, kept in
    /// memory (`DemoSecretVault`) instead of the Keychain.
    static var sandboxConnectionSecrets: [ConnectionSecretKind: SecretLocation] {
        [
            .main: SecretLocation(store: VaultSecretStore(service: service(purpose: "platform-client-secret"))),
            .protect: SecretLocation(store: VaultSecretStore(service: service(purpose: "protect-client-secret"))),
        ]
    }
}

/// A secret store on the in-memory vault, for a sandbox run.
nonisolated struct VaultSecretStore: SecretStore {
    let service: String

    func secret(for account: String) -> String? {
        DemoSecretVault.load(service: service, account: account)
    }

    @discardableResult
    func setSecret(_ secret: String?, for account: String) -> Bool {
        DemoSecretVault.save(secret, service: service, account: account)
        TenantClients.shared.secretChanged(account: account)
        return true
    }
}

/// A secret store that tells the tenant clients about every change, so a
/// secret edited in Settings › Connections is used at the next request.
nonisolated struct ReportingSecretStore: SecretStore {
    let base: KeychainSecretStore
    var clients: TenantClients = .shared

    func secret(for account: String) -> String? {
        base.secret(for: account)
    }

    @discardableResult
    func setSecret(_ secret: String?, for account: String) -> Bool {
        let saved = base.setSecret(secret, for: account)
        clients.secretChanged(account: account)
        return saved
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
