import SwiftUI
import DeployerKit
import JamfDeployerCore

/// The tenant's baseline: pick a preset or individual blocks, fill in each
/// block's settings and scope, then preview.
struct BaselineEditorView: View {
    @Environment(TenantStore.self) private var tenantStore
    @Environment(TenantDeployService.self) private var deployService

    let tenant: Tenant
    let catalog: LoadedCatalog
    /// Called after something on disk changed (a saved preset), so the
    /// owner reloads the catalog.
    var onCatalogChanged: () -> Void = {}

    @State private var expandedBlockID: String?
    @State private var isSavingPreset = false
    @State private var blockPendingRemoval: BlockMetadata?
    @State private var isCheckingUpdates = false
    @State private var presetPendingApply: Preset?
    /// Preset blocks left out because they cannot deploy through this
    /// tenant's connection.
    @State private var presetSkippedNames: [String] = []

    private var selectionIndex: [String: BlockSelection] {
        Dictionary(uniqueKeysWithValues: tenant.blockSelections.map { ($0.blockID, $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Menu("Apply a Preset", systemImage: "square.stack.3d.up") {
                    ForEach(catalog.presets) { preset in
                        Button(preset.name) {
                            if tenant.blockSelections.isEmpty { apply(preset) } else { presetPendingApply = preset }
                        }
                            .help(preset.summary)
                    }
                    if !catalog.presets.isEmpty { Divider() }
                    Button("Save Current Baseline as Preset…") { isSavingPreset = true }
                        .disabled(tenant.blockSelections.isEmpty)
                }
                .fixedSize()
                .help("Replaces the current block selection with a preset, or saves this baseline as one")
                .sheet(isPresented: $isSavingPreset) {
                    SavePresetSheet(tenant: tenant, catalog: catalog, onSaved: onCatalogChanged)
                }

                Button("Baseline Updates…", systemImage: "square.and.arrow.down.badge.clock") {
                    isCheckingUpdates = true
                }
                .help("Checks the tenant's catalog sources for newer releases, block by block")
                Spacer()
                Text("\(availableSelectionCount) of \(supportedBlockCount) blocks selected")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if !presetSkippedNames.isEmpty {
                Label("Left out of the preset: \(presetSkippedNames.joined(separator: ", ")). These blocks need \(otherConnectionName).", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(catalog.blocks) { block in
                blockRow(block)
            }

            // Selections whose block is in no followed catalog (a removed
            // source, a block deleted on disk, or a catalog not added on
            // this Mac) would fail generation — surface them with a way out.
            ForEach(missingSelections, id: \.blockID) { selection in
                HStack(alignment: .firstTextBaseline) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(selection.blockID)
                                .font(.callout.monospaced())
                            Text("Selected on this tenant, but not in any catalog this Mac follows. Add the catalog it comes from, or remove it from the baseline.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "questionmark.square.dashed")
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    // A deployed block's configuration is gone with its
                    // catalog, so it can only be released, never deleted.
                    let isDeployed = tenant.deployedBlockVersions[selection.blockID] != nil
                    Button(isDeployed ? "Stop Managing" : "Remove from Baseline", role: isDeployed ? nil : .destructive) {
                        var updated = tenant
                        updated.blockSelections.removeAll { $0.blockID == selection.blockID }
                        if isDeployed {
                            updated.pendingRemovals.removeAll { $0.blockID == selection.blockID }
                            updated.pendingRemovals.append(BlockRemoval(blockID: selection.blockID, keepInJamf: true))
                        }
                        tenantStore.update(updated)
                    }
                    .controlSize(.small)
                    .help(isDeployed
                        ? "Its objects stay in Jamf; the next deploy stops tracking them"
                        : "Removes the selection; nothing was deployed for it")
                }
                .padding(10)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .sheet(isPresented: $isCheckingUpdates) {
            BaselineUpdateSheet(tenant: tenant)
        }
        .confirmationDialog(
            "Apply “\(presetPendingApply?.name ?? "")”?",
            isPresented: Binding(
                get: { presetPendingApply != nil },
                set: { if !$0 { presetPendingApply = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Apply Preset") {
                if let preset = presetPendingApply { apply(preset) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The preset replaces the current block selection. Deployed blocks it leaves out stop being managed; their objects stay in Jamf.")
        }
        .confirmationDialog(
            "Remove “\(blockPendingRemoval?.name ?? "")” from the baseline?",
            isPresented: Binding(
                get: { blockPendingRemoval != nil },
                set: { if !$0 { blockPendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove from Tenant", role: .destructive) {
                if let block = blockPendingRemoval { confirmRemoval(block, keepInJamf: false) }
            }
            Button("Stop Managing") {
                if let block = blockPendingRemoval { confirmRemoval(block, keepInJamf: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Remove from Tenant deletes the block's objects from Jamf on the next deploy; tenant-wide settings keep their current values. Stop Managing leaves everything in Jamf untouched — the app just stops tracking it. The preview shows exactly what happens either way.")
        }
    }

    /// The first required setting that has no value yet — the same condition
    /// the generator enforces, caught here before a preview is attempted.
    private func firstMissingRequiredSetting(_ block: BlockMetadata, selection: BlockSelection?) -> BlockSetting? {
        block.settings.first { setting in
            guard setting.required, setting.type != .bool else { return false }
            if setting.type == .secret {
                let stored = TenantSecrets(tenantID: tenant.id)
                    .blockSetting(blockID: block.id, key: setting.key)
                    .load()
                return (stored ?? "").isEmpty
            }
            let value = selection?.settings[setting.key] ?? setting.default
            return value.isEmpty
        }
    }

    /// Needed object names no other selected block creates — the same
    /// check the generator enforces, surfaced before a preview is attempted.
    private func unmetDependencies(for block: BlockMetadata) -> [String] {
        block.needs.sorted(by: { $0.key < $1.key }).compactMap { depKey, names in
            let covered = Set(tenant.blockSelections
                .compactMap { catalog.block(id: $0.blockID) }
                .filter { $0.id != block.id }
                .flatMap { $0.provides[depKey] ?? [] })
            let missing = names.filter { !covered.contains($0) }
            guard !missing.isEmpty else { return nil }
            let plurals = [
                "category": "categories", "script": "scripts", "package": "packages",
                "device_group": "device groups", "extension_attribute": "extension attributes",
            ]
            let kind = plurals[depKey] ?? depKey.replacingOccurrences(of: "_", with: " ") + "s"
            return "Needs \(kind) no selected block creates: \(missing.joined(separator: ", ")). Select the block that creates them."
        }
    }

    private func supports(_ blockID: String) -> Bool {
        catalog.supports(blockID: blockID, connection: tenant.connection)
    }

    /// What blocks this tenant cannot deploy need instead.
    private var otherConnectionName: String {
        tenant.isJamfPro ? "a Jamf Platform API connection" : "a Jamf Pro API connection"
    }

    private var supportedBlockCount: Int {
        catalog.blocks.filter { supports($0.id) }.count
    }

    /// Selections that resolve to a catalog block on this Mac.
    private var availableSelectionCount: Int {
        tenant.blockSelections.filter { selection in
            catalog.blocks.contains { $0.id == selection.blockID }
        }.count
    }

    /// Selections whose block is absent from every followed catalog.
    private var missingSelections: [BlockSelection] {
        tenant.blockSelections.filter { selection in
            !catalog.blocks.contains { $0.id == selection.blockID }
        }
    }

    @ViewBuilder
    private func blockRow(_ block: BlockMetadata) -> some View {
        let selection = selectionIndex[block.id]
        let isSelected = selection != nil || block.alwaysOn
        let prerequisitesMissing = block.requires.filter { selectionIndex[$0] == nil && catalog.block(id: $0) != nil }
        let prerequisitesUnavailable = block.requires.filter { catalog.block(id: $0) == nil }
        let isSupported = supports(block.id)

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Toggle(isOn: Binding(
                    get: { isSelected },
                    set: { toggle(block, on: $0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(block.name)
                                .font(.body.weight(.medium))
                            if block.alwaysOn {
                                StatusBadge("Always on", style: .neutral)
                            }
                            if block.risk == "high" && isSelected {
                                StatusBadge("High impact", style: .warning)
                            }
                        }
                        Text(block.summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(block.alwaysOn || (!isSupported && !isSelected))

                Spacer()

                if isSelected && (block.scope.kind != .none || !block.settings.isEmpty) {
                    Button(expandedBlockID == block.id ? "Hide Settings" : "Show Settings") {
                        expandedBlockID = expandedBlockID == block.id ? nil : block.id
                    }
                    .buttonStyle(.borderless)
                }
            }

            if !isSupported {
                Label(
                    isSelected
                        ? "Needs \(otherConnectionName), and this tenant is connected through the \(tenant.isJamfPro ? "Jamf Pro API" : "Jamf Platform API"). Remove it from the baseline."
                        : "Needs \(otherConnectionName).",
                    systemImage: isSelected ? "exclamationmark.circle.fill" : "info.circle"
                )
                .font(.caption)
                .foregroundStyle(isSelected ? .orange : .secondary)
            }

            if let removal = tenant.pendingRemovals.first(where: { $0.blockID == block.id }) {
                Label(
                    removal.keepInJamf
                        ? "Will stop managing on the next deploy — objects stay in Jamf."
                        : "Will be removed from the tenant on the next deploy.",
                    systemImage: removal.keepInJamf ? "hand.raised" : "trash"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            if isSelected, let missing = prerequisitesMissing.first {
                Label("Also selects \(catalog.block(id: missing)?.name ?? missing) — this block needs it.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if isSelected, let missing = prerequisitesUnavailable.first {
                Label(
                    "Needs “\(missing)”, which no catalog on this Mac provides. Add the catalog it comes from, or remove this block.",
                    systemImage: "exclamationmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            if isSelected, let selection, let message = scopeProblem(block, selection: selection) {
                Label(message, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if isSelected, let missing = firstMissingRequiredSetting(block, selection: selection) {
                Label(
                    "“\(missing.title)” needs a value before this block can deploy — open Settings.",
                    systemImage: "exclamationmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            if isSelected {
                ForEach(unmetDependencies(for: block), id: \.self) { message in
                    Label(message, systemImage: "link.badge.plus")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if isSelected, block.capturedFromTenant == tenant.scopeID {
                Label(
                    "Captured from this tenant — its objects already exist here and deploying would create duplicates. Use Adopt Existing Configuration to manage the originals instead.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            if expandedBlockID == block.id, isSelected {
                BlockSettingsForm(
                    tenant: tenant,
                    block: block,
                    selection: selection ?? defaultSelection(for: block, selectedIDs: selectedIDs),
                    providers: providerChoices(excluding: block.id)
                )
                .padding(.leading, 22)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(isSelected ? 0.5 : 0.25), in: RoundedRectangle(cornerRadius: 8))
    }

    private func toggle(_ block: BlockMetadata, on: Bool) {
        var updated = tenant
        if on {
            guard selectionIndex[block.id] == nil else { return }
            // Re-selecting a block that was pending removal just cancels it.
            updated.pendingRemovals.removeAll { $0.blockID == block.id }
            // Pull in prerequisites first.
            for requirement in block.requires where selectionIndex[requirement] == nil {
                if let required = catalog.block(id: requirement) {
                    updated.blockSelections.append(defaultSelection(for: required, selectedIDs: selectedIDs))
                }
            }
            let selectedAfter = selectedIDs.union([block.id] + block.requires)
            let selection = defaultSelection(for: block, selectedIDs: selectedAfter)
            updated.blockSelections.append(selection)
            // Blocks waiting for a group or category this block creates pick
            // up their declared default now.
            for index in updated.blockSelections.indices {
                guard let other = catalog.block(id: updated.blockSelections[index].blockID) else { continue }
                Self.adoptDefaults(of: other, into: &updated.blockSelections[index], from: block)
            }
            tenantStore.update(updated)
            if scopeProblem(block, selection: selection) != nil {
                expandedBlockID = block.id
            }
        } else {
            // Refuse removal while another selected block requires this one.
            let dependents = updated.blockSelections.compactMap { catalog.block(id: $0.blockID) }
                .filter { $0.requires.contains(block.id) }
            guard dependents.isEmpty else { return }
            if tenant.deployedBlockVersions[block.id] != nil {
                // Deployed blocks get the Remove / Stop managing choice.
                blockPendingRemoval = block
            } else {
                updated.blockSelections.removeAll { $0.blockID == block.id }
                tenantStore.update(updated)
            }
        }
    }

    private func confirmRemoval(_ block: BlockMetadata, keepInJamf: Bool) {
        var updated = tenant
        updated.blockSelections.removeAll { $0.blockID == block.id }
        updated.pendingRemovals.removeAll { $0.blockID == block.id }
        updated.pendingRemovals.append(BlockRemoval(blockID: block.id, keepInJamf: keepInJamf))
        tenantStore.update(updated)
    }

    private var selectedIDs: Set<String> {
        Set(tenant.blockSelections.map(\.blockID))
    }

    /// A block's starting selection. Scope and category follow the block's
    /// declared defaults when the block creating them is selected too;
    /// otherwise the user picks (an existing group, no category).
    private func defaultSelection(for block: BlockMetadata, selectedIDs: Set<String>) -> BlockSelection {
        var settings: [String: String] = [:]
        for setting in block.settings where !setting.default.isEmpty {
            settings[setting.key] = setting.default
        }
        var selection = BlockSelection(
            blockID: block.id,
            sourceID: catalog.sourceIDByBlockID[block.id] ?? "official",
            settings: settings
        )
        if block.scope.kind != .none,
           let provided = block.scope.default.flatMap(ProvidedObject.init(reference:)),
           selectedIDs.contains(provided.blockID) {
            selection.providedScope = provided
        }
        if block.acceptsCategory {
            if let provided = block.defaultCategory.flatMap(ProvidedObject.init(reference:)),
               selectedIDs.contains(provided.blockID) {
                selection.providedCategory = provided
            } else {
                selection.existingCategory = .noCategory
            }
        }
        return selection
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

    /// Selected blocks that create groups or categories other blocks can use.
    private func providerChoices(excluding blockID: String) -> [BlockSettingsForm.Provider] {
        tenant.blockSelections.compactMap { catalog.block(id: $0.blockID) }
            .filter { $0.id != blockID }
            .compactMap { block in
                let groups = block.provides["device_group"] ?? []
                let categories = block.provides["category"] ?? []
                guard !groups.isEmpty || !categories.isEmpty else { return nil }
                return BlockSettingsForm.Provider(
                    blockID: block.id, blockName: block.name, groups: groups,
                    mobileGroups: block.mobileDeviceGroups, categories: categories)
            }
    }

    /// Why the block's scope or category cannot deploy yet, if so.
    private func scopeProblem(_ block: BlockMetadata, selection: BlockSelection) -> String? {
        if block.scope.kind != .none, selection.existingScope == nil, selection.providedScope == nil {
            return "Choose which group this block applies to — open Settings."
        }
        for (provided, kind) in [(selection.providedScope, "group"), (selection.providedCategory, "category")] {
            guard let provided else { continue }
            if selectionIndex[provided.blockID] == nil {
                let providerName = catalog.block(id: provided.blockID)?.name ?? provided.blockID
                return "Uses the \(kind) “\(provided.name)” from \(providerName), which is not selected. Select it, or pick another \(kind) in Settings."
            }
        }
        return nil
    }

    private func apply(_ preset: Preset) {
        var updated = tenant
        presetSkippedNames = preset.blocks.filter { catalog.block(id: $0) != nil && !supports($0) }
            .map { catalog.block(id: $0)?.name ?? $0 }
        let presetBlocks = preset.blocks.filter(supports)
        let presetIDs = Set(presetBlocks)
        updated.blockSelections = presetBlocks.compactMap { blockID in
            guard let block = catalog.block(id: blockID) else { return nil }
            var selection = defaultSelection(for: block, selectedIDs: presetIDs)
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
        // Deployed blocks the preset leaves out are released, never deleted.
        for blockID in tenant.deployedBlockVersions.keys where !presetIDs.contains(blockID)
            && !updated.pendingRemovals.contains(where: { $0.blockID == blockID }) {
            updated.pendingRemovals.append(BlockRemoval(blockID: blockID, keepInJamf: true))
        }
        updated.pendingRemovals.removeAll { presetIDs.contains($0.blockID) }
        tenantStore.update(updated)
    }
}

/// Native controls for one block's settings and scope.
struct BlockSettingsForm: View {
    @Environment(TenantStore.self) private var tenantStore
    @Environment(ActivityLog.self) private var activityLog

    let tenant: Tenant
    let block: BlockMetadata
    let selection: BlockSelection
    /// Other selected blocks that create groups or categories.
    var providers: [Provider] = []

    struct Provider: Hashable {
        var blockID: String
        var blockName: String
        var groups: [String]
        /// The subset of `groups` that are mobile device groups.
        var mobileGroups: [String] = []
        var categories: [String]

        /// The groups that can scope a block of the given kind.
        func groups(for kind: BlockScope.Kind) -> [String] {
            kind == .jamfProMobileGroup
                ? groups.filter(mobileGroups.contains)
                : groups.filter { !mobileGroups.contains($0) }
        }
    }

    @State private var isPickingApps = false
    @State private var isPickingStoreApps = false
    @State private var groups: [ExistingObjectService.ComputerGroup]?
    @State private var categories: [ExistingObjectRef]?
    @State private var lookupError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TerraformTerm("input variables of the block's module; values in tenant.auto.tfvars")
            if block.scope.kind != .none {
                scopePicker
            }
            if block.acceptsCategory {
                categoryPicker
            }
            if let lookupError {
                Label("Existing groups and categories could not be loaded: \(lookupError)", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            let sections = Dictionary(grouping: block.settings, by: \.section)
            ForEach(sections.keys.sorted(), id: \.self) { section in
                VStack(alignment: .leading, spacing: 6) {
                    if sections.count > 1 {
                        Text(section)
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                    }
                    ForEach(sections[section] ?? []) { setting in
                        settingControl(setting)
                    }
                }
            }
        }
        .controlSize(.small)
        .task(id: tenant.id) { await loadExistingObjects() }
    }

    // MARK: Scope and category

    /// Existing groups are listed by Jamf Pro ID; Platform-scoped blocks
    /// offer groups other selected blocks create.
    private var offersExistingGroups: Bool {
        block.scope.kind == .jamfProGroup || block.scope.kind == .jamfProMobileGroup
    }

    private var isMobileScope: Bool {
        block.scope.kind == .jamfProMobileGroup
    }

    private var existingGroupChoices: [ExistingObjectRef] {
        var choices = (groups ?? [])
            .filter { !block.scope.smartOnly || $0.isSmart }
            .map(\.ref)
        if let current = selection.existingScope, !choices.contains(current) {
            choices.insert(current, at: 0)
        }
        return choices
    }

    private var scopePicker: some View {
        Picker("Scope", selection: scopeBinding) {
            if selection.existingScope == nil, selection.providedScope == nil {
                Text("Choose a group…").tag("")
            }
            ForEach(providers.filter { !$0.groups(for: block.scope.kind).isEmpty }, id: \.blockID) { provider in
                Section("Created by \(provider.blockName)") {
                    ForEach(provider.groups(for: block.scope.kind), id: \.self) { name in
                        Text(name).tag("provided:\(provider.blockID)/\(name)")
                    }
                }
            }
            if let provided = selection.providedScope,
               !providers.contains(where: { $0.blockID == provided.blockID && $0.groups(for: block.scope.kind).contains(provided.name) }) {
                Text("\(provided.name) (block not selected)").tag("provided:\(provided.reference)")
            }
            if offersExistingGroups {
                Section(groups == nil && lookupError == nil ? "In this tenant (loading…)" : "In this tenant") {
                    ForEach(existingGroupChoices, id: \.id) { group in
                        Text(group.name).tag("existing:\(group.id)")
                    }
                }
            }
        }
        .frame(maxWidth: 420)
        .help(isMobileScope
            ? "The mobile device group this block applies to: one another selected block creates, or one already in the tenant."
            : block.scope.smartOnly
            ? "The smart group this block applies to: one another selected block creates, or one already in the tenant. App Installers need a smart group."
            : "The group this block applies to: one another selected block creates, or one already in the tenant.")
    }

    private var scopeBinding: Binding<String> {
        Binding(
            get: {
                if let existing = selection.existingScope { return "existing:\(existing.id)" }
                if let provided = selection.providedScope { return "provided:\(provided.reference)" }
                return ""
            },
            set: { tag in
                mutateSelection { selection in
                    if tag.hasPrefix("existing:") {
                        let id = String(tag.dropFirst("existing:".count))
                        selection.existingScope = existingGroupChoices.first { $0.id == id }
                        selection.providedScope = nil
                    } else if tag.hasPrefix("provided:") {
                        selection.providedScope = ProvidedObject(reference: String(tag.dropFirst("provided:".count)))
                        selection.existingScope = nil
                    }
                }
            }
        )
    }

    private var categoryChoices: [ExistingObjectRef] {
        var choices = [ExistingObjectRef.noCategory] + (categories ?? [])
        if let current = selection.existingCategory, !choices.contains(current) {
            choices.insert(current, at: 1)
        }
        return choices
    }

    private var categoryPicker: some View {
        Picker(block.settings.contains { $0.type == .appPicker } ? "Default category" : "Category", selection: categoryBinding) {
            ForEach(providers.filter { !$0.categories.isEmpty }, id: \.blockID) { provider in
                Section("Created by \(provider.blockName)") {
                    ForEach(provider.categories, id: \.self) { name in
                        Text(name).tag("provided:\(provider.blockID)/\(name)")
                    }
                }
            }
            if let provided = selection.providedCategory,
               !providers.contains(where: { $0.blockID == provided.blockID && $0.categories.contains(provided.name) }) {
                Text("\(provided.name) (block not selected)").tag("provided:\(provided.reference)")
            }
            Section("In this tenant") {
                ForEach(categoryChoices, id: \.id) { category in
                    Text(category.name).tag("existing:\(category.id)")
                }
            }
        }
        .frame(maxWidth: 420)
        .help("The Jamf Pro category this block's objects are filed under")
    }

    private var categoryBinding: Binding<String> {
        Binding(
            get: {
                if let existing = selection.existingCategory { return "existing:\(existing.id)" }
                if let provided = selection.providedCategory { return "provided:\(provided.reference)" }
                return "existing:\(ExistingObjectRef.noCategory.id)"
            },
            set: { tag in
                mutateSelection { selection in
                    if tag.hasPrefix("existing:") {
                        let id = String(tag.dropFirst("existing:".count))
                        selection.existingCategory = categoryChoices.first { $0.id == id }
                        selection.providedCategory = nil
                    } else if tag.hasPrefix("provided:") {
                        selection.providedCategory = ProvidedObject(reference: String(tag.dropFirst("provided:".count)))
                        selection.existingCategory = nil
                    }
                }
            }
        )
    }

    private func loadExistingObjects() async {
        guard offersExistingGroups || block.acceptsCategory else { return }
        do {
            if offersExistingGroups {
                groups = isMobileScope
                    ? try await ExistingObjectService.mobileDeviceGroups(tenant: tenant, activityLog: activityLog)
                    : try await ExistingObjectService.computerGroups(tenant: tenant, activityLog: activityLog)
            }
            if block.acceptsCategory {
                categories = try await ExistingObjectService.categories(tenant: tenant, activityLog: activityLog)
            }
            lookupError = nil
        } catch {
            lookupError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    @ViewBuilder
    private func settingControl(_ setting: BlockSetting) -> some View {
        let binding = settingBinding(setting)
        switch setting.type {
        case .bool:
            Toggle(setting.title, isOn: Binding(
                get: { binding.wrappedValue == "true" },
                set: { binding.wrappedValue = $0 ? "true" : "false" }
            ))
            .help(setting.description)
        case .enumeration:
            Picker(setting.title, selection: binding) {
                ForEach(Array((setting.enumValues ?? []).enumerated()), id: \.element) { index, value in
                    Text(setting.enumLabels?.indices.contains(index) == true ? setting.enumLabels![index] : value)
                        .tag(value)
                }
            }
            .frame(maxWidth: 420)
            .help(setting.description)
        case .secret:
            // Secret settings live in the Keychain only; tenant.json (which
            // syncs through team spaces) never sees the value.
            SecureField(setting.title, text: Binding(
                get: {
                    TenantSecrets(tenantID: tenant.id)
                        .blockSetting(blockID: block.id, key: setting.key)
                        .load() ?? ""
                },
                set: { newValue in
                    TenantSecrets(tenantID: tenant.id)
                        .blockSetting(blockID: block.id, key: setting.key)
                        .save(newValue)
                }
            ))
            .frame(maxWidth: 360)
            .help(setting.description)
        case .appPicker:
            HStack(spacing: 8) {
                Button("Choose Apps…", systemImage: "app.badge") {
                    isPickingApps = true
                }
                let count = AppCatalogApp.decode(settingValue: binding.wrappedValue).count
                Text(count == 0 ? "No apps selected yet" : "\(count) app\(count == 1 ? "" : "s") selected")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .sheet(isPresented: $isPickingApps) {
                AppCatalogPickerView(tenant: tenant, apps: Binding(
                    get: { AppCatalogApp.decode(settingValue: binding.wrappedValue) },
                    set: { binding.wrappedValue = AppCatalogApp.encode($0) }
                ))
            }
        case .macAppStorePicker, .mobileAppStorePicker:
            HStack(spacing: 8) {
                Button("Choose Apps…", systemImage: setting.type == .macAppStorePicker ? "app.badge" : "ipad.and.iphone") {
                    isPickingStoreApps = true
                }
                let count = AppStoreApp.decode(settingValue: binding.wrappedValue).count
                Text(count == 0 ? "No apps selected yet" : "\(count) app\(count == 1 ? "" : "s") selected")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .sheet(isPresented: $isPickingStoreApps) {
                AppStorePickerView(
                    tenant: tenant,
                    platform: setting.type == .macAppStorePicker ? .mac : .mobile,
                    apps: Binding(
                        get: { AppStoreApp.decode(settingValue: binding.wrappedValue) },
                        set: { binding.wrappedValue = AppStoreApp.encode($0) }
                    ),
                    locationName: Binding(
                        get: { selection.settings["vpp_location_name"] ?? "" },
                        set: { name in mutateSelection { $0.settings["vpp_location_name"] = name } }
                    )
                )
            }
        case .number:
            TextField(setting.title, text: binding, prompt: Text(setting.default))
                .frame(maxWidth: 360)
                .help(setting.description)
        case .string, .stringList:
            VStack(alignment: .leading, spacing: 2) {
                TextField(setting.title, text: binding, prompt: setting.required ? Text("Required") : nil)
                    .frame(maxWidth: 420)
                if !setting.description.isEmpty {
                    Text(setting.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func settingBinding(_ setting: BlockSetting) -> Binding<String> {
        Binding(
            get: { selection.settings[setting.key] ?? setting.default },
            set: { newValue in mutateSelection { $0.settings[setting.key] = newValue } }
        )
    }

    private func mutateSelection(_ mutate: (inout BlockSelection) -> Void) {
        var tenantCopy = tenant
        guard let index = tenantCopy.blockSelections.firstIndex(where: { $0.blockID == block.id }) else { return }
        mutate(&tenantCopy.blockSelections[index])
        tenantStore.update(tenantCopy)
    }
}

/// Saves the tenant's baseline as a preset file in a folder catalog source.
struct SavePresetSheet: View {
    let tenant: Tenant
    let catalog: LoadedCatalog
    var onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(CatalogSourceStore.self) private var catalogSources
    @State private var name = ""
    @State private var summary = ""
    @State private var destinationID: UUID?
    @State private var errorMessage: String?
    @State private var isConfirmingReplace = false

    private var folderSources: [CatalogSourceStore.CustomSource] {
        catalogSources.customSources.filter { $0.kind == .localFolder }
    }

    private var preset: Preset {
        Preset.capturing(
            name: name.trimmingCharacters(in: .whitespaces),
            summary: summary.trimmingCharacters(in: .whitespaces),
            selections: tenant.blockSelections.map {
                Preset.PresetSelection(
                    blockID: $0.blockID, settings: $0.settings,
                    providedScope: $0.providedScope, providedCategory: $0.providedCategory)
            },
            blocks: catalog.blocks)
    }

    private var destinationURL: URL? {
        guard let source = folderSources.first(where: { $0.id == destinationID }) else { return nil }
        return URL(filePath: source.path).appending(path: "presets/\(preset.id).json")
    }

    var body: some View {
        SheetFrame(title: "Save as Preset", systemImage: "square.stack.3d.up") {
            Form {
                TextField("Name", text: $name, prompt: Text("Office devices"))
                TextField("Summary", text: $summary, prompt: Text("What this baseline is for"), axis: .vertical)
                    .lineLimit(2...4)
                if folderSources.isEmpty {
                    Text("Presets are saved in a folder catalog source. Add one in Building Blocks → Manage Sources → Add Folder…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Save into", selection: $destinationID) {
                        ForEach(folderSources) { source in
                            Text(source.name).tag(Optional(source.id))
                        }
                    }
                }
                Section {
                    Text("\(tenant.blockSelections.count) building block\(tenant.blockSelections.count == 1 ? "" : "s") with their changed settings, and the groups and categories they use from other blocks in the preset. Groups and categories picked from this tenant, and secret settings, are not saved.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
        } footer: {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save") {
                if let url = destinationURL, FileManager.default.fileExists(atPath: url.path) {
                    isConfirmingReplace = true
                } else {
                    save()
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || destinationURL == nil)
        }
        .frame(width: 480, height: 400)
        .confirmationDialog(
            "Replace the existing preset “\(preset.id)”?",
            isPresented: $isConfirmingReplace,
            titleVisibility: .visible
        ) {
            Button("Replace", role: .destructive) { save() }
        }
        .onAppear { destinationID = destinationID ?? folderSources.first?.id }
    }

    private func save() {
        guard let url = destinationURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(preset).write(to: url, options: .atomic)
            onSaved()
            dismiss()
        } catch {
            errorMessage = "The preset could not be saved: \(error.localizedDescription)"
        }
    }
}
