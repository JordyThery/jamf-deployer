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

    init() {
        let activityLog = ActivityLog()
        // Demo Mode in the Tenant menu, saved under "demoMode"
        let demo = DemoMode(key: "demoMode")
        if demo.isSandbox { DemoSecretVault.keepEverythingInMemory() }
        let worlds = AppWorlds(demo: demo, activityLog: activityLog)
        _worlds = State(initialValue: worlds)
        _activityLog = State(initialValue: activityLog)
        // Settings › Connections: always the real tenants (their own
        // tenant.json files and Keychain items, unchanged), also in demo mode
        let real = worlds.real
        let storage = TenantConnectionStorage(
            tenantStore: real.tenantStore,
            backupURL: demo.isSandbox ? demo.scratchDirectory.appending(path: "connection-backup")
                : TenantConnectionStorage.defaultBackupURL,
            signInID: { tenant in real.deployService.isTeamMode ? tenant.engineerClientID : nil }
        )
        _connections = State(initialValue: ConnectionStore(
            storage: storage,
            secrets: demo.isSandbox ? TenantSecrets.sandboxConnectionSecrets : TenantSecrets.connectionSecrets,
            log: { message in
                Logger(subsystem: "be.jordythery.jamf-deployer", category: "Connections").error("\(message, privacy: .public)")
            }
        ))
        Task.detached(priority: .background) { JamformerRunner.removeStaleExports() }
    }

    @State private var updates = UpdateChecker(
        configuration: UpdateConfiguration(owner: "JordyThery", repository: "jamf-deployer", appName: "Jamf Deployer")
    )
    @State private var tour = JamfDeployerTour.makeState()

    var body: some Scene {
        Window("Jamf Deployer", id: "main") {
            if Self.isUnitTestHost {
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

        // General (Appearance first), Connections, Team, Advanced, then Updates.
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
            CommandMenu("Tenant") {
                // No connection picker in this app: the switch lives here.
                DemoModeToggle(demo: worlds.demo)
                    .disabled(worlds.isBusy)
                Divider()
                Button("Check for Changes", systemImage: "arrow.clockwise") {
                    if let id = appState.selectedTenantID,
                       let tenant = tenantStore.tenant(id: id) {
                        Task { await deployService.checkDriftRecordingFailure(tenant: tenant) }
                    } else {
                        Task { await deployService.checkAllTenants() }
                    }
                }
                .keyboardShortcut("r")
                .disabled(deployService.isBusy || deployService.fleetCheckProgress != nil)

                Button("Preview Changes", systemImage: "list.bullet.clipboard") {
                    appState.previewRequestCount += 1
                }
                .keyboardShortcut("p")
                .disabled(appState.selectedTenantID == nil || deployService.isBusy)

                // Deploying always goes through a preview; ⌘D opens the same
                // sheet, whose flow ends in the confirmed Deploy.
                Button("Deploy…", systemImage: "paperplane") {
                    appState.previewRequestCount += 1
                }
                .keyboardShortcut("d")
                .disabled(appState.selectedTenantID == nil || deployService.isBusy)
            }
            CommandGroup(after: .help) {
                Button("Guided Tour") {
                    tour.start()
                }
                Link("Graduating to Terraform", destination: DocsLinks.graduating)
            }
        }
    }

    /// Set by Xcode when the app hosts the unit tests (Jamf DeployerTests).
    private static let isUnitTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    private var tenantStore: TenantStore { worlds.active.tenantStore }
    private var deployService: TenantDeployService { worlds.active.deployService }
    private var appState: AppState { worlds.active.appState }

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
