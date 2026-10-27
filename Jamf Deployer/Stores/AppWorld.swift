import Foundation
import JTKit

/// The stores and services the main window works on: the real ones, or
/// demo mode's. Demo mode's have their own store in demo mode's temporary
/// folder, so the real store, its Git history and the team space are never
/// read or written while it's on.
@MainActor
final class AppWorld: Identifiable {
    let id = UUID()
    let tenantStore: TenantStore
    let catalogSources: CatalogSourceStore
    let deployService: TenantDeployService
    let appState = AppState()
    let exportSessions = ExportSessionStore()
    let isDemo: Bool

    private init(tenantStore: TenantStore, catalogSources: CatalogSourceStore, deployService: TenantDeployService,
                 isDemo: Bool) {
        self.tenantStore = tenantStore
        self.catalogSources = catalogSources
        self.deployService = deployService
        self.isDemo = isDemo
    }

    /// The real store; in a sandbox run (`-JTKitSandbox YES`) a throwaway
    /// store in demo mode's temporary folder instead.
    static func real(activityLog: ActivityLog, sandboxFolder: URL?) -> AppWorld {
        let storeURL = sandboxFolder?.appending(path: "store") ?? GitStoreService.storeURL
        let tenantStore = TenantStore(rootURL: storeURL.appending(path: "tenants"))
        let catalogSources = CatalogSourceStore(fileURL: storeURL.appending(path: "catalog-sources.json"), tools: .app)
        let deployService = TenantDeployService(tenantStore: tenantStore, activityLog: activityLog,
                                                catalogSources: catalogSources, storeURL: storeURL, tools: .app)
        return AppWorld(tenantStore: tenantStore, catalogSources: catalogSources, deployService: deployService,
                        isDemo: false)
    }

    /// Demo mode's: Contoso's tenants in a store of its own, the doorway
    /// that never starts OpenTofu, jamformer or git, and JTKit's demo servers.
    static func demo(_ demo: DemoMode, activityLog: ActivityLog, tools: ToolDoorway = .demo) -> AppWorld {
        let storeURL = demo.scratchDirectory.appending(path: "store")
        let tenantStore = TenantStore(rootURL: storeURL.appending(path: "tenants"))
        let catalogSources = CatalogSourceStore(fileURL: storeURL.appending(path: "catalog-sources.json"), tools: tools)
        let deployService = TenantDeployService(tenantStore: tenantStore, activityLog: activityLog,
                                                catalogSources: catalogSources, storeURL: storeURL, tools: tools,
                                                isDemo: true)
        DemoFleet.start(demo, store: tenantStore)
        return AppWorld(tenantStore: tenantStore, catalogSources: catalogSources, deployService: deployService,
                        isDemo: true)
    }
}

/// The real world and, once demo mode was turned on, demo mode's, kept
/// until the app quits so what's done in demo mode stays for the launch.
@MainActor
@Observable
final class AppWorlds {
    let demo: DemoMode
    let real: AppWorld
    @ObservationIgnored private let activityLog: ActivityLog
    @ObservationIgnored private var demoWorld: AppWorld?

    init(demo: DemoMode, activityLog: ActivityLog) {
        self.demo = demo
        self.activityLog = activityLog
        real = .real(activityLog: activityLog, sandboxFolder: demo.isSandbox ? demo.scratchDirectory : nil)
        ToolDoorway.setDemoMode(demo.isOn)
    }

    /// The world the main window shows now.
    var active: AppWorld {
        guard demo.isOn else { return real }
        if let demoWorld { return demoWorld }
        let created = AppWorld.demo(demo, activityLog: activityLog)
        demoWorld = created
        return created
    }

    /// Engine work, a check or a removal running in either world: the
    /// switch waits for it.
    var isBusy: Bool {
        [real, demoWorld].compactMap(\.self).contains {
            $0.deployService.isBusy || $0.deployService.fleetCheckProgress != nil
        }
    }
}
