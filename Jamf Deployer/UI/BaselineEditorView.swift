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

    @State private var expandedBlockID: String?
    @State private var blockPendingRemoval: BlockMetadata?
    @State private var isCheckingUpdates = false

    private var selectionIndex: [String: BlockSelection] {
        Dictionary(uniqueKeysWithValues: tenant.blockSelections.map { ($0.blockID, $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Menu("Apply a Preset", systemImage: "square.stack.3d.up") {
                    ForEach(catalog.presets) { preset in
                        Button(preset.name) { apply(preset) }
                            .help(preset.summary)
                    }
                }
                .fixedSize()
                .help("Replaces the current block selection with a preset")

                Button("Baseline Updates…", systemImage: "square.and.arrow.down.badge.clock") {
                    isCheckingUpdates = true
                }
                .help("Checks the tenant's catalog sources for newer releases, block by block")
                Spacer()
                Text("\(tenant.blockSelections.count) of \(catalog.blocks.count) blocks selected")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ForEach(catalog.blocks) { block in
                blockRow(block)
            }
        }
        .sheet(isPresented: $isCheckingUpdates) {
            BaselineUpdateSheet(tenant: tenant)
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
            Text("Remove from Tenant deletes the block's objects from Jamf on the next deploy. Stop Managing leaves everything in Jamf untouched — the app just stops tracking it. The preview shows exactly what happens either way.")
        }
    }

    @ViewBuilder
    private func blockRow(_ block: BlockMetadata) -> some View {
        let selection = selectionIndex[block.id]
        let isSelected = selection != nil || block.alwaysOn
        let prerequisitesMissing = block.requires.filter { selectionIndex[$0] == nil && $0 != "foundation" }

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
                .disabled(block.alwaysOn)

                Spacer()

                if isSelected && (block.scope.kind != .none || !block.settings.isEmpty) {
                    Button(expandedBlockID == block.id ? "Hide Settings" : "Settings…") {
                        expandedBlockID = expandedBlockID == block.id ? nil : block.id
                    }
                    .buttonStyle(.borderless)
                }
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
                Label("Also selects \(missing) — this block needs it.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    selection: selection ?? BlockSelection(blockID: block.id, scope: block.scope.default ?? "pilot")
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
                    updated.blockSelections.append(defaultSelection(for: required))
                }
            }
            updated.blockSelections.append(defaultSelection(for: block))
            tenantStore.update(updated)
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

    private func defaultSelection(for block: BlockMetadata) -> BlockSelection {
        var settings: [String: String] = [:]
        for setting in block.settings where !setting.default.isEmpty {
            settings[setting.key] = setting.default
        }
        // Safe default: pilot scope unless the block declares otherwise.
        let scope = block.scope.default ?? "pilot"
        return BlockSelection(blockID: block.id, settings: settings, scope: scope)
    }

    private func apply(_ preset: Preset) {
        var updated = tenant
        updated.blockSelections = preset.blocks.compactMap { blockID in
            guard let block = catalog.block(id: blockID) else { return nil }
            var selection = defaultSelection(for: block)
            for (key, value) in preset.defaults[blockID] ?? [:] {
                selection.settings[key] = value
            }
            return selection
        }
        tenantStore.update(updated)
    }
}

/// Native controls for one block's settings and scope.
struct BlockSettingsForm: View {
    @Environment(TenantStore.self) private var tenantStore

    let tenant: Tenant
    let block: BlockMetadata
    let selection: BlockSelection

    @State private var isPickingApps = false

    private static let scopeChoices: [(key: String, label: String)] = [
        ("pilot", "Pilot"),
        ("all_macs", "All Managed Macs"),
        ("laptops", "Laptops"),
        ("desktops", "Desktops"),
        ("apple_silicon", "Apple Silicon Macs"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if block.scope.kind != .none {
                // App Installers only accept smart groups; the static Pilot
                // group is withheld for those blocks.
                let choices = block.scope.smartOnly
                    ? Self.scopeChoices.filter { $0.key != "pilot" }
                    : Self.scopeChoices
                Picker("Scope", selection: scopeBinding) {
                    ForEach(choices, id: \.key) { choice in
                        Text(choice.label).tag(choice.key)
                    }
                }
                .frame(maxWidth: 360)
                .help(tenant.isProduction
                    ? "Production tenants default to the Pilot group — widen the scope once the pilot looks good."
                    : "The device group this block applies to.")
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
    }

    private var scopeBinding: Binding<String> {
        Binding(
            get: { selection.scope },
            set: { newValue in mutateSelection { $0.scope = newValue } }
        )
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
