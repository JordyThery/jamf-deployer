import Foundation

/// One object changed outside the app ("Changes made in Jamf"), with a
/// field-level diff. Persisted into tenant.json so the dashboard can show
/// drift without re-checking.
public nonisolated struct DriftedObject: Codable, Sendable, Identifiable, Equatable {
    public var address: String
    /// The owning block's catalog ID ("tenant" for adopted objects).
    public var blockID: String
    /// The owning block's display name.
    public var blockName: String
    public var resourceType: String
    public var displayName: String
    public var fields: [FieldDiff]
    /// True when every changed field is one Jamf maintains itself
    /// (computed values like `category_name` or `profile_uuid`) — shown as
    /// informational, not actionable drift.
    public var isComputedOnly: Bool

    public var id: String { address }
}

/// The outcome of one "check for changes" run.
public nonisolated struct DriftReport: Codable, Sendable, Equatable {
    public var date: Date
    public var objects: [DriftedObject]

    /// Drift that needs a decision (computed-only noise excluded).
    public var actionableObjects: [DriftedObject] {
        objects.filter { !$0.isComputedOnly }
    }

    public init(date: Date, objects: [DriftedObject]) {
        self.date = date
        self.objects = objects
    }
}

/// Builds a drift report from a refresh-only plan.
public nonisolated enum DriftReportBuilder {
    /// Attribute paths Jamf maintains itself. Changes limited to these are
    /// echoes of other changes (or server-side housekeeping), not something
    /// an admin did that needs reverting.
    static let computedAttributePaths: Set<String> = [
        "category_name",
        "site_name",
        "general.category_name",
        "general.site_name",
        "self_service.categories[].name",
        "general.trigger",
        "profile_uuid",
        "profile_url",
        "prestage_installed_profile_ids",
        "version_lock",
        "member_count",
        "selected_version",
        "latest_available_version",
        "version_removed",
        "title_available_in_ais",
        "cloud_transfer_status",
        "last_updated_at",
        "update_available",
        "deployment_state",
        "updated",
    ]

    /// Matches a field path against the computed list with list positions
    /// generalized: `self_service.categories[2].name` → `self_service.categories[].name`.
    static func isComputed(_ path: String) -> Bool {
        computedAttributePaths.contains(path.replacing(/\[\d+\]/, with: "[]"))
    }

    public static func build(plan: PlanFile, blockNames: [String: String]) -> DriftReport {
        var objects: [DriftedObject] = []
        for drifted in plan.resourceDrift ?? [] {
            let fields = deepFieldDiffs(
                before: drifted.change.before,
                after: drifted.change.after,
                beforeSensitive: drifted.change.beforeSensitive,
                afterSensitive: drifted.change.afterSensitive
            )
            guard !fields.isEmpty else { continue }
            let blockID = PreviewBuilder.moduleID(of: drifted.address) ?? "tenant"
            objects.append(DriftedObject(
                address: drifted.address,
                blockID: blockID,
                blockName: blockNames[blockID] ?? blockID,
                resourceType: drifted.type,
                displayName: PreviewBuilder.displayName(for: drifted),
                fields: fields,
                isComputedOnly: fields.allSatisfy { isComputed($0.path) }
            ))
        }
        return DriftReport(date: .now, objects: objects)
    }

    /// Attribute diffs that descend into nested objects (two levels), so a
    /// policy's `general.category_name` reads as exactly that instead of an
    /// opaque "general changed".
    static func deepFieldDiffs(
        before: JSONValue?,
        after: JSONValue?,
        beforeSensitive: JSONValue? = nil,
        afterSensitive: JSONValue? = nil,
        prefix: String = "",
        depth: Int = 0
    ) -> [FieldDiff] {
        guard let beforeObject = before?.objectValue, let afterObject = after?.objectValue else {
            return []
        }
        let sensitiveBefore = beforeSensitive?.objectValue ?? [:]
        let sensitiveAfter = afterSensitive?.objectValue ?? [:]

        var diffs: [FieldDiff] = []
        for key in Set(beforeObject.keys).union(afterObject.keys).sorted() {
            let old = beforeObject[key] ?? .null
            let new = afterObject[key] ?? .null
            // An unset list and an empty one mean the same: some engine
            // plugins read back [] for lists the configuration left out.
            guard old != new, !(old.isNullOrEmptyList && new.isNullOrEmptyList) else { continue }
            let path = prefix.isEmpty ? key : "\(prefix).\(key)"
            // A mask of `true` covers the whole value, nested fields included.
            let wholeSensitive = sensitiveBefore[key]?.boolValue == true || sensitiveAfter[key]?.boolValue == true

            // Recurse into nested objects so the exact field is named.
            if !wholeSensitive, depth < 3, old.objectValue != nil, new.objectValue != nil {
                diffs.append(contentsOf: deepFieldDiffs(
                    before: old,
                    after: new,
                    beforeSensitive: sensitiveBefore[key],
                    afterSensitive: sensitiveAfter[key],
                    prefix: path,
                    depth: depth + 1
                ))
                continue
            }

            // Same-length object arrays diff element-wise, so a change
            // inside a blueprint's component list names its exact field.
            // Both sides must be all objects: an element turning into null
            // or a string falls through to the leaf diff below.
            if !wholeSensitive, depth < 3,
               case .array(let oldItems) = old,
               case .array(let newItems) = new,
               oldItems.count == newItems.count,
               oldItems.allSatisfy({ $0.objectValue != nil }),
               newItems.allSatisfy({ $0.objectValue != nil }) {
                // Sensitivity masks mirror the value: one mask per element.
                func elementMask(_ mask: JSONValue?, _ index: Int) -> JSONValue? {
                    guard case .array(let masks)? = mask, index < masks.count else { return nil }
                    return masks[index]
                }
                for (index, pair) in zip(oldItems, newItems).enumerated() where pair.0 != pair.1 {
                    diffs.append(contentsOf: deepFieldDiffs(
                        before: pair.0,
                        after: pair.1,
                        beforeSensitive: elementMask(sensitiveBefore[key], index),
                        afterSensitive: elementMask(sensitiveAfter[key], index),
                        prefix: "\(path)[\(index)]",
                        depth: depth + 1
                    ))
                }
                continue
            }

            let maskedOld = wholeSensitive ? "••••••" : old.displayText
            let maskedNew = wholeSensitive ? "••••••" : new.displayText
            diffs.append(FieldDiff(
                path: path,
                before: maskedOld,
                after: maskedNew,
                rawAfter: wholeSensitive ? nil : new.settingValue
            ))
        }
        return diffs
    }
}
