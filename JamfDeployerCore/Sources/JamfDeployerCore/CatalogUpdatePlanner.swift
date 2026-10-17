import Foundation

/// Compares two checkouts of a catalog source (the tenant's pinned tag and a
/// newer one) and lists the per-block updates a tenant can opt into.
public nonisolated enum CatalogUpdatePlanner {
    public struct BlockUpdate: Sendable, Identifiable {
        public var blockID: String
        public var name: String
        public var fromVersion: String
        public var toVersion: String
        public var summary: String

        public var id: String { blockID }
    }

    /// Updates relevant to the given selected block IDs. Blocks whose
    /// version is unchanged between the tags are omitted.
    public static func plan(
        current: LoadedCatalog,
        candidate: LoadedCatalog,
        selectedBlockIDs: [String]
    ) -> [BlockUpdate] {
        selectedBlockIDs.compactMap { blockID in
            guard let now = current.block(id: blockID),
                  let next = candidate.block(id: blockID),
                  now.version != next.version
            else { return nil }
            return BlockUpdate(
                blockID: blockID,
                name: next.name,
                fromVersion: now.version,
                toVersion: next.version,
                summary: next.summary
            )
        }
        .sorted { $0.name < $1.name }
    }
}
