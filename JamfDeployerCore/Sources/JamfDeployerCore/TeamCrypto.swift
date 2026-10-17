import Foundation
import CryptoKit

/// End-to-end encryption for team secrets: each engineer holds a Curve25519
/// identity (private key never leaves their Keychain), and secrets committed
/// to the team repository are sealed per recipient — the repository only
/// ever carries ciphertext.
///
/// Scheme per recipient (ECIES): ephemeral X25519 key agreement with the
/// recipient's public key → HKDF-SHA256 → ChaCha20-Poly1305 over the payload.
public nonisolated enum TeamCrypto {
    public struct Identity: Sendable {
        /// Base64 raw representations.
        public var privateKey: String
        public var publicKey: String

        public init(privateKey: String, publicKey: String) {
            self.privateKey = privateKey
            self.publicKey = publicKey
        }
    }

    /// One sealed copy of the payload, addressed to one engineer.
    public struct RecipientBox: Codable, Sendable {
        public var recipientFingerprint: String
        public var ephemeralPublicKey: String
        public var ciphertext: String
    }

    /// The committed envelope: the same payload sealed for every engineer.
    public struct Envelope: Codable, Sendable {
        public var version: Int
        public var updatedAt: Date
        public var boxes: [RecipientBox]

        public init(version: Int = 1, updatedAt: Date = .now, boxes: [RecipientBox]) {
            self.version = version
            self.updatedAt = updatedAt
            self.boxes = boxes
        }
    }

    public enum CryptoError: LocalizedError {
        case invalidKey
        case notAddressedToThisIdentity
        case decryptionFailed

        public var errorDescription: String? {
            switch self {
            case .invalidKey:
                "The team encryption key is malformed."
            case .notAddressedToThisIdentity:
                "These credentials are not shared with this Mac yet. Ask a teammate to grant access."
            case .decryptionFailed:
                "The shared credentials could not be decrypted."
            }
        }
    }

    static let hkdfInfo = Data("jamf-deployer-team-secrets-v1".utf8)

    public static func generateIdentity() -> Identity {
        let key = Curve25519.KeyAgreement.PrivateKey()
        return Identity(
            privateKey: key.rawRepresentation.base64EncodedString(),
            publicKey: key.publicKey.rawRepresentation.base64EncodedString()
        )
    }

    /// Short identifier for a public key, used as the box address and shown
    /// in the UI next to engineer names.
    public static func fingerprint(publicKey: String) -> String {
        guard let data = Data(base64Encoded: publicKey) else { return "invalid" }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.prefix(16).joined()
    }

    /// Seals the payload for every recipient public key.
    public static func seal(payload: Data, recipientPublicKeys: [String]) throws -> Envelope {
        var boxes: [RecipientBox] = []
        for recipient in recipientPublicKeys {
            guard let keyData = Data(base64Encoded: recipient),
                  let publicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: keyData)
            else { throw CryptoError.invalidKey }

            let ephemeral = Curve25519.KeyAgreement.PrivateKey()
            let shared = try ephemeral.sharedSecretFromKeyAgreement(with: publicKey)
            let symmetricKey = shared.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: keyData,
                sharedInfo: hkdfInfo,
                outputByteCount: 32
            )
            let sealed = try ChaChaPoly.seal(payload, using: symmetricKey)
            boxes.append(RecipientBox(
                recipientFingerprint: fingerprint(publicKey: recipient),
                ephemeralPublicKey: ephemeral.publicKey.rawRepresentation.base64EncodedString(),
                ciphertext: sealed.combined.base64EncodedString()
            ))
        }
        return Envelope(boxes: boxes)
    }

    /// Opens the envelope with this engineer's identity.
    public static func open(_ envelope: Envelope, identity: Identity) throws -> Data {
        guard let privateData = Data(base64Encoded: identity.privateKey),
              let privateKey = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateData)
        else { throw CryptoError.invalidKey }

        let myFingerprint = fingerprint(publicKey: identity.publicKey)
        guard let box = envelope.boxes.first(where: { $0.recipientFingerprint == myFingerprint }) else {
            throw CryptoError.notAddressedToThisIdentity
        }
        guard let ephemeralData = Data(base64Encoded: box.ephemeralPublicKey),
              let ephemeralKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephemeralData),
              let ciphertext = Data(base64Encoded: box.ciphertext),
              let sealed = try? ChaChaPoly.SealedBox(combined: ciphertext),
              let publicData = Data(base64Encoded: identity.publicKey)
        else { throw CryptoError.decryptionFailed }

        let shared = try privateKey.sharedSecretFromKeyAgreement(with: ephemeralKey)
        let symmetricKey = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: publicData,
            sharedInfo: hkdfInfo,
            outputByteCount: 32
        )
        guard let payload = try? ChaChaPoly.open(sealed, using: symmetricKey) else {
            throw CryptoError.decryptionFailed
        }
        return payload
    }
}

/// The payload carried in a tenant's secret envelope.
public nonisolated struct TenantSecretPayload: Codable, Sendable, Equatable {
    public var platformClientSecret: String?
    public var protectClientSecret: String?
    public var statePassphrase: String?

    public init(
        platformClientSecret: String? = nil,
        protectClientSecret: String? = nil,
        statePassphrase: String? = nil
    ) {
        self.platformClientSecret = platformClientSecret
        self.protectClientSecret = protectClientSecret
        self.statePassphrase = statePassphrase
    }

    public var isEmpty: Bool {
        platformClientSecret == nil && protectClientSecret == nil && statePassphrase == nil
    }
}
