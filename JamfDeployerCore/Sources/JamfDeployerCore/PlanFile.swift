import Foundation

/// The structured plan produced by `tofu show -json plan.bin`.
///
/// Shapes verified against fixtures captured in Phase 0
/// (Fixtures/engine/show-plan-*.json, Fixtures/live/show-plan-*.json).
public nonisolated struct PlanFile: Decodable, Sendable {
    /// One resource-level change. `actions` maps to the user-facing labels:
    /// ["create"] Create, ["update"] Update, ["delete","create"] Replace,
    /// ["delete"] Remove, ["forget"] Stop managing, import flag → Adopt.
    public struct ResourceChange: Decodable, Sendable {
        public struct Change: Decodable, Sendable {
            public var actions: [String]
            public var before: JSONValue?
            public var after: JSONValue?
            public var afterUnknown: JSONValue?
            public var beforeSensitive: JSONValue?
            public var afterSensitive: JSONValue?
            public var replacePaths: JSONValue?
            public var importing: Importing?

            public struct Importing: Decodable, Sendable {
                public var id: String?
            }

            enum CodingKeys: String, CodingKey {
                case actions, before, after, importing
                case afterUnknown = "after_unknown"
                case beforeSensitive = "before_sensitive"
                case afterSensitive = "after_sensitive"
                case replacePaths = "replace_paths"
            }
        }

        public var address: String
        public var type: String
        public var name: String
        public var providerName: String?
        public var actionReason: String?
        public var change: Change

        public enum CodingKeys: String, CodingKey {
            case address, type, name, change
            case providerName = "provider_name"
            case actionReason = "action_reason"
        }
    }

    public var formatVersion: String
    public var terraformVersion: String?
    public var resourceChanges: [ResourceChange]?
    /// Changes detected outside the tool ("Changes made in Jamf") on a
    /// refresh-only plan.
    public var resourceDrift: [ResourceChange]?
    public var errored: Bool?

    public enum CodingKeys: String, CodingKey {
        case errored
        case formatVersion = "format_version"
        case terraformVersion = "terraform_version"
        case resourceChanges = "resource_changes"
        case resourceDrift = "resource_drift"
    }
}

nonisolated extension PlanFile.ResourceChange {
    /// Attribute-level diff between before and after, for the Preview screen.
    /// Returns top-level attribute names whose values differ.
    public var changedAttributeNames: [String] {
        guard
            let before = change.before?.objectValue,
            let after = change.after?.objectValue
        else { return [] }
        let keys = Set(before.keys).union(after.keys)
        return keys.filter { before[$0] != after[$0] }.sorted()
    }
}
