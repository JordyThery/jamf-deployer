import SwiftUI
import DeployerKit
import JamfDeployerCore

/// Every preview and deploy across the fleet: who, when, what.
struct HistoryView: View {
    @Environment(TenantStore.self) private var tenantStore
    @Environment(TenantDeployService.self) private var deployService

    private struct Row: Identifiable {
        var id: String { "\(tenantID)-\(entry.id)" }
        var tenantID: UUID
        var tenantName: String
        var entry: DeployHistoryEntry
    }

    @State private var rows: [Row] = []
    @State private var rollbackMessage: String?

    var body: some View {
        Group {
            if rows.isEmpty {
                ContentUnavailableView(
                    "No History Yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Every deploy is recorded here: who ran it, when, and what changed.")
                )
            } else {
                Table(rows) {
                    TableColumn("When") { row in
                        Text(row.entry.date, format: .dateTime.day().month().hour().minute())
                    }
                    .width(130)
                    TableColumn("Tenant") { row in
                        Text(row.tenantName)
                    }
                    TableColumn("Who") { row in
                        Text(row.entry.engineerName)
                    }
                    TableColumn("Changes") { row in
                        Text(changesText(row.entry))
                            .foregroundStyle(.secondary)
                    }
                    TableColumn("Result") { row in
                        if row.entry.failed == 0 {
                            Label("Succeeded", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Label("\(row.entry.failed) failed", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                        }
                    }
                    TableColumn("Roll back") { row in
                        Button("Roll Back…") {
                            rollBack(row)
                        }
                        .controlSize(.small)
                        .help("Restore this entry's baseline selection; the next preview plans back to it against the tenant's current state")
                    }
                    .width(90)
                    TableColumn("Blocks") { row in
                        Text(row.entry.blockVersions.map { "\($0.key)@\($0.value)" }.sorted().joined(separator: ", "))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .help(row.entry.blockVersions.map { "\($0.key)@\($0.value)" }.sorted().joined(separator: "\n"))
                    }
                }
            }
        }
        .navigationTitle("History")
        .task {
            reload()
        }
        .toolbar {
            Button("Reload", systemImage: "arrow.clockwise") {
                reload()
            }
        }
        .alert("Baseline Restored", isPresented: Binding(
            get: { rollbackMessage != nil },
            set: { if !$0 { rollbackMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(rollbackMessage ?? "")
        }
    }

    private func rollBack(_ row: Row) {
        guard let tenant = tenantStore.tenant(id: row.tenantID) else { return }
        do {
            try deployService.rollback(tenant: tenant, toHistoryEntry: row.entry.id)
            rollbackMessage = "“\(tenant.name)” now uses the baseline from \(row.entry.date.formatted(date: .abbreviated, time: .shortened)). Open the tenant and Preview Changes to apply it."
        } catch {
            rollbackMessage = "Could not restore: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    private func changesText(_ entry: DeployHistoryEntry) -> String {
        var parts: [String] = []
        if entry.added > 0 { parts.append("\(entry.added) created") }
        if entry.changed > 0 { parts.append("\(entry.changed) updated") }
        if entry.removed > 0 { parts.append("\(entry.removed) removed") }
        if entry.stoppedManaging > 0 { parts.append("\(entry.stoppedManaging) stopped managing") }
        return parts.isEmpty ? "No changes" : parts.joined(separator: " · ")
    }

    private func reload() {
        rows = tenantStore.tenants.flatMap { tenant in
            deployService.historyEntries(for: tenant).map {
                Row(tenantID: tenant.id, tenantName: tenant.name, entry: $0)
            }
        }
        .sorted { $0.entry.date > $1.entry.date }
    }
}
