import Foundation
import DeployerKit
import JTKit

/// Lists objects that already exist in a tenant, so blocks can point at
/// them instead of creating their own.
nonisolated enum ExistingObjectService {
    enum LookupError: LocalizedError {
        case missingSecret

        var errorDescription: String? {
            "The tenant's client secret or password is missing from the Keychain. Enter it on the tenant page (Update Client Secret… or Update Password…)."
        }
    }

    private struct Page: Decodable, Sendable {
        struct Item: Decodable, Sendable {
            let id: String
            let name: String
        }
        let totalCount: Int
        let results: [Item]
    }

    struct ComputerGroup: Sendable, Hashable {
        var ref: ExistingObjectRef
        var isSmart: Bool
    }

    private struct GroupItem: Decodable, Sendable {
        let id: String
        let name: String
        let smartGroup: Bool
    }

    /// Smart and static computer groups, by Jamf Pro ID.
    static func computerGroups(tenant: Tenant, activityLog: ActivityLog?) async throws -> [ComputerGroup] {
        let client = try client(for: tenant, activityLog: activityLog)
        let items = try await client.getDecoded([GroupItem].self, path: "/pro/v1/computer-groups")
        return items
            .map { ComputerGroup(ref: ExistingObjectRef(id: $0.id, name: $0.name), isSmart: $0.smartGroup) }
            .sorted { $0.ref.name.localizedStandardCompare($1.ref.name) == .orderedAscending }
    }

    private struct MobileGroupItem: Decodable, Sendable {
        let id: Int
        let name: String
        let isSmartGroup: Bool
    }

    /// Smart and static mobile device groups, by Jamf Pro ID.
    static func mobileDeviceGroups(tenant: Tenant, activityLog: ActivityLog?) async throws -> [ComputerGroup] {
        let client = try client(for: tenant, activityLog: activityLog)
        let items = try await client.getDecoded([MobileGroupItem].self, path: "/pro/v1/mobile-device-groups")
        return items
            .map { ComputerGroup(ref: ExistingObjectRef(id: String($0.id), name: $0.name), isSmart: $0.isSmartGroup) }
            .sorted { $0.ref.name.localizedStandardCompare($1.ref.name) == .orderedAscending }
    }

    /// Jamf Pro categories.
    static func categories(tenant: Tenant, activityLog: ActivityLog?) async throws -> [ExistingObjectRef] {
        let client = try client(for: tenant, activityLog: activityLog)
        return try await pagedList(path: "/pro/v1/categories", client: client)
    }

    private static func client(for tenant: Tenant, activityLog: ActivityLog?) throws -> JamfPlatformClient {
        guard let secret = TenantSecrets(tenantID: tenant.id).platformClientSecret.load() else {
            throw LookupError.missingSecret
        }
        return JamfPlatformClient(
            configuration: JamfAPIConfiguration(tenant: tenant, clientSecret: secret),
            activityLog: activityLog
        )
    }

    private static func pagedList(path: String, client: JamfPlatformClient) async throws -> [ExistingObjectRef] {
        var objects: [ExistingObjectRef] = []
        var page = 0
        while true {
            let result = try await client.getDecoded(Page.self, path: path, query: [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "page-size", value: "200"),
            ])
            objects += result.results.map { ExistingObjectRef(id: $0.id, name: $0.name) }
            if result.results.isEmpty || objects.count >= result.totalCount { break }
            page += 1
        }
        return objects.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
