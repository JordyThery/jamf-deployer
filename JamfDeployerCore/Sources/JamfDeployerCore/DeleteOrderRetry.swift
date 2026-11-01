import Foundation

/// The engine can delete an object before it updates the objects that still
/// use it — for example when a block renames a group another block scopes
/// to. Jamf refuses such a delete, and the dependent update never runs.
/// The deploy then finishes in order: first the approved changes that are
/// not deletes, then the deletes. Every retry plan must stay within the plan
/// the user approved; anything else is left for a new preview.
public nonisolated enum DeleteOrderRetry {
    /// The failed deletes, when every operation that failed is a delete the
    /// approved plan contains and every error is a delete error. `nil`
    /// otherwise. The engine reports delete errors without an address (the
    /// object is gone from the configuration), so the failed operations come
    /// from the run's `apply_errored` events.
    public static func failedDeletes(
        events: [EngineStreamEvent],
        diagnostics: [EngineStreamEvent.Diagnostic],
        approved: PlanFile
    ) -> Set<String>? {
        let errors = diagnostics.filter { $0.severity == "error" }
        let failed = events.filter { $0.type == .applyErrored }.compactMap(\.hook)
        guard !errors.isEmpty, !failed.isEmpty else { return nil }
        let actions = actionsByAddress(approved)
        var addresses: Set<String> = []
        for hook in failed {
            let address = hook.resource.addr
            guard hook.action == "delete", actions[address] == ["delete"] else { return nil }
            addresses.insert(address)
        }
        for error in errors {
            guard error.summary.range(of: "delet", options: .caseInsensitive) != nil else { return nil }
            if let address = error.address, !addresses.contains(address) { return nil }
        }
        return addresses
    }

    /// Approved changes that are not plain deletes: the first retry phase.
    public static func nonDeleteTargets(approved: PlanFile) -> [String] {
        actionsByAddress(approved)
            .filter { $0.value != ["delete"] }
            .map(\.key)
            .sorted()
    }

    /// Whether every change in `plan` appears in the approved plan with the
    /// same actions and the same planned values. A value that differs (the
    /// object was changed in Jamf since the preview) is outside it: the
    /// deploy stops and asks for a new preview.
    public static func staysWithin(_ plan: PlanFile, approved: PlanFile) -> Bool {
        changesOutside(plan, approved: approved).isEmpty
    }

    /// The addresses whose change in `plan` isn't the approved one: not in
    /// the approved plan, other actions, or other planned values. A value
    /// the approved plan didn't know yet (an ID of an object created since,
    /// `after_unknown`) may be anything. Sorted, for logs and messages.
    public static func changesOutside(_ plan: PlanFile, approved: PlanFile) -> [String] {
        let allowed = actionsByAddress(approved)
        var approvedChanges: [String: PlanFile.ResourceChange.Change] = [:]
        for change in approved.resourceChanges ?? [] { approvedChanges[change.address] = change.change }
        var outside: [String] = []
        for change in plan.resourceChanges ?? [] {
            let actions = change.change.actions.filter { $0 != "no-op" && $0 != "read" }
            guard !actions.isEmpty else { continue }
            guard allowed[change.address] == actions, let original = approvedChanges[change.address],
                  sameValue(approved: original.after, unknown: original.afterUnknown, retry: change.change.after)
            else {
                outside.append(change.address)
                continue
            }
        }
        return outside.sorted()
    }

    /// Whether `retry` is the value the approved plan planned, where
    /// `unknown` (its `after_unknown`) marks the parts not known then.
    static func sameValue(approved: JSONValue?, unknown: JSONValue?, retry: JSONValue?) -> Bool {
        if unknown == .bool(true) { return true }
        switch (approved ?? .null, retry ?? .null) {
        case (.object(let planned), .object(let now)):
            let unknownFields: [String: JSONValue]
            if case .object(let fields) = unknown { unknownFields = fields } else { unknownFields = [:] }
            return Set(planned.keys).union(now.keys).union(unknownFields.keys).allSatisfy { key in
                sameValue(approved: planned[key], unknown: unknownFields[key], retry: now[key])
            }
        case (.array(let planned), .array(let now)):
            let unknownElements: [JSONValue]
            if case .array(let elements) = unknown { unknownElements = elements } else { unknownElements = [] }
            guard planned.count == now.count || unknownElements.count == now.count else { return false }
            return now.indices.allSatisfy { index in
                sameValue(approved: planned.indices.contains(index) ? planned[index] : nil,
                          unknown: unknownElements.indices.contains(index) ? unknownElements[index] : nil,
                          retry: now[index])
            }
        case (let planned, let now):
            return planned == now
        }
    }

    /// Whether the plan changes anything.
    public static func hasChanges(_ plan: PlanFile) -> Bool {
        !actionsByAddress(plan).isEmpty
    }

    /// The planned changes as "address: actions" lines, for logs.
    public static func actionsByAddressForDisplay(_ plan: PlanFile) -> [String] {
        actionsByAddress(plan).sorted { $0.key < $1.key }.map { "\($0.key): \($0.value.joined(separator: "+"))" }
    }

    /// Planned actions per address, without no-ops and reads.
    static func actionsByAddress(_ plan: PlanFile) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for change in plan.resourceChanges ?? [] {
            let actions = change.change.actions.filter { $0 != "no-op" && $0 != "read" }
            guard !actions.isEmpty else { continue }
            result[change.address] = actions
        }
        return result
    }
}
