import Foundation
import JamfDeployerCore

/// What checking, unchecking and presets do to a tenant's baseline. Each
/// rule takes the tenant as the store has it now and changes only its
/// baseline (`blockSelections`, `pendingRemovals`), so a drift check or
/// preflight that finished since the screen was drawn is kept.
nonisolated enum BaselineRules {
    /// Unchecking a block.
    enum Unchecking: Equatable {
        case removed(Tenant)
        /// Other selected blocks need it.
        case refused(String)
        /// Deployed: Remove from Tenant or Stop Managing, the user picks.
        case asksHowToRemove
    }

    /// Checks `block`, with its prerequisites first. Nil when it already is.
    static func selecting(_ block: BlockMetadata, in tenant: Tenant, catalog: LoadedCatalog) -> Tenant? {
        var updated = tenant
        let selectedIDs = Set(tenant.blockSelections.map(\.blockID))
        guard !selectedIDs.contains(block.id) else { return nil }
        // Re-selecting a block that was pending removal just cancels it.
        updated.pendingRemovals.removeAll { $0.blockID == block.id }
        for requirement in block.requires where !selectedIDs.contains(requirement) {
            if let required = catalog.block(id: requirement) {
                updated.blockSelections.append(
                    BlockSelection.defaults(for: required, catalog: catalog, selectedIDs: selectedIDs))
            }
        }
        let selectedAfter = selectedIDs.union([block.id] + block.requires)
        updated.blockSelections.append(BlockSelection.defaults(for: block, catalog: catalog, selectedIDs: selectedAfter))
        // Blocks waiting for a group or category this block creates pick
        // up their declared default now.
        for index in updated.blockSelections.indices {
            guard let other = catalog.block(id: updated.blockSelections[index].blockID) else { continue }
            adoptDefaults(of: other, into: &updated.blockSelections[index], from: block)
        }
        return updated
    }

    /// Unchecks `block`: refused while another selected block requires it;
    /// a deployed block asks how.
    static func unselecting(_ block: BlockMetadata, in tenant: Tenant, catalog: LoadedCatalog) -> Unchecking {
        let dependents = tenant.blockSelections.compactMap { catalog.block(id: $0.blockID) }
            .filter { $0.requires.contains(block.id) }
        guard dependents.isEmpty else {
            return .refused("\(dependents.map(\.name).formatted(.list(type: .and))) need\(dependents.count == 1 ? "s" : "") \(block.name) — remove \(dependents.count == 1 ? "it" : "them") first.")
        }
        if tenant.deployedBlockVersions[block.id] != nil {
            return .asksHowToRemove
        }
        var updated = tenant
        updated.blockSelections.removeAll { $0.blockID == block.id }
        return .removed(updated)
    }

    /// The deployed block leaves the baseline: its objects are deleted on
    /// the next deploy, or stay in Jamf untracked (`keepInJamf`).
    static func removing(_ blockID: String, keepInJamf: Bool, in tenant: Tenant) -> Tenant {
        var updated = tenant
        updated.blockSelections.removeAll { $0.blockID == blockID }
        updated.pendingRemovals.removeAll { $0.blockID == blockID }
        updated.pendingRemovals.append(BlockRemoval(blockID: blockID, keepInJamf: keepInJamf))
        return updated
    }

    /// A selection whose block is in no catalog on this Mac: dropped, or
    /// released when deployed (its configuration is gone, so never deleted).
    static func droppingMissing(_ blockID: String, in tenant: Tenant) -> Tenant {
        guard tenant.deployedBlockVersions[blockID] != nil else {
            var updated = tenant
            updated.blockSelections.removeAll { $0.blockID == blockID }
            return updated
        }
        return removing(blockID, keepInJamf: true, in: tenant)
    }

    /// The preset replaces the selection. Blocks the tenant's connection
    /// can't deploy are left out (`skipped`, by name); deployed blocks the
    /// preset leaves out are released, never deleted.
    static func applying(_ preset: Preset, to tenant: Tenant, catalog: LoadedCatalog,
                         supports: (String) -> Bool) -> (tenant: Tenant, skipped: [String]) {
        var updated = tenant
        let skipped = preset.blocks.filter { catalog.block(id: $0) != nil && !supports($0) }
            .map { catalog.block(id: $0)?.name ?? $0 }
        let presetBlocks = preset.blocks.filter(supports)
        let presetIDs = Set(presetBlocks)
        updated.blockSelections = presetBlocks.compactMap { blockID in
            guard let block = catalog.block(id: blockID) else { return nil }
            var selection = BlockSelection.defaults(for: block, catalog: catalog, selectedIDs: presetIDs)
            for (key, value) in preset.defaults[blockID] ?? [:] {
                selection.settings[key] = value
            }
            if let scope = preset.scopes[blockID], block.scope.kind != .none,
               let provided = ProvidedObject(reference: scope) {
                selection.providedScope = provided
            }
            if let category = preset.categories[blockID], block.acceptsCategory,
               let provided = ProvidedObject(reference: category) {
                selection.existingCategory = nil
                selection.providedCategory = provided
            }
            return selection
        }
        for blockID in tenant.deployedBlockVersions.keys where !presetIDs.contains(blockID)
            && !updated.pendingRemovals.contains(where: { $0.blockID == blockID }) {
            updated.pendingRemovals.append(BlockRemoval(blockID: blockID, keepInJamf: true))
        }
        updated.pendingRemovals.removeAll { presetIDs.contains($0.blockID) }
        return (updated, skipped)
    }

    /// Fills an unchosen scope, or the "no category" placeholder, with the
    /// block's default when `provider` is the block that creates it.
    static func adoptDefaults(of block: BlockMetadata, into selection: inout BlockSelection, from provider: BlockMetadata) {
        if block.scope.kind != .none, selection.existingScope == nil, selection.providedScope == nil,
           let provided = block.scope.default.flatMap(ProvidedObject.init(reference:)),
           provided.blockID == provider.id {
            selection.providedScope = provided
        }
        if block.acceptsCategory, selection.existingCategory == .noCategory,
           let provided = block.defaultCategory.flatMap(ProvidedObject.init(reference:)),
           provided.blockID == provider.id {
            selection.existingCategory = nil
            selection.providedCategory = provided
        }
    }
}
