import Foundation

/// One line of the engine's machine-readable output stream
/// (`tofu plan -json`, `tofu apply -json`).
///
/// Shapes verified against fixtures captured in Phase 0
/// (Fixtures/engine/*.jsonl, OpenTofu 1.13.1, ui 1.2).
public nonisolated struct EngineStreamEvent: Decodable, Sendable {
    public enum Kind: String, Decodable, Sendable {
        case version
        case log
        case diagnostic
        case plannedChange = "planned_change"
        case changeSummary = "change_summary"
        case resourceDrift = "resource_drift"
        case applyStart = "apply_start"
        case applyProgress = "apply_progress"
        case applyComplete = "apply_complete"
        case applyErrored = "apply_errored"
        case provisionStart = "provision_start"
        case provisionProgress = "provision_progress"
        case provisionComplete = "provision_complete"
        case provisionErrored = "provision_errored"
        case refreshStart = "refresh_start"
        case refreshComplete = "refresh_complete"
        case outputs
        case unknown

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .unknown
        }
    }

    /// A resource referenced by a planned change or apply hook.
    public struct ResourceAddress: Decodable, Sendable {
        public var addr: String
        public var module: String
        public var resourceType: String
        public var resourceName: String

        public enum CodingKeys: String, CodingKey {
            case addr
            case module
            case resourceType = "resource_type"
            case resourceName = "resource_name"
        }
    }

    /// Payload of `planned_change` and `resource_drift`.
    public struct Change: Decodable, Sendable {
        public var resource: ResourceAddress
        /// create, update, replace, delete, remove (forget), read, import, noop
        public var action: String
        public var reason: String?
    }

    /// Payload of apply/provision/refresh hook events.
    public struct Hook: Decodable, Sendable {
        public var resource: ResourceAddress
        public var action: String?
        public var idKey: String?
        public var idValue: String?
        public var elapsedSeconds: Double?

        public enum CodingKeys: String, CodingKey {
            case resource
            case action
            case idKey = "id_key"
            case idValue = "id_value"
            case elapsedSeconds = "elapsed_seconds"
        }
    }

    /// Payload of `change_summary`.
    public struct ChangeCounts: Decodable, Sendable {
        public var add: Int
        public var change: Int
        public var importCount: Int
        public var remove: Int
        /// Objects that leave the tenant record without being destroyed
        /// ("Stop managing").
        public var forget: Int?
        /// "plan", "apply" or "destroy".
        public var operation: String

        public enum CodingKeys: String, CodingKey {
            case add, change, remove, forget, operation
            case importCount = "import"
        }
    }

    /// Payload of `diagnostic` — errors, warnings, and the provider's
    /// impact alerts.
    public struct Diagnostic: Decodable, Sendable {
        public var severity: String
        public var summary: String
        public var detail: String?
        public var address: String?
    }

    public var type: Kind
    public var message: String
    public var level: String
    public var timestamp: String
    public var change: Change?
    public var hook: Hook?
    public var changes: ChangeCounts?
    public var diagnostic: Diagnostic?
    public var outputs: [String: JSONValue]?

    public enum CodingKeys: String, CodingKey {
        case type
        case message = "@message"
        case level = "@level"
        case timestamp = "@timestamp"
        case change
        case hook
        case changes
        case diagnostic
        case outputs
    }
}
