import Foundation
import JamfDeployerCore
import JTKit

/// One connected Jamf tenant and everything the app knows about it.
/// Persisted as `tenants/<id>/tenant.json` in Application Support; secrets
/// never live here — they stay in the Keychain.
nonisolated struct Tenant: Codable, Identifiable, Sendable, Equatable {
    /// JTKit's region; saved as "us", "eu" or "apac", as before.
    typealias Region = JamfRegion

    /// How the API integration is scoped. Environment is what new
    /// integrations should use; tenant scope is legacy.
    enum APIScope: String, Codable, Sendable {
        case environment
        case tenant
    }

    enum Mode: String, Codable, Sendable {
        case managed
        case handedOver
    }

    /// How a Jamf Pro API connection signs in. The client ID or username
    /// is stored in `clientID`; the secret or password is in the Keychain.
    enum JamfProAuth: String, Codable, Sendable, CaseIterable {
        case apiClient
        case userAccount
    }

    var id: UUID
    var name: String
    /// Platform API gateway or a Jamf Pro instance's own API; fixed at connect.
    var connection: ConnectionKind
    /// Jamf Pro instance URL (Jamf Pro API connections), e.g.
    /// "https://example.jamfcloud.com".
    var jamfProURL: String?
    var jamfProAuth: JamfProAuth?
    var region: Region
    /// OAuth client ID of the API integration, or the username of a Jamf
    /// Pro user account (not a secret).
    var clientID: String
    /// Platform environment UUID (preferred scope).
    var environmentID: String?
    /// Tenant UUID (legacy scope). Exactly one of the two IDs is used.
    var tenantID: String?
    var isProduction: Bool
    var mode: Mode
    /// The Terraform repository a handed-over tenant moved to (Export as
    /// Terraform), if that is how it left the app.
    var exportedTo: String?

    /// Optional Jamf Protect connection (console URL; client ID only —
    /// its secret is in the Keychain).
    var protectURL: String?
    var protectClientID: String?

    /// Prefix applied to every object name this app creates in the tenant.
    var namePrefix: String
    /// Git catalog source ID → the release tag this tenant is pinned to.
    var catalogPins: [String: String]
    /// Selected building blocks.
    var blockSelections: [BlockSelection]

    /// Manual Day 0 progress (live checks run on demand and are not stored).
    var day0: Day0Status
    /// block id → version actually deployed to the tenant.
    var deployedBlockVersions: [String: String]
    /// Blocks awaiting removal on the next deploy ("Remove from tenant" or
    /// "Stop managing").
    var pendingRemovals: [BlockRemoval]
    /// Set by Hand Over until the hand-over deploys: the next preview
    /// releases every block and adopted object, and a successful deploy
    /// archives the record.
    var handOverPending: Bool
    /// The baseline before Hand Over was prepared, restored on cancel.
    var selectionsBeforeHandOver: [BlockSelection]?
    var removalsBeforeHandOver: [BlockRemoval]?
    /// Last drift check result ("Changes made in Jamf").
    var driftReport: DriftReport?
    /// Drift the user chose to keep, keyed "address|field|value".
    var acknowledgedDrift: [String]
    /// Cached result of the last preflight run, for the fleet dashboard.
    var preflight: PreflightSnapshot?
    var lastDeploy: DeployRecord?
    var lastDriftCheck: Date?

    var createdAt: Date

    var isJamfPro: Bool { connection == .jamfPro }

    /// What identifies the connection in lists: the environment ID for
    /// Platform tenants, the instance host for Jamf Pro tenants.
    var connectionLabel: String {
        guard isJamfPro else { return scopeID }
        return jamfProURL.flatMap { URL(string: $0)?.host() } ?? jamfProURL ?? ""
    }

    var apiScope: APIScope {
        environmentID != nil ? .environment : .tenant
    }

    var scopeID: String {
        environmentID ?? tenantID ?? ""
    }

    init(
        id: UUID = UUID(),
        name: String,
        region: Region,
        clientID: String,
        environmentID: String?,
        tenantID: String? = nil,
        isProduction: Bool,
        connection: ConnectionKind = .platform,
        jamfProURL: String? = nil,
        jamfProAuth: JamfProAuth? = nil
    ) {
        self.id = id
        self.name = name
        self.connection = connection
        self.jamfProURL = jamfProURL
        self.jamfProAuth = jamfProAuth
        self.region = region
        self.clientID = clientID
        self.environmentID = environmentID
        self.tenantID = tenantID
        self.isProduction = isProduction
        self.mode = .managed
        self.namePrefix = "JD - "
        self.catalogPins = [:]
        self.blockSelections = []
        self.day0 = Day0Status()
        self.deployedBlockVersions = [:]
        self.pendingRemovals = []
        self.handOverPending = false
        self.acknowledgedDrift = []
        self.createdAt = .now
    }
}

/// One selected building block and its non-secret settings.
/// Secret settings are referenced by Keychain key, never stored here.
nonisolated struct BlockSelection: Codable, Sendable, Equatable {
    var blockID: String
    var sourceID: String
    var settings: [String: String]
    /// When set, this block stays on a specific catalog tag instead of the
    /// tenant's source pin — the per-block update opt-in.
    var sourceTag: String?
    /// An existing group in the tenant the block is scoped to.
    var existingScope: ExistingObjectRef?
    /// An existing category in the tenant (ID "-1" for none).
    var existingCategory: ExistingObjectRef?
    /// A group another selected block creates.
    var providedScope: ProvidedObject?
    /// A category another selected block creates.
    var providedCategory: ProvidedObject?

    init(blockID: String, sourceID: String = "official", settings: [String: String] = [:], sourceTag: String? = nil) {
        self.blockID = blockID
        self.sourceID = sourceID
        self.settings = settings
        self.sourceTag = sourceTag
    }

    /// A new selection of `block` with its defaults: setting defaults, and
    /// the scope or category it declares when the block providing them is
    /// among `selectedIDs`.
    static func defaults(for block: BlockMetadata, catalog: LoadedCatalog, selectedIDs: Set<String>) -> BlockSelection {
        var settings: [String: String] = [:]
        for setting in block.settings where !setting.default.isEmpty {
            settings[setting.key] = setting.default
        }
        var selection = BlockSelection(
            blockID: block.id,
            sourceID: catalog.sourceIDByBlockID[block.id] ?? "official",
            settings: settings
        )
        if block.scope.kind != .none,
           let provided = block.scope.default.flatMap(ProvidedObject.init(reference:)),
           selectedIDs.contains(provided.blockID) {
            selection.providedScope = provided
        }
        if block.acceptsCategory {
            if let provided = block.defaultCategory.flatMap(ProvidedObject.init(reference:)),
               selectedIDs.contains(provided.blockID) {
                selection.providedCategory = provided
            } else {
                selection.existingCategory = .noCategory
            }
        }
        return selection
    }
}

/// An object that already exists in the tenant, referenced by its Jamf ID.
/// The name is kept for display; the ID is what deploys use.
nonisolated struct ExistingObjectRef: Codable, Sendable, Equatable, Hashable {
    var id: String
    var name: String

    static let noCategory = ExistingObjectRef(id: "-1", name: "No category")
}

/// The dashboard-relevant outcome of the last deploy.
nonisolated struct DeployRecord: Codable, Sendable, Equatable {
    var date: Date
    var engineerName: String
    var succeeded: Int
    var failed: Int
}

/// Cached preflight results for the dashboard and tenant view.
nonisolated struct PreflightSnapshot: Codable, Sendable, Equatable {
    var date: Date
    var jamfProVersion: String?
    var allGreen: Bool
    var tenantHasContent: Bool?
    var adeTokenExpiration: String?
    var vppTokenExpiration: String?
}

/// Manually confirmed Day 0 progress. Everything detectable is detected
/// live instead of stored.
nonisolated struct Day0Status: Codable, Sendable, Equatable {
    /// The date the user confirmed the APNs certificate was set up.
    var apnsConfirmedDate: Date?
    /// Step IDs the user chose to skip.
    var skippedSteps: [String]

    init(apnsConfirmedDate: Date? = nil, skippedSteps: [String] = []) {
        self.apnsConfirmedDate = apnsConfirmedDate
        self.skippedSteps = skippedSteps
    }
}

nonisolated extension Tenant {
    /// Drift that still needs a decision: actionable and not kept.
    var outstandingDrift: [DriftedObject] {
        guard let driftReport else { return [] }
        return driftReport.actionableObjects.compactMap { object in
            var remaining = object
            remaining.fields = object.fields.filter { field in
                !acknowledgedDrift.contains("\(object.address)|\(field.path)|\(field.after)")
            }
            return remaining.fields.isEmpty ? nil : remaining
        }
    }

    var isHandedOver: Bool {
        mode == .handedOver
    }
}
