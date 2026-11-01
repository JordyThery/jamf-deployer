import Foundation

/// A rollout's tenants in order: ring, then name. Frozen at Start Rollout,
/// so a team sync that renames or removes a tenant mid-rollout can't
/// reorder it: every step, outcome and embedded preview stays keyed on the
/// same tenant IDs.
nonisolated struct RolloutQueue: Equatable, Sendable {
    /// One tenant in the setup list.
    struct Entry: Identifiable, Equatable, Sendable {
        var id: UUID
        var include: Bool
        var ring: Int
    }

    /// One tenant's turn.
    struct Step: Identifiable, Equatable, Sendable {
        var id: UUID
        var ring: Int
    }

    /// What follows a finished step.
    enum Next: Equatable, Sendable {
        case start(Int)
        case pause(next: Int)
        case finished
    }

    let steps: [Step]

    /// The included entries, by ring, then by name as shown now.
    init(_ entries: [Entry], name: (UUID) -> String) {
        steps = entries.filter(\.include)
            .map { (step: Step(id: $0.id, ring: $0.ring), name: name($0.id)) }
            .sorted { lhs, rhs in
                if lhs.step.ring != rhs.step.ring { return lhs.step.ring < rhs.step.ring }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            .map(\.step)
    }

    var count: Int { steps.count }
    var isEmpty: Bool { steps.isEmpty }
    var ringCount: Int { Set(steps.map(\.ring)).count }

    subscript(index: Int) -> Step { steps[index] }

    /// After step `index`: the next tenant, a pause before a new ring, or
    /// the end.
    func next(after index: Int, pauseBetweenRings: Bool) -> Next {
        let next = index + 1
        guard next < steps.count else { return .finished }
        if pauseBetweenRings && steps[next].ring != steps[index].ring {
            return .pause(next: next)
        }
        return .start(next)
    }
}
