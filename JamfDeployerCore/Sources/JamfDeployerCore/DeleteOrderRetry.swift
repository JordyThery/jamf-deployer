import Foundation

/// The engine can delete an object before it updates the objects that still
/// use it — for example when a block renames a group another block scopes
/// to. Jamf refuses such a delete, and the dependent update never runs.
/// The deploy then finishes in order: first the approved changes that are
/// not deletes, then the deletes. Every retry plan must stay within the plan
/// the user approved; anything else is left for a new preview.
public nonisolated enum DeleteOrderRetry {
    /// The failed deletes, when every error of the run is a delete the
    /// approved plan contains. `nil` when any other error occurred.
    public static func failedDeletes(
        diagnostics: [EngineStreamEvent.Diagnostic],
        approved: PlanFile
    ) -> Set<String>? {
        let errors = diagnostics.filter { $0.severity == "error" }
        guard !errors.isEmpty else { return nil }
        let actions = actionsByAddress(approved)
        var addresses: Set<String> = []
        for error in errors {
            guard let address = error.address,
                  actions[address] == ["delete"],
                  error.summary.range(of: "delet", options: .caseInsensitive) != nil
            else { return nil }
            addresses.insert(address)
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

    /// Whether every change in `plan` appears, with the same actions, in the
    /// approved plan.
    public static func staysWithin(_ plan: PlanFile, approved: PlanFile) -> Bool {
        let allowed = actionsByAddress(approved)
        return actionsByAddress(plan).allSatisfy { allowed[$0.key] == $0.value }
    }

    /// Whether the plan changes anything.
    public static func hasChanges(_ plan: PlanFile) -> Bool {
        !actionsByAddress(plan).isEmpty
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
