import SwiftUI
import DeployerKit
import JamfDeployerCore

/// Per-block opt-in to newer catalog tags: shows what changed between the
/// tenant's pinned tag and the newest one, block by block.
struct BaselineUpdateSheet: View {
    @Environment(TenantStore.self) private var tenantStore
    @Environment(TenantDeployService.self) private var deployService
    @Environment(\.dismiss) private var dismiss

    let tenant: Tenant

    @State private var available: [(source: CatalogSourceStore.CustomSource, tag: String, updates: [CatalogUpdatePlanner.BlockUpdate])] = []
    @State private var chosen: Set<String> = []
    @State private var isLoading = true
    @State private var message: String?

    var body: some View {
        SheetFrame(
            title: "Baseline Updates — \(tenant.name)",
            systemImage: "square.and.arrow.down.badge.clock",
            isBusy: isLoading
        ) {
            content
        } footer: {
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Stage Selected Updates") { apply() }
                .buttonStyle(.borderedProminent)
                .disabled(chosen.isEmpty)
                .help("Moves the chosen blocks to the newer tag; Preview Changes shows the effect")
        }
        .frame(width: 620, height: 460)
        .task {
            await load()
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("Checking the catalog sources for newer releases…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let message {
            ContentUnavailableView("Catalog Check Failed", systemImage: "exclamationmark.icloud", description: Text(message))
        } else if available.isEmpty {
            ContentUnavailableView(
                "Baseline Is Current",
                systemImage: "checkmark.seal",
                description: Text("Every selected block already runs the newest release of its catalog source.")
            )
        } else {
            List {
                ForEach(Array(available.enumerated()), id: \.offset) { _, entry in
                    Section("\(entry.source.name) — \(tenant.catalogPins[entry.source.id.uuidString] ?? entry.source.defaultTag ?? "?") → \(entry.tag)") {
                        ForEach(entry.updates) { update in
                            Toggle(isOn: Binding(
                                get: { chosen.contains(update.blockID) },
                                set: { on in
                                    if on { chosen.insert(update.blockID) } else { chosen.remove(update.blockID) }
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(update.name)
                                            .font(.body.weight(.medium))
                                        Text("\(update.fromVersion) → \(update.toVersion)")
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(update.summary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
            }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            available = try await deployService.availableBaselineUpdates(for: tenant)
            chosen = Set(available.flatMap { $0.updates.map(\.blockID) })
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func apply() {
        for entry in available {
            let blockIDs = Set(entry.updates.map(\.blockID)).intersection(chosen)
            guard !blockIDs.isEmpty else { continue }
            deployService.applyBaselineUpdate(
                tenant: tenantStore.tenant(id: tenant.id) ?? tenant,
                source: entry.source,
                tag: entry.tag,
                blockIDs: blockIDs
            )
        }
        dismiss()
    }
}
