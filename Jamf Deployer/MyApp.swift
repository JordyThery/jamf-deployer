import SwiftUI
import JTKit
import os

@main
struct MyApp: App {
    @State private var tenantStore: TenantStore
    @State private var activityLog: ActivityLog
    @State private var deployService: TenantDeployService
    @State private var appState = AppState()
    @State private var terraform = TerraformManager()
    @State private var exportSessions = ExportSessionStore()
    @State private var componentUpdates = ComponentUpdateChecker()
    @State private var catalogSources: CatalogSourceStore
    @State private var connections: ConnectionStore<TenantConnection>

    init() {
        let tenantStore = TenantStore()
        let activityLog = ActivityLog()
        let catalogSources = CatalogSourceStore()
        let deployService = TenantDeployService(
            tenantStore: tenantStore,
            activityLog: activityLog,
            catalogSources: catalogSources
        )
        _tenantStore = State(initialValue: tenantStore)
        _activityLog = State(initialValue: activityLog)
        _catalogSources = State(initialValue: catalogSources)
        _deployService = State(initialValue: deployService)
        // Settings › Connections: the tenants' own tenant.json files and
        // Keychain items, unchanged
        let storage = TenantConnectionStorage(
            tenantStore: tenantStore,
            backupURL: TenantConnectionStorage.defaultBackupURL,
            signInID: { tenant in deployService.isTeamMode ? tenant.engineerClientID : nil }
        )
        _connections = State(initialValue: ConnectionStore(
            storage: storage,
            secrets: TenantSecrets.connectionSecrets,
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
                ContentView()
                    .environment(tenantStore)
                    .environment(activityLog)
                    .environment(updates)
                    .environment(tour)
                    .environment(deployService)
                    .environment(appState)
                    .environment(terraform)
                    .environment(catalogSources)
                    .environment(componentUpdates)
                    .environment(exportSessions)
            }
        }

        Window("Activity Log", id: "activity-log") {
            ActivityLogView(
                log: activityLog,
                emptyDescription: "Calls to Jamf and engine runs appear here as they happen."
            )
            .frame(minWidth: 640, minHeight: 320)
        }
        .keyboardShortcut("l", modifiers: [.command, .shift])

        AboutWindow(configuration: .jamfDeployer)

        // General (Appearance first), Connections, Team, Advanced, then Updates.
        SettingsWindow(updates: updates) {
            GeneralSettingsSections()
        } tabs: {
            withStores(TenantConnectionsTab(store: connections))
            SettingsTab("Team", systemImage: "person.2") {
                withStores(TeamSettingsView())
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

    /// The stores the Team and Advanced tabs read.
    private func withStores(_ content: some View) -> some View {
        content
            .environment(tenantStore)
            .environment(catalogSources)
            .environment(deployService)
            .environment(componentUpdates)
            .environment(activityLog)
    }
}
