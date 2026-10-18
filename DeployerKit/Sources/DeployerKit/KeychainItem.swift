import Foundation
import Security

/// One generic-password item in the login Keychain.
///
/// Convention: `service` is `<bundle id>.<purpose>` and `account` names the specific
/// credential (for per-tenant secrets, the tenant's UUID string).
public nonisolated struct KeychainItem: Sendable {
    public let service: String
    public let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    public func load() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Saves the value, replacing any existing one. An empty value deletes
    /// the item. Never synchronized to iCloud.
    @discardableResult
    public func save(_ value: String) -> Bool {
        guard !value.isEmpty else {
            delete()
            return true
        }
        let data = Data(value.utf8)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let update: [CFString: Any] = [kSecValueData: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData] = data
            add[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlocked
            status = SecItemAdd(add as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    /// Deletes every item of `service` whose account starts with `prefix`.
    public static func deleteAll(service: String, accountPrefix prefix: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnAttributes: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[CFString: Any]] else { return }
        for item in items {
            guard let account = item[kSecAttrAccount] as? String, account.hasPrefix(prefix) else { continue }
            KeychainItem(service: service, account: account).delete()
        }
    }

    public func delete() {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
