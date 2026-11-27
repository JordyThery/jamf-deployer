import Foundation

/// The user-facing label for one planned change.
public nonisolated enum ChangeKind: String, Sendable, CaseIterable {
    case create = "Create"
    case update = "Update"
    case replace = "Replace"
    case remove = "Remove"
    case adopt = "Adopt"
    case stopManaging = "Stop managing"
    /// An action set this app doesn't know. Shown as its own row and
    /// treated as destructive until the app learns what it means.
    case unknown = "Unknown change"
    case unchanged = "Unchanged"

    /// The kind follows the engine's actions first; an import only adds to
    /// them. An import that keeps the object (no-op, or update: the diffs
    /// are shown on the Adopt row) is "Adopt"; an import the engine can only
    /// finish by deleting and recreating the object is "Replace".
    public static func from(actions: [String], importing: Bool) -> ChangeKind {
        switch Set(actions) {
        case ["no-op"]: return importing ? .adopt : .unchanged
        case ["update"]: return importing ? .adopt : .update
        case ["create"]: return .create
        case ["delete", "create"]: return .replace
        case ["delete"]: return .remove
        case ["forget"]: return .stopManaging
        // A data source read during the deploy changes nothing in Jamf.
        case ["read"]: return .unchanged
        default: return .unknown
        }
    }

    /// Changes that warrant the production guard (typed tenant name) and
    /// keep Deploy off the Return key.
    public var isDestructive: Bool {
        self == .remove || self == .replace || self == .unknown
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
    /// The change also imports (adopts) the object, whatever its kind.
    public var importing: Bool
    /// The engine's actions, for an `unknown` change.
    public var actions: [String]

    public init(address: String, resourceType: String, displayName: String, kind: ChangeKind,
                fieldDiffs: [FieldDiff] = [], notes: [String] = [], importing: Bool = false, actions: [String] = []) {
        self.address = address
        self.resourceType = resourceType
        self.displayName = displayName
        self.kind = kind
        self.fieldDiffs = fieldDiffs
        self.notes = notes
        self.importing = importing
        self.actions = actions
    }

    /// Why this row needs a second look, or nil.
    public var caution: String? {
        switch kind {
        case .replace where importing:
            "Adopting this object deletes it in Jamf and creates it again: it gets a new Jamf ID, and what Jamf keeps with the old one (such as logs) is lost."
        case .unknown:
            "The engine planned an action this app doesn’t recognize (\(actions.joined(separator: ", "))). Treat it like a removal and check it before deploying."
        default:
            nil
        }
    }
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

        // A warning can repeat many times, for one object (a deprecated
        // attribute per setting) or for many: each is shown once, with how
        // often it came.
        var general: [String] = []
        var notesByAddress: [String: [String]] = [:]
        for diagnostic in diagnostics {
            if let address = diagnostic.address {
                notesByAddress[address, default: []].append(diagnostic.summary)
            } else if diagnostic.severity == "warning" {
                general.append(diagnostic.summary)
            }
        }
        generalNotes = Self.grouped(general)
        notesByAddress = notesByAddress.mapValues(Self.grouped)

        for change in plan.resourceChanges ?? [] {
            let importing = change.change.importing != nil
            let kind = ChangeKind.from(actions: change.change.actions, importing: importing)
            if kind == .unchanged, change.change.actions != ["no-op"] { continue }
            counts[kind, default: 0] += 1
            if kind == .unchanged { continue }

            let blockID = moduleID(of: change.address) ?? "tenant"
            let adoptsWithChanges = kind == .adopt && change.change.actions.contains("update")
            let diffs = kind == .update || kind == .replace || kind == .unknown || adoptsWithChanges
                ? fieldDiffs(for: change)
                : []

            groupsByBlock[blockID, default: []].append(ObjectChange(
                address: change.address,
                resourceType: change.type,
                displayName: displayName(for: change),
                kind: kind,
                fieldDiffs: diffs,
                notes: notesByAddress[change.address] ?? [],
                importing: importing,
                actions: change.change.actions
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

    /// Each note once, in first-seen order, with "(N times)" when it repeats.
    static func grouped(_ notes: [String]) -> [String] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for note in notes {
            if counts[note] == nil { order.append(note) }
            counts[note, default: 0] += 1
        }
        return order.map { note in
            let count = counts[note] ?? 1
            return count > 1 ? "\(note) (\(count) times)" : note
        }
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
            // An unset list and an empty one mean the same (as in drift).
            if !isUnknown && old.isNullOrEmptyList && new.isNullOrEmptyList { continue }

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
