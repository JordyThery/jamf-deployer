import SwiftUI
import JTKit

struct ContentView: View {
    @Environment(TenantStore.self) private var tenantStore
    @Environment(TenantDeployService.self) private var deployService
    @Environment(ComponentUpdateChecker.self) private var componentUpdates
    @Environment(UpdateChecker.self) private var updates
    @Environment(TourState<TourAnchor>.self) private var tour
    @Environment(AppState.self) private var appState
    @Environment(DemoMode.self) private var demo

    @State private var isConnectingTenant = false

    /// The sidebar's selection lives in `AppState`, so the View menu can
    /// change it.
    private var selection: Binding<SidebarSelection?> {
        Bindable(appState).selection
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: selection, isConnectingTenant: $isConnectingTenant)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            detail
        }
        .frame(minWidth: 900, minHeight: 560)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            RequestWaitsBar()
        }
        .sheet(isPresented: $isConnectingTenant) {
            ConnectTenantWizard()
        }
        .sheet(isPresented: Binding(
            get: { updates.isPresented },
            set: { updates.isPresented = $0 }
        )) {
            UpdateView()
        }
        .sheet(item: Binding(
            get: { deployService.storeSecretReview },
            set: { if $0 == nil { Task { await deployService.closeStoreSecretReview(retry: false) } } }
        )) { review in
            StoreSecretsSheet(review: review)
        }
        .guidedTour(tour)
        // File › Connect a Tenant… (⌘N)
        .onChange(of: appState.menuRequest) {
            if appState.take([.connectTenant]) != nil { isConnectingTenant = true }
        }
        .onChange(of: tenantStore.tenants, initial: true) {
            // a tenant removed in Settings › Connections leaves the detail
            if case .tenant(let id) = appState.selection, tenantStore.tenant(id: id) == nil {
                appState.selection = .fleet
            }
        }
        .task {
            await deployService.syncTeamState()
            await deployService.checkExistingStoreOnce()
            // a sandbox run (UI tests) makes no update checks
            guard !demo.isSandbox else { return }
            await updates.checkAutomatically()
            await componentUpdates.checkIfDue()
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch appState.selection {
        case .fleet, nil:
            FleetDashboardView(selection: selection, isConnectingTenant: $isConnectingTenant)
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

/// A wait before Jamf is asked again ("Jamf asked to wait 40 s"), with Stop,
/// which ends every wait at once; those requests aren't sent again.
private struct RequestWaitsBar: View {
    @Environment(RequestWaits.self) private var waits

    var body: some View {
        if let text = waits.statusText {
            HStack(spacing: 8) {
                Label(text, systemImage: "hourglass")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Stop") { waits.cancelAll() }
                    .help("Ends the wait now; the request isn’t sent again.")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
            .accessibilityElement(children: .contain)
        }
    }
}
