import Foundation
import DeployerKit
import JamfDeployerCore

/// Shares tenant credentials with the team, end-to-end encrypted: each
/// engineer's private key stays in their Keychain, public keys live in the
/// repository, and secrets are committed only as per-recipient ciphertext.
/// Joining engineers get working tenants in one sync.
@Observable
final class TeamSecretsService {
    private let tenantStore: TenantStore
    private let gitStore: GitStoreService

    /// Engineers who published a public key, by display name.
    private(set) var publishedEngineers: [(name: String, fingerprint: String)] = []
    private(set) var sharingEnabled = false
    private(set) var lastAbsorbed: Int = 0

    init(tenantStore: TenantStore, gitStore: GitStoreService) {
        self.tenantStore = tenantStore
        self.gitStore = gitStore
    }

    // MARK: Identity

    private var identityItem: KeychainItem {
        KeychainItem(service: "be.jordythery.jamf-deployer.team-identity", account: "curve25519")
    }

    private var engineersURL: URL {
        GitStoreService.storeURL.appending(path: "team/engineers")
    }

    private var secretsURL: URL {
        GitStoreService.storeURL.appending(path: "team/secrets")
    }

    /// This Mac's identity, created on first use. The stored value is
    /// "privateKey|publicKey", both base64.
    func identity() -> TeamCrypto.Identity {
        if let stored = identityItem.load() {
            let parts = stored.split(separator: "|").map(String.init)
            if parts.count == 2 {
                return TeamCrypto.Identity(privateKey: parts[0], publicKey: parts[1])
            }
        }
        let fresh = TeamCrypto.generateIdentity()
        identityItem.save("\(fresh.privateKey)|\(fresh.publicKey)")
        return fresh
    }

    /// Publishes this engineer's public key into the team space.
    func publishIdentity(engineerName: String) async throws {
        let identity = identity()
        try FileManager.default.createDirectory(at: engineersURL, withIntermediateDirectories: true)
        let safeName = engineerName.isEmpty ? "engineer" : engineerName
            .replacingOccurrences(of: "/", with: "-")
        try Data(identity.publicKey.utf8)
            .write(to: engineersURL.appending(path: "\(safeName).pub"))
        _ = try await gitStore.commitAll(message: "Team key: \(safeName)")
        try await gitStore.push()
        refresh()
    }

    // MARK: State

    func refresh() {
        let files = (try? FileManager.default.contentsOfDirectory(at: engineersURL, includingPropertiesForKeys: nil)) ?? []
        publishedEngineers = files
            .filter { $0.pathExtension == "pub" }
            .compactMap { file in
                guard let key = try? String(contentsOf: file, encoding: .utf8) else { return nil }
                return (file.deletingPathExtension().lastPathComponent, TeamCrypto.fingerprint(publicKey: key))
            }
            .sorted { $0.name < $1.name }
        sharingEnabled = FileManager.default.fileExists(atPath: secretsURL.path)
    }

    private func allPublicKeys() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: engineersURL, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "pub" }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    // MARK: Publish and absorb

    /// Seals every tenant's credentials for every published engineer and
    /// commits the envelopes. Run after connecting tenants, and again
    /// ("grant") whenever a new engineer's key appears.
    func publishAllSecrets(engineerName: String) async throws {
        try await publishIdentity(engineerName: engineerName)
        let recipients = allPublicKeys()
        guard !recipients.isEmpty else { return }
        try FileManager.default.createDirectory(at: secretsURL, withIntermediateDirectories: true)

        var published = 0
        for tenant in tenantStore.tenants {
            let secrets = TenantSecrets(tenantID: tenant.id)
            let payload = TenantSecretPayload(
                platformClientSecret: secrets.platformClientSecret.load(),
                protectClientSecret: secrets.protectClientSecret.load(),
                statePassphrase: secrets.statePassphrase.load()
            )
            guard !payload.isEmpty else { continue }
            let envelope = try TeamCrypto.seal(
                payload: try JSONEncoder().encode(payload),
                recipientPublicKeys: recipients
            )
            let data = try JSONEncoder().encode(envelope)
            try data.write(to: secretsURL.appending(path: "\(tenant.id.uuidString).json"))
            published += 1
        }
        _ = try await gitStore.commitAll(message: "Share credentials for \(published) tenant(s) with \(recipients.count) engineer(s)")
        try await gitStore.push()
        refresh()
    }

    /// Decrypts any shared credentials this Mac is missing into the
    /// Keychain. Runs on every team sync; quiet when nothing applies.
    func absorbSecrets() {
        lastAbsorbed = 0
        guard FileManager.default.fileExists(atPath: secretsURL.path) else { return }
        let identity = identity()
        let files = (try? FileManager.default.contentsOfDirectory(at: secretsURL, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let tenantID = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  tenantStore.tenant(id: tenantID) != nil,
                  let data = try? Data(contentsOf: file),
                  let envelope = try? JSONDecoder().decode(TeamCrypto.Envelope.self, from: data),
                  let opened = try? TeamCrypto.open(envelope, identity: identity),
                  let payload = try? JSONDecoder().decode(TenantSecretPayload.self, from: opened)
            else { continue }

            let secrets = TenantSecrets(tenantID: tenantID)
            var filled = false
            if let secret = payload.platformClientSecret, secrets.platformClientSecret.load() == nil {
                secrets.platformClientSecret.save(secret)
                filled = true
            }
            if let secret = payload.protectClientSecret, secrets.protectClientSecret.load() == nil {
                secrets.protectClientSecret.save(secret)
                filled = true
            }
            if let secret = payload.statePassphrase, secrets.statePassphrase.load() == nil {
                secrets.statePassphrase.save(secret)
                filled = true
            }
            if filled { lastAbsorbed += 1 }
        }
    }

    /// Engineers whose keys exist but who can't open the current envelopes —
    /// the "needs granting" signal.
    func engineersNeedingAccess() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: secretsURL, includingPropertiesForKeys: nil)) ?? []
        guard let sample = files.first(where: { $0.pathExtension == "json" }),
              let data = try? Data(contentsOf: sample),
              let envelope = try? JSONDecoder().decode(TeamCrypto.Envelope.self, from: data)
        else { return [] }
        let addressed = Set(envelope.boxes.map(\.recipientFingerprint))
        return publishedEngineers
            .filter { !addressed.contains($0.fingerprint) }
            .map(\.name)
    }
}
