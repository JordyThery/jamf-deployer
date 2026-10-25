import SwiftUI
import JTKit

struct ContentView: View {
    @Environment(TenantStore.self) private var tenantStore
    @Environment(TenantDeployService.self) private var deployService
    @Environment(ComponentUpdateChecker.self) private var componentUpdates
    @Environment(UpdateChecker.self) private var updates
    @Environment(TourState<TourAnchor>.self) private var tour
    @Environment(AppState.self) private var appState

    @State private var selection: SidebarSelection? = .fleet
    @State private var isConnectingTenant = false

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection, isConnectingTenant: $isConnectingTenant)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            detail
        }
        .frame(minWidth: 900, minHeight: 560)
        .sheet(isPresented: $isConnectingTenant) {
            ConnectTenantWizard()
        }
        .sheet(isPresented: Binding(
            get: { updates.isPresented },
            set: { updates.isPresented = $0 }
        )) {
            UpdateView()
        }
        .guidedTour(tour)
        .onChange(of: selection) {
            appState.selection = selection
        }
        .onChange(of: tenantStore.tenants) {
            // a tenant removed in Settings › Connections leaves the detail
            if case .tenant(let id) = selection, tenantStore.tenant(id: id) == nil {
                selection = .fleet
            }
        }
        .task {
            await deployService.syncTeamState()
            await updates.checkAutomatically()
            await componentUpdates.checkIfDue()
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .fleet, nil:
            FleetDashboardView(selection: $selection, isConnectingTenant: $isConnectingTenant)
        case .tenant(let id):
            // A fresh view per tenant: no form state carries over.
            TenantDetailView(tenantID: id)
                .id(id)
        case .catalog:
            CatalogView()
        case .history:
            HistoryView()
        }
    }
}
