import Foundation
import JamfDeployerCore

/// One connected Jamf tenant and everything the app knows about it.
/// Persisted as `tenants/<id>/tenant.json` in Application Support; secrets
/// never live here — they stay in the Keychain.
nonisolated struct Tenant: Codable, Identifiable, Sendable, Equatable {
    enum Region: String, Codable, CaseIterable, Sendable {
        case us, eu, apac

        var gatewayURL: URL {
            URL(string: "https://\(rawValue).api.jamfcloud.com")!
        }

        var displayName: String {
            switch self {
            case .us: "US"
            case .eu: "EU"
            case .apac: "APAC"
            }
        }
    }

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

    var id: UUID
    var name: String
    var region: Region
    /// OAuth client ID of the Platform API integration (not a secret).
    var clientID: String
    /// Platform environment UUID (preferred scope).
    var environmentID: String?
    /// Tenant UUID (legacy scope). Exactly one of the two IDs is used.
    var tenantID: String?
    var isProduction: Bool
    var mode: Mode

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
        isProduction: Bool
    ) {
        self.id = id
        self.name = name
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

    /// Tolerant decoding so older tenant.json files keep loading as the
    /// model grows.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Unnamed tenant"
        region = try container.decodeIfPresent(Region.self, forKey: .region) ?? .us
        clientID = try container.decodeIfPresent(String.self, forKey: .clientID) ?? ""
        environmentID = try container.decodeIfPresent(String.self, forKey: .environmentID)
        tenantID = try container.decodeIfPresent(String.self, forKey: .tenantID)
        isProduction = try container.decodeIfPresent(Bool.self, forKey: .isProduction) ?? true
        mode = try container.decodeIfPresent(Mode.self, forKey: .mode) ?? .managed
        namePrefix = try container.decodeIfPresent(String.self, forKey: .namePrefix) ?? "JD - "
        protectURL = try container.decodeIfPresent(String.self, forKey: .protectURL)
        protectClientID = try container.decodeIfPresent(String.self, forKey: .protectClientID)
        catalogPins = try container.decodeIfPresent([String: String].self, forKey: .catalogPins) ?? [:]
        blockSelections = try container.decodeIfPresent([BlockSelection].self, forKey: .blockSelections) ?? []
        day0 = try container.decodeIfPresent(Day0Status.self, forKey: .day0) ?? Day0Status()
        deployedBlockVersions = try container.decodeIfPresent([String: String].self, forKey: .deployedBlockVersions) ?? [:]
        pendingRemovals = try container.decodeIfPresent([BlockRemoval].self, forKey: .pendingRemovals) ?? []
        handOverPending = try container.decodeIfPresent(Bool.self, forKey: .handOverPending) ?? false
        selectionsBeforeHandOver = try container.decodeIfPresent([BlockSelection].self, forKey: .selectionsBeforeHandOver)
        removalsBeforeHandOver = try container.decodeIfPresent([BlockRemoval].self, forKey: .removalsBeforeHandOver)
        driftReport = try container.decodeIfPresent(DriftReport.self, forKey: .driftReport)
        acknowledgedDrift = try container.decodeIfPresent([String].self, forKey: .acknowledgedDrift) ?? []
        preflight = try container.decodeIfPresent(PreflightSnapshot.self, forKey: .preflight)
        lastDeploy = try container.decodeIfPresent(DeployRecord.self, forKey: .lastDeploy)
        lastDriftCheck = try container.decodeIfPresent(Date.self, forKey: .lastDriftCheck)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
    }
}

/// One selected building block and its non-secret settings.
/// Secret settings are referenced by Keychain key, never stored here.
nonisolated struct BlockSelection: Codable, Sendable, Equatable {
    var blockID: String
    var sourceID: String
    var settings: [String: String]
    var scope: String
    /// When set, this block stays on a specific catalog tag instead of the
    /// tenant's source pin — the per-block update opt-in.
    var sourceTag: String?
    /// An existing group in the tenant the block is scoped to, instead of a
    /// Foundation group.
    var existingScope: ExistingObjectRef?
    /// An existing category in the tenant (ID "-1" for none), instead of
    /// the Foundation category.
    var existingCategory: ExistingObjectRef?
    /// A group another selected block creates.
    var providedScope: ProvidedObject?
    /// A category another selected block creates.
    var providedCategory: ProvidedObject?

    init(blockID: String, sourceID: String = "official", settings: [String: String] = [:], scope: String = "pilot", sourceTag: String? = nil) {
        self.blockID = blockID
        self.sourceID = sourceID
        self.settings = settings
        self.scope = scope
        self.sourceTag = sourceTag
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        blockID = try container.decodeIfPresent(String.self, forKey: .blockID) ?? ""
        sourceID = try container.decodeIfPresent(String.self, forKey: .sourceID) ?? ""
        settings = try container.decodeIfPresent([String: String].self, forKey: .settings) ?? [:]
        scope = try container.decodeIfPresent(String.self, forKey: .scope) ?? "pilot"
        sourceTag = try container.decodeIfPresent(String.self, forKey: .sourceTag)
        existingScope = try container.decodeIfPresent(ExistingObjectRef.self, forKey: .existingScope)
        existingCategory = try container.decodeIfPresent(ExistingObjectRef.self, forKey: .existingCategory)
        providedScope = try container.decodeIfPresent(ProvidedObject.self, forKey: .providedScope)
        providedCategory = try container.decodeIfPresent(ProvidedObject.self, forKey: .providedCategory)
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        apnsConfirmedDate = try container.decodeIfPresent(Date.self, forKey: .apnsConfirmedDate)
        skippedSteps = try container.decodeIfPresent([String].self, forKey: .skippedSteps) ?? []
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
