import Foundation
import JamfDeployerCore
import JTKit
import os

/// Demo mode's tenants: which they are, what they connect to and the
/// secrets they use, none of it ever in the Keychain or the real store.
///
/// A demo tenant has an ID in JTKit's fake range (or a `.demo.invalid`
/// address), connects through JTKit's demo network to JTKit's demo servers,
/// and signs in with a fixed fake secret.
nonisolated enum DemoTenants {
    /// "Contoso (Demo)": Jamf Platform API, production, deployed, one change made in Jamf.
    static let contosoID = UUID(uuidString: DemoSamples.uuid(0xd101)) ?? UUID()
    /// "Contoso Lab (Demo)": Jamf Pro API, a test tenant, deployed, in sync.
    static let labID = UUID(uuidString: DemoSamples.uuid(0xd102)) ?? UUID()

    /// Whether the tenant is one of demo mode's: by ID, environment or address.
    static func isDemo(_ tenant: Tenant) -> Bool {
        let ids = [tenant.id.uuidString, tenant.environmentID ?? "", tenant.tenantID ?? ""]
        if ids.contains(where: DemoSamples.isDemoID) { return true }
        let host = tenant.jamfProURL.flatMap { URL(string: $0)?.host() }?.lowercased() ?? ""
        return host.hasSuffix("." + DemoNetwork.reservedDomain)
    }

    /// The JTKit demo connection a demo tenant uses: the Platform demo, or
    /// the Jamf Pro demo at the tenant's address.
    static func connection(for tenant: Tenant) -> Connection? {
        guard isDemo(tenant) else { return nil }
        guard tenant.isJamfPro else { return .demoJamfPlatform }
        let host = tenant.jamfProURL.flatMap { URL(string: $0)?.host() }?.lowercased()
        return [Connection.demoJamfProSource, .demoJamfProDestination]
            .first { URL(string: $0.serverURL)?.host()?.lowercased() == host }
    }

    /// The demo connection the Connect a Tenant wizard offers in demo mode:
    /// the Platform demo, or a fresh Jamf Pro tenant.
    static func wizardConnection(for kind: ConnectionKind) -> Connection {
        kind == .jamfPro ? .demoJamfProDestination : .demoJamfPlatform
    }

    /// An ID in the fake range for a tenant the wizard adds in demo mode.
    static func newTenantID() -> UUID {
        let number = nextNumber.withLock { value -> Int in
            value += 1
            return value
        }
        return UUID(uuidString: DemoSamples.uuid(number)) ?? UUID()
    }

    private static let nextNumber = OSAllocatedUnfairLock(initialState: 0xd200)

    // MARK: Where demo tenants connect

    /// The demo sources, set once demo mode starts (`DemoFleet`).
    private static let sources = OSAllocatedUnfairLock<[UUID: DemoSource]>(initialState: [:])

    static func register(_ source: DemoSource) {
        sources.withLock { $0[source.connection.id] = source }
    }

    static func source(for tenant: Tenant) -> DemoSource? {
        guard let connection = connection(for: tenant) else { return nil }
        return sources.withLock { $0[connection.id] }
    }

    /// The client for a demo tenant: JTKit's demo network, its fake secret.
    /// Without a demo source (demo mode never started) every request fails
    /// inside the app; a demo tenant never reaches the network.
    static func client(for tenant: Tenant, activityLog: ActivityLog?) -> JamfPlatformClient {
        guard let source = source(for: tenant) else {
            return JamfPlatformClient(configuration: JamfAPIConfiguration(unreachableDemo: tenant), activityLog: activityLog,
                                      session: DemoNetwork(servers: [:]).session)
        }
        return JamfPlatformClient(configuration: JamfAPIConfiguration(demo: source, tenant: tenant),
                                  activityLog: activityLog, session: source.session)
    }

    /// The environments the wizard lists in demo mode.
    static func environments(activityLog: ActivityLog?) async throws -> [JamfPlatform.Environment] {
        guard let source = sources.withLock({ $0[Connection.demoJamfPlatform.id] }) else { return [] }
        let recorder = RequestRecorder(session: source.session, log: activityLog, category: "API",
                                       service: "Jamf Platform API", connection: source.connection.name)
        return try await JamfPlatform.environments(for: source.connection, secret: source.secret, recorder: recorder)
    }
}

nonisolated extension JamfAPIConfiguration {
    /// A demo tenant on JTKit's demo network: the demo service's address,
    /// client ID and fake secret.
    init(demo source: DemoSource, tenant: Tenant) {
        let connection = source.connection
        clientID = connection.clientID
        secret = source.secret
        connectionName = tenant.name
        if tenant.isJamfPro {
            gatewayURL = Self.instanceURL(connection.serverURL) ?? URL(filePath: "/")
            flavor = .jamfProAPIClient
        } else {
            gatewayURL = URL(string: "https://\(connection.hostOverride)") ?? URL(filePath: "/")
            scope = .environment(connection.environmentID)
        }
    }

    /// A demo tenant whose demo source is missing: nothing is sent.
    init(unreachableDemo tenant: Tenant) {
        gatewayURL = URL(string: "https://\(DemoNetwork.reservedDomain)") ?? URL(filePath: "/")
        flavor = tenant.isJamfPro ? .jamfProAPIClient : .platform
        clientID = tenant.clientID
        secret = { "" }
        hasInvalidInstanceURL = true
        connectionName = tenant.name
    }
}

/// Demo tenants' Keychain items, kept in memory for the launch instead:
/// a demo tenant's client secret reads back as a fixed fake one, and what
/// demo mode saves (a block's secret setting, say) is forgotten at quit.
/// The Keychain is never read or written for them.
nonisolated enum DemoSecretVault {
    private static let items = OSAllocatedUnfairLock<[String: String]>(initialState: [:])
    private static let keepsEverything = OSAllocatedUnfairLock(initialState: false)

    /// A sandbox run (`-JTKitSandbox YES`): every item is kept in memory.
    static func keepEverythingInMemory() {
        keepsEverything.withLock { $0 = true }
    }

    /// Whether a Keychain account's items stay in memory: a demo tenant's,
    /// or any in a sandbox run.
    static func keepsInMemory(account: String) -> Bool {
        DemoSamples.isDemoID(account) || keepsEverything.withLock { $0 }
    }

    static func load(service: String, account: String) -> String? {
        items.withLock { items in
            items["\(service)|\(account)"]
                ?? (DemoSamples.isDemoID(account) && service.hasSuffix(".platform-client-secret")
                    ? DemoSecretStore().secret(for: account) : nil)
        }
    }

    static func save(_ value: String?, service: String, account: String) {
        items.withLock { $0["\(service)|\(account)"] = value }
    }

    static func deleteAll(service: String, accountPrefix prefix: String) {
        items.withLock { items in
            items = items.filter { !$0.key.hasPrefix("\(service)|\(prefix)") }
        }
    }
}

/// Starts demo mode's fleet: the demo servers' Jamf objects for the two
/// Contoso tenants, the sources their clients use, and the tenants in the
/// demo store.
@MainActor
enum DemoFleet {
    static func start(_ demo: DemoMode, store: TenantStore) {
        for connection in [Connection.demoJamfPlatform, .demoJamfProSource, .demoJamfProDestination] {
            if let source = demo.source(for: connection) { DemoTenants.register(source) }
        }
        // What Jamf holds now: Teams was changed in Jamf on Contoso, Firefox
        // on the lab matches what was deployed.
        demo.jamfPlatformServer.jamfPro?.add(
            DemoDrift.deployed[DemoTenants.contosoID]?.map { $0.jamfObject(changedInJamf: true) } ?? [],
            at: DemoDrift.appInstallerPath)
        demo.jamfProSourceServer.objects?.add(
            DemoDrift.deployed[DemoTenants.labID]?.map { $0.jamfObject(changedInJamf: false) } ?? [],
            at: DemoDrift.appInstallerPath)
        for tenant in seededTenants() where store.tenant(id: tenant.id) == nil {
            store.add(tenant)
        }
    }

    /// Contoso's two tenants, as after a deploy a few days ago.
    static func seededTenants() -> [Tenant] {
        let deployed = Calendar.current.date(byAdding: .day, value: -3, to: .now) ?? .now
        let platform = Connection.demoJamfPlatform
        var contoso = Tenant(id: DemoTenants.contosoID, name: platform.name, region: platform.region,
                             clientID: platform.clientID, environmentID: platform.environmentID, isProduction: true)
        contoso.blockSelections = [appCatalog(["Microsoft Teams", "Google Chrome", "Slack", "Zoom"])]
        contoso.deployedBlockVersions = ["app-catalog": "1.0.0"]
        contoso.lastDeploy = DeployRecord(date: deployed, engineerName: "Avery Sample", succeeded: 1, failed: 0)
        contoso.day0 = Day0Status(apnsConfirmedDate: Calendar.current.date(byAdding: .month, value: -2, to: .now))
        contoso.createdAt = Calendar.current.date(byAdding: .month, value: -2, to: .now) ?? .now

        let source = Connection.demoJamfProSource
        var lab = Tenant(id: DemoTenants.labID, name: "Contoso Lab (Demo)", region: .us, clientID: source.clientID,
                         environmentID: nil, isProduction: false, connection: .jamfPro,
                         jamfProURL: source.serverURL, jamfProAuth: .apiClient)
        lab.blockSelections = [appCatalog(["Mozilla Firefox"])]
        lab.deployedBlockVersions = ["app-catalog": "1.0.0"]
        lab.lastDeploy = DeployRecord(date: deployed, engineerName: "Avery Sample", succeeded: 1, failed: 0)
        lab.createdAt = Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now
        return [contoso, lab]
    }

    /// The App Catalog block with `apps`, on Contoso's managed Macs.
    private static func appCatalog(_ apps: [String]) -> BlockSelection {
        let items = apps.map { name in
            ["titleName": name, "publisher": DemoDrift.publishers[name] ?? "",
             "deploymentType": "INSTALL_AUTOMATICALLY", "updateBehavior": "AUTOMATIC"]
        }
        let json = (try? JSONSerialization.data(withJSONObject: items, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        var selection = BlockSelection(blockID: "app-catalog", settings: ["apps_json": json])
        selection.existingScope = ExistingObjectRef(id: "1", name: "All Managed Clients")
        selection.existingCategory = ExistingObjectRef(id: "2", name: "Contoso Apps")
        return selection
    }
}

/// "Check for Changes" in demo mode: what the engine's refresh-only plan
/// would find, read from the demo server with the tenant's real client and
/// compared with what was last deployed. Nothing is started.
nonisolated enum DemoDrift {
    static let appInstallerPath = "v1/app-installers/deployments"

    /// The App Catalog's titles the demo uses, by name.
    static let titleIDs = ["Microsoft Teams": "1D2", "Google Chrome": "0BC", "Slack": "1F0", "Zoom": "2A7",
                           "Mozilla Firefox": "0C4"]
    static let publishers = ["Microsoft Teams": "Microsoft", "Google Chrome": "Google", "Slack": "Slack Technologies",
                             "Zoom": "Zoom Video Communications", "Mozilla Firefox": "Mozilla"]

    /// One App Installer deployment as the last deploy left it.
    struct DeployedObject: Sendable {
        var jamfID: Int
        var title: String
        var isJamfPro: Bool

        var resourceType: String { isJamfPro ? "jamfpro_app_installer" : "jamfplatform_pro_app_installer" }
        var address: String { "module.app_catalog.\(resourceType).app[\"\(title)\"]" }

        /// The engine's attributes, as deployed.
        var values: [String: Any] {
            ["id": "\(jamfID)", "name": "JD - \(title)", "app_title_name": title,
             "deployment_type": "INSTALL_AUTOMATICALLY", "update_behavior": "AUTOMATIC",
             "category_id": "2", "smart_group_id": "1", "enabled": true]
        }

        /// The object in Jamf; `changedInJamf`: someone set its updates to manual there.
        func jamfObject(changedInJamf: Bool) -> LosslessJSON.Object {
            LosslessJSON.Object([
                "id": .string("\(jamfID)"), "name": .string("JD - \(title)"),
                "appTitleId": .string(DemoDrift.titleIDs[title] ?? ""), "enabled": .bool(true),
                "deploymentType": .string("INSTALL_AUTOMATICALLY"),
                "updateBehavior": .string(changedInJamf ? "MANUAL" : "AUTOMATIC"),
                "categoryId": .string("2"), "siteId": .string("-1"), "smartGroupId": .string("1"),
                "installPredefinedConfigProfiles": .bool(false), "triggerAdminNotifications": .bool(false),
            ])
        }
    }

    /// What each seeded tenant's last deploy left in Jamf.
    static let deployed: [UUID: [DeployedObject]] = [
        DemoTenants.contosoID: [DeployedObject(jamfID: 501, title: "Microsoft Teams", isJamfPro: false)],
        DemoTenants.labID: [DeployedObject(jamfID: 501, title: "Mozilla Firefox", isJamfPro: true)],
    ]

    /// A refresh-only plan (`tofu show -json` form) for the tenant: one
    /// drifted resource per deployed object whose values in Jamf differ.
    static func refreshPlan(for tenant: Tenant, client: JamfPlatformClient) async throws -> PlanFile {
        nonisolated struct Title: Decodable, Sendable { let id: String; let titleName: String }
        let objects = deployed[tenant.id] ?? []
        let titles = objects.isEmpty ? [] : try await client.allPages("/pro/v1/app-installers/titles", as: Title.self,
                                                                      privileges: [.readMacApplications])
        var drift: [[String: Any]] = []
        for object in objects {
            let (data, status) = try await client.get("/pro/\(appInstallerPath)/\(object.jamfID)",
                                                      privileges: [.readMacApplications])
            // gone from Jamf: a refresh drops it, with nothing to compare
            guard status == 200, let now = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let before = object.values
            var after = before
            after["name"] = now["name"]
            after["app_title_name"] = titles.first { $0.id == "\(now["appTitleId"] ?? "")" }?.titleName ?? before["app_title_name"]
            after["deployment_type"] = now["deploymentType"]
            after["update_behavior"] = now["updateBehavior"]
            after["category_id"] = now["categoryId"]
            after["smart_group_id"] = now["smartGroupId"]
            after["enabled"] = now["enabled"]
            guard !NSDictionary(dictionary: before).isEqual(to: after) else { continue }
            drift.append(["address": object.address, "type": object.resourceType, "name": "app",
                          "change": ["actions": ["update"], "before": before, "after": after]])
        }
        return try decodePlan(["format_version": "1.2", "resource_drift": drift])
    }

    static func decodePlan(_ plan: [String: Any]) throws -> PlanFile {
        try JSONDecoder().decode(PlanFile.self, from: JSONSerialization.data(withJSONObject: plan))
    }
}

/// Deploy in demo mode: a fixed plan, read by the real preview, that stops
/// there. On "Contoso (Demo)" the three App Installers its baseline adds and
/// the update that reverts the change found in Jamf; on any other demo
/// tenant, nothing to deploy.
nonisolated enum DemoPlan {
    static func plan(for tenant: Tenant) throws -> (PlanFile, [EngineStreamEvent.Diagnostic]) {
        guard tenant.id == DemoTenants.contosoID else {
            return (try DemoDrift.decodePlan(["format_version": "1.2", "resource_changes": [] as [Any]]), [])
        }
        var changes: [[String: Any]] = []
        var reasons: [[String: Any]] = []
        for title in ["Google Chrome", "Slack", "Zoom"] {
            let object = DemoDrift.DeployedObject(jamfID: 0, title: title, isJamfPro: false)
            var after = object.values
            after["id"] = nil
            changes.append(["address": object.address, "type": object.resourceType, "name": "app",
                            "change": ["actions": ["create"], "before": NSNull(), "after": after,
                                       "after_unknown": ["id": true]]])
            reasons.append(reason("New in the baseline: the App Catalog block installs \(title) on All Managed Clients.",
                                  address: object.address))
        }
        let teams = DemoDrift.DeployedObject(jamfID: 501, title: "Microsoft Teams", isJamfPro: false)
        var inJamf = teams.values
        inJamf["update_behavior"] = "MANUAL"
        changes.append(["address": teams.address, "type": teams.resourceType, "name": "app",
                        "change": ["actions": ["update"], "before": inJamf, "after": teams.values]])
        reasons.append(reason("Reverts the change found in Jamf: updates were set to manual there; the baseline installs them automatically.",
                              address: teams.address))

        let plan = try DemoDrift.decodePlan(["format_version": "1.2", "resource_changes": changes])
        let diagnostics = try JSONDecoder().decode([EngineStreamEvent.Diagnostic].self,
                                                   from: JSONSerialization.data(withJSONObject: reasons))
        return (plan, diagnostics)
    }

    private static func reason(_ text: String, address: String) -> [String: Any] {
        ["severity": "warning", "summary": text, "address": address]
    }
}
