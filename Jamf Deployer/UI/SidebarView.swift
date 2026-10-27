import SwiftUI
import JTKit

/// What the sidebar can select.
nonisolated enum SidebarSelection: Hashable, Sendable {
    case fleet
    case tenant(UUID)
    case catalog
    case history
}

/// Tour anchor targets across the main window.
nonisolated enum TourAnchor: Hashable, Sendable {
    case fleet
    case tenants
    case catalog
    case detail
}

struct SidebarView: View {
    @Environment(TenantStore.self) private var tenantStore
    @Environment(TenantDeployService.self) private var deployService
    @Environment(DemoMode.self) private var demo
    @Binding var selection: SidebarSelection?
    @Binding var isConnectingTenant: Bool
    @State private var tenantPendingRemoval: Tenant?
    @State private var removalError: String?

    var body: some View {
        List(selection: $selection) {
            Section("Fleet") {
                Label("Dashboard", systemImage: "rectangle.3.group")
                    .tag(SidebarSelection.fleet)
            }
            .tourAnchor(TourAnchor.fleet)

            Section("Tenants") {
                ForEach(tenantStore.tenants) { tenant in
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(tenant.name)
                            Text(deployService.isRemoving(tenant.id) ? "Removing…" : tenant.connectionLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    } icon: {
                        Image(systemName: "building.2")
                    }
                    .tag(SidebarSelection.tenant(tenant.id))
                    .contextMenu {
                        Button("Remove Tenant…", role: .destructive) {
                            tenantPendingRemoval = tenant
                        }
                        .disabled(deployService.isRemoving(tenant.id))
                    }
                }
                Button {
                    isConnectingTenant = true
                } label: {
                    Label("Connect a Tenant…", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .help(demo.isOn ? "Add a Contoso demo tenant to the demo fleet" : "Add a Jamf tenant to the fleet")
                if tenantStore.tenants.isEmpty && !demo.isOn {
                    Button {
                        _ = demo.requestSwitch(to: true)
                    } label: {
                        Label("Try Demo Mode", systemImage: "testtube.2")
                    }
                    .buttonStyle(.borderless)
                    .help(DemoMode.helpText)
                }
            }
            .tourAnchor(TourAnchor.tenants)

            Section("Library") {
                Label("Building Blocks", systemImage: "square.grid.2x2")
                    .tag(SidebarSelection.catalog)
                Label("History", systemImage: "clock.arrow.circlepath")
                    .tag(SidebarSelection.history)
            }
            .tourAnchor(TourAnchor.catalog)
        }
        .confirmationDialog(
            "Remove “\(tenantPendingRemoval?.name ?? "")” from this app?",
            isPresented: Binding(
                get: { tenantPendingRemoval != nil },
                set: { if !$0 { tenantPendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Tenant", role: .destructive) {
                if let tenant = tenantPendingRemoval {
                    if case .tenant(tenant.id) = selection {
                        selection = .fleet
                    }
                    Task {
                        do {
                            try await deployService.removeTenant(tenant)
                        } catch {
                            removalError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deployService.isTeamMode
                ? "Nothing in Jamf is changed. The tenant record and its state are deleted from the team space for everyone, and its credentials from this Mac."
                : "Nothing in Jamf is changed. The tenant record kept by this app and its stored credentials are deleted.")
        }
        .alert(
            "Tenant Not Removed",
            isPresented: Binding(get: { removalError != nil }, set: { if !$0 { removalError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Its deployment state could not be deleted from the team space: \(removalError ?? ""). Try again later.")
        }
    }
}
