import Foundation

/// The user-facing label for one planned change.
public nonisolated enum ChangeKind: String, Sendable, CaseIterable {
    case create = "Create"
    case update = "Update"
    case replace = "Replace"
    case remove = "Remove"
    case adopt = "Adopt"
    case stopManaging = "Stop managing"
    case unchanged = "Unchanged"

    public static func from(actions: [String], importing: Bool) -> ChangeKind {
        // An import is always "Adopt" — even when the first plan would also
        // change attributes (the diffs are shown on the Adopt row).
        if importing { return .adopt }
        switch Set(actions) {
        case ["create"]: return .create
        case ["update"]: return .update
        case ["delete", "create"]: return .replace
        case ["delete"]: return .remove
        case ["forget"]: return .stopManaging
        default: return .unchanged
        }
    }

    /// Changes that warrant the production guard (typed tenant name).
    public var isDestructive: Bool {
        self == .remove || self == .replace
    }
}

/// One attribute-level difference, with sensitive values masked.
public nonisolated struct FieldDiff: Codable, Sendable, Identifiable, Equatable {
    public var id: String { path }
    public var path: String
    public var before: String
    public var after: String
    /// The new value in block-setting encoding (primitives only), enabling
    /// "Keep this change" to write it back into a bound setting.
    public var rawAfter: String?

    public init(path: String, before: String, after: String, rawAfter: String? = nil) {
        self.path = path
        self.before = before
        self.after = after
        self.rawAfter = rawAfter
    }
}

/// One object in the preview.
public nonisolated struct ObjectChange: Sendable, Identifiable {
    public var id: String { address }
    public var address: String
    public var resourceType: String
    /// Human name pulled from the planned values where available.
    public var displayName: String
    public var kind: ChangeKind
    public var fieldDiffs: [FieldDiff]
    /// Impact alerts and other diagnostics attached to this object.
    public var notes: [String]
}

/// Changes grouped by building block for the Preview screen.
public nonisolated struct BlockChangeGroup: Sendable, Identifiable {
    public var id: String { blockID }
    public var blockID: String
    public var blockName: String
    public var changes: [ObjectChange]
}

public nonisolated struct PreviewSummary: Sendable {
    public var groups: [BlockChangeGroup]
    public var counts: [ChangeKind: Int]
    public var hasDestructiveChanges: Bool
    /// Warnings not tied to one object.
    public var generalNotes: [String]

    public var isEmpty: Bool {
        counts.filter { $0.key != .unchanged }.values.reduce(0, +) == 0
    }
}

/// Builds the Preview screen's model from `tofu show -json` output plus the
/// diagnostics collected from the plan stream.
public nonisolated enum PreviewBuilder {
    public static func build(
        plan: PlanFile,
        diagnostics: [EngineStreamEvent.Diagnostic],
        blockNames: [String: String]
    ) -> PreviewSummary {
        var groupsByBlock: [String: [ObjectChange]] = [:]
        var counts: [ChangeKind: Int] = [:]
        var generalNotes: [String] = []

        var notesByAddress: [String: [String]] = [:]
        for diagnostic in diagnostics {
            if let address = diagnostic.address {
                notesByAddress[address, default: []].append(diagnostic.summary)
            } else if diagnostic.severity == "warning" {
                generalNotes.append(diagnostic.summary)
            }
        }

        for change in plan.resourceChanges ?? [] {
            let kind = ChangeKind.from(
                actions: change.change.actions,
                importing: change.change.importing != nil
            )
            if kind == .unchanged, change.change.actions != ["no-op"] { continue }
            counts[kind, default: 0] += 1
            if kind == .unchanged { continue }

            let blockID = moduleID(of: change.address) ?? "tenant"
            let adoptsWithChanges = kind == .adopt && change.change.actions.contains("update")
            let diffs = kind == .update || kind == .replace || adoptsWithChanges
                ? fieldDiffs(for: change)
                : []

            groupsByBlock[blockID, default: []].append(ObjectChange(
                address: change.address,
                resourceType: change.type,
                displayName: displayName(for: change),
                kind: kind,
                fieldDiffs: diffs,
                notes: notesByAddress[change.address] ?? []
            ))
        }

        let groups = groupsByBlock
            .map { blockID, changes in
                BlockChangeGroup(
                    blockID: blockID,
                    blockName: blockNames[blockID] ?? blockID,
                    changes: changes.sorted { $0.address < $1.address }
                )
            }
            .sorted { $0.blockName < $1.blockName }

        return PreviewSummary(
            groups: groups,
            counts: counts,
            hasDestructiveChanges: counts.keys.contains { $0.isDestructive && counts[$0, default: 0] > 0 },
            generalNotes: generalNotes
        )
    }

    /// "module.filevault.jamfplatform_pro_policy.enable" → "filevault"
    static func moduleID(of address: String) -> String? {
        let parts = address.split(separator: ".")
        guard parts.count >= 2, parts[0] == "module" else { return nil }
        return String(parts[1]).replacingOccurrences(of: "_", with: "-")
    }

    static func displayName(for change: PlanFile.ResourceChange) -> String {
        let values = change.change.after?.objectValue ?? change.change.before?.objectValue
        if let name = values?["name"]?.stringValue { return name }
        if let name = values?["display_name"]?.stringValue { return name }
        if let name = values?["title"]?.stringValue { return name }
        if let general = values?["general"]?.objectValue,
           let name = general["name"]?.stringValue { return name }
        return change.name
    }

    static func fieldDiffs(for change: PlanFile.ResourceChange) -> [FieldDiff] {
        guard
            let before = change.change.before?.objectValue,
            let after = change.change.after?.objectValue
        else { return [] }

        let sensitiveBefore = change.change.beforeSensitive?.objectValue ?? [:]
        let sensitiveAfter = change.change.afterSensitive?.objectValue ?? [:]
        let unknown = change.change.afterUnknown?.objectValue ?? [:]

        var diffs: [FieldDiff] = []
        for key in Set(before.keys).union(after.keys).sorted() {
            let old = before[key] ?? .null
            let isUnknown = unknown[key]?.boolValue == true
            let new = after[key] ?? .null
            if !isUnknown && old == new { continue }

            let maskedOld = sensitiveBefore[key]?.boolValue == true ? "••••••" : old.displayText
            let maskedNew: String
            if sensitiveAfter[key]?.boolValue == true {
                maskedNew = "••••••"
            } else if isUnknown {
                maskedNew = "(decided during deploy)"
            } else {
                maskedNew = new.displayText
            }
            diffs.append(FieldDiff(path: key, before: maskedOld, after: maskedNew))
        }
        return diffs
    }
}
