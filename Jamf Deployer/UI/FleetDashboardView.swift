import SwiftUI
import DeployerKit
import JamfDeployerCore

/// The home screen: one table with every tenant and its health at a glance.
struct FleetDashboardView: View {
    @Environment(TenantStore.self) private var tenantStore
    @Environment(TenantDeployService.self) private var deployService
    @State private var catalog: LoadedCatalog?
    @Binding var selection: SidebarSelection?
    @Binding var isConnectingTenant: Bool
    @State private var searchText = ""
    @State private var showsOnlyNeedsAttention = false
    @State private var isRollingOut = false

    private var rows: [Tenant] {
        tenantStore.tenants.filter { tenant in
            if showsOnlyNeedsAttention {
                let needsAttention = tenant.preflight?.allGreen == false
                    || !tenant.outstandingDrift.isEmpty
                    || (tenant.lastDeploy?.failed ?? 0) > 0
                guard needsAttention else { return false }
            }
            guard !searchText.isEmpty else { return true }
            return tenant.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        Group {
            if tenantStore.tenants.isEmpty {
                ContentUnavailableView {
                    Label("No Tenants Yet", systemImage: "building.2")
                } description: {
                    Text("Connect your first Jamf tenant to see the whole fleet here.")
                } actions: {
                    Button("Connect a Tenant…") {
                        isConnectingTenant = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Table(rows) {
                    TableColumn("Tenant") { tenant in
                        HStack(spacing: 6) {
                            Text(tenant.name)
                                .font(.body.weight(.medium))
                            StatusBadge(
                                tenant.isProduction ? "Production" : "Test",
                                style: tenant.isProduction ? .tinted : .neutral
                            )
                        }
                    }
                    TableColumn("Status") { tenant in
                        if let lock = deployService.lock(for: tenant.id) {
                            Label("\(lock.operation == "check" ? "Being checked" : "Being deployed") by \(lock.engineer) on \(lock.host)", systemImage: "lock.fill")
                                .foregroundStyle(.orange)
                                .help("Since \(lock.acquiredAt.formatted(.relative(presentation: .named)))")
                        } else {
                            statusLabel(for: tenant)
                        }
                    }
                    TableColumn("Jamf Pro") { tenant in
                        Text(tenant.preflight.flatMap(\.jamfProVersion).map(PreflightService.displayVersion) ?? "—")
                            .font(.body.monospaced())
                    }
                    .width(80)
                    TableColumn("Baseline") { tenant in
                        baselineCell(for: tenant)
                    }
                    .width(110)
                    TableColumn("Last deploy") { tenant in
                        if let deploy = tenant.lastDeploy {
                            Text(deploy.date, format: .dateTime.day().month().hour().minute())
                        } else {
                            Text("Never")
                                .foregroundStyle(.secondary)
                        }
                    }
                    TableColumn("ADE token") { tenant in
                        expiryText(tenant.preflight?.adeTokenExpiration)
                    }
                    TableColumn("VPP token") { tenant in
                        expiryText(tenant.preflight?.vppTokenExpiration)
                    }
                }
                .contextMenu(forSelectionType: Tenant.ID.self) { ids in
                    if let id = ids.first {
                        Button("Open Tenant") { selection = .tenant(id) }
                    }
                } primaryAction: { ids in
                    if let id = ids.first {
                        selection = .tenant(id)
                    }
                }
                .searchable(text: $searchText, placement: .toolbar, prompt: "Search tenants")
            }
        }
        .navigationTitle("Fleet")
        .task {
            catalog = try? deployService.loadCatalog()
        }
        .toolbar {
            Toggle(isOn: $showsOnlyNeedsAttention) {
                Label("Needs Attention", systemImage: "exclamationmark.triangle")
            }
            .help("Show only tenants that need attention")
            Button {
                isConnectingTenant = true
            } label: {
                Label("Connect a Tenant", systemImage: "plus")
            }
            .help("Add a Jamf tenant to the fleet")
            if deployService.isTeamMode {
                Button {
                    Task { await deployService.syncTeamState() }
                } label: {
                    Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                }
                .help("Pull the latest tenant records and locks from the team space")
            }
            Button {
                Task { await deployService.checkAllTenants() }
            } label: {
                if let progress = deployService.fleetCheckProgress {
                    Label("Checking \(progress.done)/\(progress.total)…", systemImage: "arrow.clockwise")
                } else {
                    Label("Check All Tenants", systemImage: "arrow.clockwise")
                }
            }
            .disabled(deployService.fleetCheckProgress != nil || !tenantStore.tenants.contains { deployService.isManaged($0) })
            .help("Compare every managed tenant against its record (a few at a time) and flag changes made in Jamf")
            Button {
                isRollingOut = true
            } label: {
                Label("Roll Out…", systemImage: "square.stack.3d.forward.dottedline")
            }
            .disabled(deployService.isBusy || tenantStore.tenants.filter(deployService.canRollOut).count < 2)
            .help("Deploy to several tenants one at a time, test tenants first, previewing each one")
        }
        .sheet(isPresented: $isRollingOut) {
            RolloutView()
        }
    }

    private enum StatusKind {
        case neverDeployed
        case attention
    }

    private func statusKind(for tenant: Tenant) -> StatusKind {
        tenant.preflight?.allGreen == false ? .attention : .neverDeployed
    }

    @ViewBuilder
    private func statusLabel(for tenant: Tenant) -> some View {
        if tenant.isHandedOver {
            Label("Handed over", systemImage: "archivebox")
                .foregroundStyle(.secondary)
        } else if let failure = deployService.fleetCheckFailure(for: tenant.id) {
            Label("Check failed", systemImage: "xmark.circle.fill")
                .foregroundStyle(.orange)
                .help(failure)
        } else if tenant.lastDeploy == nil {
            if tenant.preflight?.allGreen == false {
                Label("Check preflight", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
            } else {
                Label("Never deployed", systemImage: "circle.dashed")
                    .foregroundStyle(.secondary)
            }
        } else if !tenant.outstandingDrift.isEmpty {
            Label("\(tenant.outstandingDrift.count) change\(tenant.outstandingDrift.count == 1 ? "" : "s") made in Jamf", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
        } else if let checked = tenant.lastDriftCheck {
            // "In sync" only with a recent check; otherwise show the age.
            if Date.now.timeIntervalSince(checked) < 24 * 60 * 60 {
                Label("In sync", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label("Last checked \(checked.formatted(.relative(presentation: .named)))", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
        } else {
            Label("Not checked yet", systemImage: "questionmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func baselineCell(for tenant: Tenant) -> some View {
        if tenant.deployedBlockVersions.isEmpty {
            Text(deployService.isManaged(tenant) ? "Adopted only" : "—").foregroundStyle(.secondary)
        } else {
            let updates = catalog.map { catalog in
                tenant.deployedBlockVersions.filter { id, version in
                    catalog.block(id: id).map { $0.version != version } ?? false
                }.count
            } ?? 0
            HStack(spacing: 5) {
                Text("\(tenant.deployedBlockVersions.count) blocks")
                if updates > 0 {
                    StatusBadge("Update available", style: .warning)
                }
            }
            .help(updates > 0
                ? "\(updates) block\(updates == 1 ? " has" : "s have") a newer version in the catalog — preview the tenant to apply it"
                : "Deployed blocks match the catalog")
        }
    }

    @ViewBuilder
    private func expiryText(_ raw: String?) -> some View {
        if let raw, let date = parseExpiry(raw) {
            let days = Calendar.current.dateComponents([.day], from: .now, to: date).day ?? 0
            Text(date, format: .dateTime.day().month().year())
                .foregroundStyle(days < 30 ? AnyShapeStyle(.yellow) : AnyShapeStyle(.primary))
                .help(days < 30 ? "Expires in \(days) days — renew it soon" : "Expires in \(days) days")
        } else {
            Text("—")
                .foregroundStyle(.secondary)
                .help("Run a preflight on the tenant to read token expiry")
        }
    }

    private func parseExpiry(_ raw: String) -> Date? {
        if let date = try? Date(raw, strategy: .iso8601) {
            return date
        }
        // Some fields come as plain "YYYY-MM-DD".
        var strategy = Date.ISO8601FormatStyle()
        strategy.timeZone = .current
        return try? Date(raw, strategy: strategy.year().month().day())
    }
}
