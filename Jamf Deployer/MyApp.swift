import SwiftUI
import DeployerKit

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

    init() {
        let tenantStore = TenantStore()
        let activityLog = ActivityLog()
        let catalogSources = CatalogSourceStore()
        _tenantStore = State(initialValue: tenantStore)
        _activityLog = State(initialValue: activityLog)
        _catalogSources = State(initialValue: catalogSources)
        _deployService = State(initialValue: TenantDeployService(
            tenantStore: tenantStore,
            activityLog: activityLog,
            catalogSources: catalogSources
        ))
        Task.detached(priority: .background) { JamformerRunner.removeStaleExports() }
    }

    @State private var updates = UpdateChecker(
        feed: UpdateFeed(owner: "JordyThery", repository: "jamf-deployer", appName: "Jamf Deployer")
    )
    @State private var tour = JamfDeployerTour.makeState()

    @AppStorage("showsTechnicalDetails") private var showsTechnicalDetails = false

    var body: some Scene {
        Window("Jamf Deployer", id: "main") {
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

        Window("Activity Log", id: "activity-log") {
            ActivityLogView(
                log: activityLog,
                emptyDescription: "Calls to Jamf and engine runs appear here as they happen."
            )
            .frame(minWidth: 640, minHeight: 320)
        }
        .keyboardShortcut("l", modifiers: [.command, .shift])

        Window("About Jamf Deployer", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Settings {
            SettingsView()
                .environment(tenantStore)
                .environment(catalogSources)
                .environment(deployService)
                .environment(componentUpdates)
                .environment(activityLog)
        }

        .commands {
            CommandGroup(replacing: .appInfo) {
                AboutCommand()
                Button("Check for Updates…") {
                    updates.checkManually()
                }
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
}

/// Opens the custom About window from the app menu.
private struct AboutCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About Jamf Deployer") {
            openWindow(id: "about")
        }
    }
}
