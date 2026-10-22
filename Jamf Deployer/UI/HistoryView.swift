import SwiftUI
import DeployerKit
import JamfDeployerCore

/// Every deploy across the fleet: who, when, what.
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
    @State private var rollbackFailed = false
    @State private var rowPendingRollback: Row?

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
                            rowPendingRollback = row
                        }
                        .controlSize(.small)
                        .help("Restore this deploy's baseline; preview and deploy to apply it")
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
        .safeAreaInset(edge: .top, spacing: 0) {
            TerraformTerm("each entry is one apply; in a repository, the Git history of main")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 4)
        }
        .task {
            reload()
        }
        .toolbar {
            Button("Reload", systemImage: "arrow.clockwise") {
                reload()
            }
        }
        .confirmationDialog(
            "Roll back “\(rowPendingRollback?.tenantName ?? "")”?",
            isPresented: Binding(
                get: { rowPendingRollback != nil },
                set: { if !$0 { rowPendingRollback = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Roll Back") {
                if let row = rowPendingRollback { rollBack(row) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The tenant's baseline returns to the one from this deploy. Nothing changes in Jamf until you preview and deploy.")
        }
        .alert(rollbackFailed ? "Roll Back Failed" : "Baseline Restored", isPresented: Binding(
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
            rollbackFailed = false
            rollbackMessage = "“\(tenant.name)” now uses the baseline from \(row.entry.date.formatted(date: .abbreviated, time: .shortened)). Open the tenant and Preview Changes to apply it."
        } catch {
            rollbackFailed = true
            rollbackMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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
