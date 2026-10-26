import Foundation
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

    private struct Item: Decodable, Sendable {
        let id: String
        let name: String
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
        let items = try await client.getDecoded([GroupItem].self, path: "/pro/v1/computer-groups",
                                             privileges: [.readSmartComputerGroups, .readStaticComputerGroups])
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
        let items = try await client.getDecoded([MobileGroupItem].self, path: "/pro/v1/mobile-device-groups",
                                             privileges: [.readSmartMobileDeviceGroups, .readStaticMobileDeviceGroups])
        return items
            .map { ComputerGroup(ref: ExistingObjectRef(id: String($0.id), name: $0.name), isSmart: $0.isSmartGroup) }
            .sorted { $0.ref.name.localizedStandardCompare($1.ref.name) == .orderedAscending }
    }

    /// Jamf Pro categories.
    static func categories(tenant: Tenant, activityLog: ActivityLog?) async throws -> [ExistingObjectRef] {
        let client = try client(for: tenant, activityLog: activityLog)
        return try await client.allPages("/pro/v1/categories", as: Item.self, pageSize: 200, privileges: [.readCategories])
            .map { ExistingObjectRef(id: $0.id, name: $0.name) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func client(for tenant: Tenant, activityLog: ActivityLog?) throws -> JamfPlatformClient {
        guard TenantSecrets(tenantID: tenant.id).platformClientSecret.load() != nil else {
            throw LookupError.missingSecret
        }
        return TenantClients.shared.client(for: tenant, activityLog: activityLog)
    }
}
