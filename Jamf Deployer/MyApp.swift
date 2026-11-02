import SwiftUI
import JTKit
import os

@main
struct MyApp: App {
    @State private var worlds: AppWorlds
    @State private var activityLog: ActivityLog
    @State private var terraform = TerraformManager()
    @State private var componentUpdates = ComponentUpdateChecker()
    @State private var connections: ConnectionStore<TenantConnection>
    @State private var waits: RequestWaits

    init() {
        let activityLog = ActivityLog()
        // Waits before a retry, from every tenant's client: shown in the
        // main window with Stop.
        let waits = RequestWaits()
        TenantClients.shared.showWaits(in: waits)
        _waits = State(initialValue: waits)
        // Demo Mode in the Tenant menu, saved under "demoMode"
        let demo = DemoMode(key: "demoMode")
        if demo.isSandbox { DemoSecretVault.keepEverythingInMemory() }
        let worlds = AppWorlds(demo: demo, activityLog: activityLog)
        _worlds = State(initialValue: worlds)
        _activityLog = State(initialValue: activityLog)
        // Settings › Connections: always the real tenants (their own
        // tenant.json files and Keychain items, unchanged), also in demo mode
        let real = worlds.real
        // A sandbox launch and the unit tests' host keep everything apart
        // from the installed app's store, backups and Keychain items.
        let sandboxFolder = AppWorlds.sandboxFolder(demo: demo)
        let storage = TenantConnectionStorage(
            tenantStore: real.tenantStore,
            backupURL: sandboxFolder?.appending(path: "connection-backup") ?? TenantConnectionStorage.defaultBackupURL,
            signInID: { tenant in real.deployService.isTeamMode ? tenant.engineerClientID : nil }
        )
        _connections = State(initialValue: ConnectionStore(
            storage: storage,
            secrets: sandboxFolder != nil ? TenantSecrets.sandboxConnectionSecrets : TenantSecrets.connectionSecrets,
            log: { message in
                Logger(subsystem: "be.jordythery.jamf-deployer", category: "Connections").error("\(message, privacy: .public)")
            }
        ))
        // Not in the unit tests' host: the installed app may be exporting.
        if !TestRun.isUnitTestHost {
            Task.detached(priority: .background) { JamformerRunner.removeStaleExports() }
        }
    }

    @State private var updates = UpdateChecker(
        configuration: UpdateConfiguration(owner: "JordyThery", repository: "jamf-deployer", appName: "Jamf Deployer")
    )
    @State private var tour = JamfDeployerTour.makeState()

    var body: some Scene {
        Window("Jamf Deployer", id: "main") {
            if TestRun.isUnitTestHost {
                // unit tests run inside the app: no sync, no network, the
                // store is never touched
                Text("Running unit tests")
                    .frame(minWidth: 300, minHeight: 100)
            } else {
                let world = worlds.active
                // A fresh window content per world: no selection or sheet carries over.
                ContentView()
                    .id(world.id)
                    .environment(world.tenantStore)
                    .environment(activityLog)
                    .environment(waits)
                    .environment(updates)
                    .environment(tour)
                    .environment(world.deployService)
                    .environment(world.appState)
                    .environment(terraform)
                    .environment(world.catalogSources)
                    .environment(componentUpdates)
                    .environment(world.exportSessions)
                    .environment(worlds.demo)
                    .environment(worlds)
                    .onChange(of: worlds.demo.isOn, initial: true) {
                        ToolDoorway.setDemoMode(worlds.demo.isOn)
                    }
            }
        }

        ActivityLogWindow(
            log: activityLog,
            emptyDescription: "Calls to Jamf and engine runs appear here as they happen."
        )

        AboutWindow(configuration: .jamfDeployer)

        // General, Connections, Team, Advanced, then Updates.
        SettingsWindow(updates: updates) {
            GeneralSettingsSections()
        } tabs: {
            withStores(TenantConnectionsTab(store: connections))
            SettingsTab("Team", systemImage: "person.2") {
                withStores(TeamSettingsView().realStoreOnly(worlds.demo))
            }
            SettingsTab("Advanced", systemImage: "wrench.and.screwdriver") {
                withStores(AdvancedSettingsSections())
            }
        }

        .commands {
            AppInfoCommands(appName: "Jamf Deployer") {
                updates.checkManually()
            }
            // Every toolbar item and main action is also here. Commands
            // that a view runs go through `AppState.request`, so they behave
            // exactly as the button on screen; the checks below dim them as
            // those buttons are dimmed.
            CommandGroup(replacing: .newItem) {
                Group {
                    Button("Connect a Tenant…") {
                        appState.request(.connectTenant)
                    }
                    .keyboardShortcut("n")
                    Button("Export as Terraform…") {
                        appState.selection = .fleet
                        appState.request(.exportTerraform)
                    }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(deployService.isDemo || deployService.isBusy || !tenantStore.tenants.contains { !$0.isHandedOver })
                }
                // one sheet at a time: nothing here opens another over it
                .disabled(appState.isSheetOpen)
            }
            SidebarCommands()
            CommandGroup(before: .sidebar) {
                Group {
                    Button("Dashboard") { appState.selection = .fleet }
                        .keyboardShortcut("1")
                    Button("Building Blocks") { appState.selection = .catalog }
                        .keyboardShortcut("2")
                    Button("History") { appState.selection = .history }
                        .keyboardShortcut("3")
                    Divider()
                    // the selected tenant's sections
                    Button("Overview") { appState.request(.showOverview) }
                        .keyboardShortcut("1", modifiers: [.command, .option])
                        .disabled(selectedTenant == nil)
                    Button("Day 0 Setup") { appState.request(.showSetup) }
                        .keyboardShortcut("2", modifiers: [.command, .option])
                        .disabled(selectedTenant == nil)
                    Button("Export") { appState.request(.showExport) }
                        .keyboardShortcut("3", modifiers: [.command, .option])
                        .disabled(selectedTenant == nil)
                    Divider()
                    Toggle("Show Technical Details", isOn: $showsTechnicalDetails)
                    Button("Reload History") {
                        appState.selection = .history
                        appState.request(.reloadHistory)
                    }
                    Divider()
                }
                // one sheet at a time: nothing here opens another over it
                .disabled(appState.isSheetOpen)
            }
            CommandMenu("Tenant") {
                Group {
                    // No connection picker in this app: the switch lives here.
                    DemoModeToggle(demo: worlds.demo)
                        .disabled(worlds.isBusy)
                    Divider()
                    Button("Check for Changes", systemImage: "arrow.clockwise") {
                        appState.request(.checkForChanges)
                    }
                    .keyboardShortcut("r")
                    .disabled(!selectedTenantCanCheck)

                    Button("Check All Tenants", systemImage: "arrow.clockwise") {
                        Task { await deployService.checkAllTenants() }
                    }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(deployService.isBusy || deployService.fleetCheckProgress != nil
                        || !tenantStore.tenants.contains { deployService.isManaged($0) })

                    // Deploys always start here: the preview ends in the confirmed Deploy.
                    Button("Preview Changes…", systemImage: "list.bullet.clipboard") {
                        appState.previewRequestCount += 1
                    }
                    .keyboardShortcut("p")
                    .disabled(!(selectedTenant.map { deployService.canPreview($0) } ?? false))
                    Divider()
                    Button("Adopt Existing Configuration…") { appState.request(.adopt) }
                        .disabled(!selectedTenantCanChange)
                    Button("Add a Custom Object…") { appState.request(.addCustomObject) }
                        .disabled(!selectedTenantCanChange)
                    Button("Baseline Updates…") { appState.request(.baselineUpdates) }
                        .disabled(selectedTenant.map { $0.handOverPending || deployService.isDemo || deployService.isBusy } ?? true)
                    Button("Run Preflight") { appState.request(.runPreflight) }
                        .disabled(selectedTenant == nil || deployService.isBusy)
                    Divider()
                    Button(selectedTenant?.jamfProAuth == .userAccount ? "Update Password…" : "Update Client Secret…") {
                        appState.request(.updateSecret)
                    }
                    .disabled(selectedTenant == nil)
                    Button("Hand Over Tenant…") { appState.request(.handOver) }
                        .disabled(!(selectedTenant.map { deployService.isManaged($0) } ?? false) || !selectedTenantCanChange)
                    Button("Remove Tenant…") { appState.request(.removeTenant) }
                        // engine work would lose its folder and state halfway
                        .disabled(selectedTenant.map { deployService.isRemoving($0.id) } ?? true
                            || deployService.isEngineWorkRunning)
                    Divider()
                    Button("Roll Out…") {
                        appState.selection = .fleet
                        appState.request(.rollOut)
                    }
                    .disabled(deployService.isDemo || deployService.isBusy
                        || tenantStore.tenants.filter(deployService.canRollOut).count < 2)
                    if deployService.isTeamMode {
                        Button("Sync Now") {
                            Task { await deployService.syncTeamState() }
                        }
                        .disabled(deployService.isBusy)
                        Button("Force Unlock…") { appState.request(.forceUnlock) }
                            .disabled(selectedTenant.map { deployService.lock(for: $0.id) == nil } ?? true
                                || deployService.isEngineWorkRunning)
                    }
                }
                // one sheet at a time: nothing here opens another over it
                .disabled(appState.isSheetOpen)
            }
            CommandMenu("Catalog") {
                Group {
                    Button("Manage Sources…") {
                        appState.selection = .catalog
                        appState.request(.manageSources)
                    }
                    .disabled(deployService.isDemo)
                    Button("Add Git Catalog…") {
                        appState.selection = .catalog
                        appState.request(.addGitCatalog)
                    }
                    .disabled(deployService.isDemo)
                }
                // one sheet at a time: nothing here opens another over it
                .disabled(appState.isSheetOpen)
            }
            CommandGroup(after: .help) {
                Button("Guided Tour") {
                    tour.start()
                }
                Link("Graduating to Terraform", destination: DocsLinks.graduating)
            }
        }
    }

    private var tenantStore: TenantStore { worlds.active.tenantStore }
    private var deployService: TenantDeployService { worlds.active.deployService }
    private var appState: AppState { worlds.active.appState }

    @AppStorage("showsTechnicalDetails") private var showsTechnicalDetails = false

    private var selectedTenant: Tenant? {
        appState.selectedTenantID.flatMap { tenantStore.tenant(id: $0) }
    }

    /// As the tenant's Check for Changes toolbar button.
    private var selectedTenantCanCheck: Bool {
        guard let tenant = selectedTenant else { return false }
        return deployService.isManaged(tenant) && !tenant.isHandedOver
            && !deployService.isBusy && deployService.fleetCheckProgress == nil
    }

    /// Adopt and custom objects, as on the tenant's page: not in demo mode,
    /// nor once the tenant is (being) handed over.
    private var selectedTenantCanChange: Bool {
        guard let tenant = selectedTenant else { return false }
        return !deployService.isDemo && !tenant.isHandedOver && !tenant.handOverPending && !deployService.isBusy
    }

    /// The stores the Team and Advanced tabs read: always the real ones.
    private func withStores(_ content: some View) -> some View {
        content
            .environment(worlds.real.tenantStore)
            .environment(worlds.real.catalogSources)
            .environment(worlds.real.deployService)
            .environment(componentUpdates)
            .environment(activityLog)
            .environment(worlds.demo)
    }
}
