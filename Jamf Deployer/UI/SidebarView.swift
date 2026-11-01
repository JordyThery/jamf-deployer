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
    @State private var managedTenantPendingRemoval: Tenant?
    @State private var removalTypedName = ""
    @State private var removalError: String?
    private var screenWork: ScreenWork { .shared }

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
                            removalTypedName = ""
                            if TenantRemoval.needsTypedName(isManaged: deployService.isManaged(tenant)) {
                                managedTenantPendingRemoval = tenant
                            } else {
                                tenantPendingRemoval = tenant
                            }
                        }
                        // engine work would lose its folder and state halfway
                        .disabled(deployService.isRemoving(tenant.id) || deployService.isEngineWorkRunning)
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
                    // as the Tenant menu's switch: running work would be torn down
                    .disabled(deployService.isEngineWorkRunning || screenWork.isBusy)
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
            "Remove “\(tenantPendingRemoval?.name ?? "")” from This App?",
            isPresented: Binding(
                get: { tenantPendingRemoval != nil },
                set: { if !$0 { tenantPendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Tenant", role: .destructive) {
                if let tenant = tenantPendingRemoval { remove(tenant) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(TenantRemoval.message(isTeamMode: deployService.isTeamMode, isManaged: false))
        }
        // A managed tenant's state goes with it: type its name, as for Hand Over.
        .alert(
            "Remove “\(managedTenantPendingRemoval?.name ?? "")” from This App?",
            isPresented: Binding(
                get: { managedTenantPendingRemoval != nil },
                set: { if !$0 { managedTenantPendingRemoval = nil } }
            )
        ) {
            TextField("Type the tenant name to confirm", text: $removalTypedName)
            Button("Cancel", role: .cancel) { removalTypedName = "" }
            Button("Remove Tenant", role: .destructive) {
                removalTypedName = ""
                if let tenant = managedTenantPendingRemoval { remove(tenant) }
            }
            .disabled(!TenantRemoval.confirms(typed: removalTypedName,
                                              tenantName: managedTenantPendingRemoval?.name ?? ""))
        } message: {
            Text(TenantRemoval.message(isTeamMode: deployService.isTeamMode, isManaged: true))
        }
        .alert(
            "Tenant Not Removed",
            isPresented: Binding(get: { removalError != nil }, set: { if !$0 { removalError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(removalError ?? "")
        }
    }

    private func remove(_ tenant: Tenant) {
        // the dialog may have stayed open while a deploy started
        if let refusal = TenantRemoval.refusal(isEngineBusy: deployService.isEngineWorkRunning) {
            removalError = refusal
            return
        }
        if case .tenant(tenant.id) = selection {
            selection = .fleet
        }
        Task {
            do {
                try await deployService.removeTenant(tenant)
            } catch {
                removalError = Self.removalErrorText(error)
            }
        }
    }

    /// A refusal (busy, locked) says what to do itself; anything else
    /// comes from deleting the state in the team space.
    static func removalErrorText(_ error: Error) -> String {
        let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        switch error as? TenantDeployService.DeployError {
        case .tenantBusy?, .engineWorkInProgress?, .previewInProgress?, .locked?:
            return detail
        default:
            return "Its deployment state couldn’t be deleted from the team space: \(detail). Try again later."
        }
    }
}
