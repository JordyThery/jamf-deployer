import Foundation
import os
import Testing
import JamfDeployerCore
import JTKit
@testable import Jamf_Deployer

// ROADMAP step 10: demo mode runs the Connect wizard's checks, Day 0, the
// lookups and Check for Changes against JTKit's demo servers, shows a fixed
// plan, and never starts OpenTofu, jamformer or git, nor touches the real
// store or the Keychain.

@MainActor
private func demoMode() -> DemoMode {
    let defaults = UserDefaults(suiteName: "jamf-deployer-demo-\(UUID().uuidString)") ?? .standard
    return DemoMode(key: "demoMode", defaults: defaults, arguments: ["app"])
}

/// Every launch the doorway was asked for.
private final class Attempts: Sendable {
    private let tools = OSAllocatedUnfairLock<[ExternalTool]>(initialState: [])
    var all: [ExternalTool] { tools.withLock { $0 } }
    func record(_ tool: ExternalTool) { tools.withLock { $0.append(tool) } }
}

/// The names and modification dates of everything in a folder, to show it was left alone.
private func fingerprint(_ folder: URL) -> [String: Date] {
    let keys: [URLResourceKey] = [.contentModificationDateKey]
    guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return [:] }
    var result: [String: Date] = [:]
    for case let file as URL in files {
        result[file.path] = (try? file.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
    }
    return result
}

@MainActor
@Suite("Demo mode", .serialized)
struct DemoModeTests {

    @Test("Demo mode never starts OpenTofu, jamformer or git, from connecting a tenant to deploying")
    func neverStartsTools() async throws {
        let realStore = fingerprint(GitStoreService.storeURL)
        let attempts = Attempts()
        let demo = demoMode()
        let log = ActivityLog()
        let world = AppWorld.demo(demo, activityLog: log, tools: .trap { attempts.record($0) })
        let service = world.deployService
        #expect(world.tenantStore.rootURL.path.hasPrefix(demo.scratchDirectory.path))
        #expect(world.tenantStore.tenants.map(\.name) == ["Contoso (Demo)", "Contoso Lab (Demo)"])

        // Connect a Tenant: a fresh Jamf Pro tenant from the wizard, its preflight on the demo server
        let connection = DemoTenants.wizardConnection(for: .jamfPro)
        let fresh = Tenant(id: DemoTenants.newTenantID(), name: "Contoso New", region: .us, clientID: connection.clientID,
                           environmentID: nil, isProduction: false, connection: .jamfPro,
                           jamfProURL: connection.serverURL, jamfProAuth: .apiClient)
        let report = await PreflightService.run(client: DemoTenants.client(for: fresh, activityLog: log),
                                                connection: .jamfPro) { _ in }
        #expect(report.checks.first { $0.id == "auth" }?.outcome == .pass)
        #expect(report.snapshot.jamfProVersion?.hasPrefix("11.") == true)
        #expect(TenantSecrets(tenantID: fresh.id).platformClientSecret.save("demo-secret"))
        world.tenantStore.add(fresh)

        // Day 0 on the fresh tenant: what's missing is set up against the demo server
        let day0 = Day0Service(activityLog: log)
        await day0.detect(tenant: fresh)
        #expect(day0.steps.first { $0.id == "vpp" }.map { if case .pending = $0.state { true } else { false } } == true)
        try await day0.uploadVPPToken(tenant: fresh, tokenFile: Data("ZGVtbw==".utf8), name: "Contoso New Apps")
        try await day0.createBranding(tenant: fresh, brandingName: "Contoso New")
        _ = try await day0.downloadADEPublicKey(tenant: fresh)
        try await day0.uploadADEToken(tenant: fresh, tokenFile: Data("demo".utf8), name: "Contoso New ABM.p7m")
        try await day0.registerProtect(tenant: fresh, protectURL: "https://contoso.protect.demo.invalid",
                                       clientID: "demo-client", password: "demo-password")
        await day0.detect(tenant: fresh)
        for step in ["ade", "vpp", "branding", "protect"] {
            #expect(day0.steps.first { $0.id == step }.map { if case .done = $0.state { true } else { false } } == true,
                    "\(step) is done")
        }

        // Day 0 and the block pickers' lookups on Contoso's Platform tenant, through the gateway
        guard let contoso = world.tenantStore.tenant(id: DemoTenants.contosoID),
              let lab = world.tenantStore.tenant(id: DemoTenants.labID) else {
            Issue.record("The demo fleet is missing")
            return
        }
        await day0.detect(tenant: contoso)
        #expect(day0.steps.first { $0.id == "ade" }.map { if case .done = $0.state { true } else { false } } == true)
        #expect(!(try await ExistingObjectService.computerGroups(tenant: contoso, activityLog: log)).isEmpty)
        #expect(!(try await ExistingObjectService.mobileDeviceGroups(tenant: lab, activityLog: log)).isEmpty)
        #expect(!(try await ExistingObjectService.categories(tenant: contoso, activityLog: log)).isEmpty)

        // Check for Changes: the change made in Jamf on Contoso, nothing on the lab
        try await service.checkDrift(tenant: contoso)
        let drifted = try #require(world.tenantStore.tenant(id: contoso.id)?.driftReport?.actionableObjects)
        #expect(drifted.map(\.displayName) == ["JD - Microsoft Teams"])
        #expect(drifted.first?.fields.map(\.path) == ["update_behavior"])
        #expect(drifted.first?.fields.first?.after.contains("MANUAL") == true)
        try await service.checkDrift(tenant: lab)
        #expect(world.tenantStore.tenant(id: lab.id)?.driftReport?.objects.isEmpty == true)
        if let field = drifted.first?.fields.first, let object = drifted.first,
           let checked = world.tenantStore.tenant(id: contoso.id) {
            service.keepDrift(tenant: checked, object: object, field: field)
        }

        // Deploy: the fixed plan, then it stops
        let session = try await service.preview(tenant: contoso)
        #expect(session.summary.counts[.create] == 3 && session.summary.counts[.update] == 1)
        let changes = session.summary.groups.flatMap(\.changes)
        #expect(Set(changes.filter { $0.kind == .create }.map(\.displayName))
            == ["JD - Google Chrome", "JD - Slack", "JD - Zoom"])
        let update = try #require(changes.first { $0.kind == .update })
        #expect(update.displayName == "JD - Microsoft Teams")
        #expect(update.notes.first?.hasPrefix("Reverts the change found in Jamf") == true)
        #expect(update.fieldDiffs.map(\.path) == ["update_behavior"])
        #expect(changes.allSatisfy { !$0.notes.isEmpty }, "every change says why")
        #expect(session.summary.groups.map(\.blockName) == ["App Catalog"])
        await #expect(throws: TenantDeployService.DeployError.self) {
            _ = try await service.deploy(tenant: contoso, session: session)
        }
        service.abandonPreview(tenant: contoso)
        #expect(try await service.preview(tenant: lab).summary.isEmpty)
        service.abandonPreview(tenant: lab)

        // Everything else that would start them is refused before it starts
        await #expect(throws: TenantDeployService.DeployError.self) {
            _ = try await service.exportRepository([contoso], to: demo.scratchDirectory.appending(path: "export"), remote: nil)
        }
        await #expect(throws: TenantDeployService.DeployError.self) { try await service.moveStateToTeam(tenants: [contoso]) }
        await #expect(throws: TenantDeployService.DeployError.self) { try await service.moveStateToLocal() }
        await #expect(throws: TenantDeployService.DeployError.self) { _ = try await service.commitStore(message: "demo") }
        #expect(try await service.availableBaselineUpdates(for: contoso).isEmpty)
        await service.syncTeamState()
        await service.checkExistingStoreOnce()
        #expect(!service.isTeamMode)

        // Remove Tenant: only from the demo store
        try await service.removeTenant(fresh)
        #expect(world.tenantStore.tenant(id: fresh.id) == nil)

        #expect(attempts.all.isEmpty, "nothing asked to start: \(attempts.all)")
        #expect(demo.jamfPlatformServer.requestCount > 0 && (demo.jamfProDestinationServer.objects?.requestCount ?? 0) > 0)
        #expect(fingerprint(GitStoreService.storeURL) == realStore, "the real store is left alone")

        // and the parts that would start one, called directly, are refused by the doorway
        let tools = service.tools
        await #expect(throws: ToolDoorway.Refused.self) {
            _ = try await JamformerRunner(tools: tools).listResourceTypes(provider: "jamfpro")
        }
        await #expect(throws: ToolDoorway.Refused.self) { _ = try await service.gitStore.commitAll(message: "demo") }
        await #expect(throws: ToolDoorway.Refused.self) {
            _ = try await GitCatalogManager.availableTags(remote: "https://github.com/JordyThery/jamf-deployer-catalog.git",
                                                          tools: world.catalogSources.tools)
        }
        await #expect(throws: ToolDoorway.Refused.self) {
            try await RepositoryPublisher.prepare(demo.scratchDirectory, remote: "https://example.invalid/r.git", tools: tools)
        }
        #expect(throws: ToolDoorway.Refused.self) {
            _ = try StateBackendService.credentialFill(protocol: "https", host: "example.invalid", tools: tools)
        }
        #expect(Set(attempts.all) == [.jamformer, .git], "each was stopped at the doorway: \(attempts.all)")
        #expect(fingerprint(GitStoreService.storeURL) == realStore)
    }

    @Test("Demo mode's own doorway refuses every tool")
    func demoDoorway() {
        for tool in ExternalTool.allCases {
            #expect(throws: ToolDoorway.Refused(tool: tool)) {
                _ = try ToolDoorway.demo.process(tool, executable: URL(filePath: "/usr/bin/true"), arguments: [])
            }
        }
    }

    @Test("The real doorway refuses anything pointing at demo mode, and everything while demo mode is on")
    func realDoorway() throws {
        let isOn = OSAllocatedUnfairLock(initialState: false)
        let tools = ToolDoorway.real(isDemoOn: { isOn.withLock { $0 } })
        let tool = URL(filePath: "/usr/bin/true")
        let demoFolder = FileManager.default.temporaryDirectory.appending(path: "JTKitDemo-\(UUID().uuidString)")
        #expect(throws: ToolDoorway.Refused.self) { _ = try tools.process(.openTofu, executable: tool, arguments: [], directory: demoFolder) }
        #expect(throws: ToolDoorway.Refused.self) {
            _ = try tools.process(.openTofu, executable: tool, arguments: ["plan"],
                                  environment: ["JAMFPLATFORM_BASE_URL": "https://contoso-platform.demo.invalid"])
        }
        #expect(throws: ToolDoorway.Refused.self) {
            _ = try tools.process(.git, executable: tool, arguments: ["-C", "tenants/\(DemoTenants.contosoID.uuidString)"])
        }
        // a real launch gets its process (not started here)
        let process = try tools.process(.git, executable: tool, arguments: ["status"],
                                        directory: FileManager.default.temporaryDirectory)
        #expect(process.executableURL == tool && !process.isRunning)
        isOn.withLock { $0 = true }
        #expect(throws: ToolDoorway.Refused.self) {
            _ = try tools.process(.git, executable: tool, arguments: ["status"], directory: FileManager.default.temporaryDirectory)
        }
    }

    @Test("Demo tenants' secrets stay in memory, never in the Keychain")
    func secretsInMemory() {
        let id = DemoTenants.newTenantID()
        let secrets = TenantSecrets(tenantID: id)
        #expect(secrets.platformClientSecret.load() == "demo-secret")
        #expect(secrets.statePassphrase.load() == nil)
        let setting = secrets.blockSetting(blockID: "app-catalog", key: "token")
        #expect(setting.save("demo-value"))
        #expect(setting.load() == "demo-value")
        let keychain = KeychainSecretStore(service: setting.service, accessibility: .whenUnlocked)
        #expect(keychain.secret(for: setting.account) == nil, "nothing reached the Keychain")
        secrets.deleteAll()
        #expect(setting.load() == nil)
        // a real tenant's items are still the Keychain's
        #expect(!DemoSecretVault.keepsInMemory(account: UUID().uuidString))
    }

    @Test("Demo tenants only reach JTKit's demo servers; real tenants never do")
    func demoClients() {
        let demo = demoMode()
        let world = AppWorld.demo(demo, activityLog: ActivityLog(), tools: .demo)
        for tenant in world.tenantStore.tenants {
            #expect(DemoTenants.isDemo(tenant))
            #expect(DemoTenants.source(for: tenant) != nil)
        }
        let real = Tenant(name: "Real", region: .eu, clientID: "client", environmentID: UUID().uuidString, isProduction: false)
        #expect(!DemoTenants.isDemo(real) && DemoTenants.connection(for: real) == nil)
        let realPro = Tenant(name: "Real Pro", region: .us, clientID: "client", environmentID: nil, isProduction: false,
                             connection: .jamfPro, jamfProURL: "https://example.jamfcloud.com", jamfProAuth: .apiClient)
        #expect(!DemoTenants.isDemo(realPro))
    }

    @Test("Test Connection in Settings stays real while demo mode is on")
    func testConnectionStaysReal() throws {
        let demo = demoMode()
        _ = AppWorld.demo(demo, activityLog: ActivityLog(), tools: .demo)
        let platform = Tenant(name: "Real", region: .eu, clientID: "client", environmentID: UUID().uuidString, isProduction: false)
        let configuration = try TenantConnectionsTab.testConfiguration(for: platform, signInName: "client", password: "secret")
        #expect(configuration.gatewayURL == platform.region.gatewayURL)
        let pro = Tenant(name: "Real Pro", region: .us, clientID: "client", environmentID: nil, isProduction: false,
                         connection: .jamfPro, jamfProURL: "https://example.jamfcloud.com", jamfProAuth: .apiClient)
        let proConfiguration = try TenantConnectionsTab.testConfiguration(for: pro, signInName: "client", password: "secret")
        #expect(proConfiguration.gatewayURL.host() == "example.jamfcloud.com")
        #expect(!(configuration.gatewayURL.host() ?? "").hasSuffix(".demo.invalid"))
    }

    @Test("The fixed plan says why for each change, as a real preview does")
    func fixedPlan() throws {
        let contoso = try #require(DemoFleet.seededTenants().first { $0.id == DemoTenants.contosoID })
        let (plan, diagnostics) = try DemoPlan.plan(for: contoso)
        let summary = PreviewBuilder.build(plan: plan, diagnostics: diagnostics, blockNames: ["app-catalog": "App Catalog"])
        let notes = summary.groups.flatMap(\.changes).map { "\($0.kind.rawValue): \($0.notes.joined())" }.sorted()
        #expect(notes == [
            "Create: New in the baseline: the App Catalog block installs Google Chrome on All Managed Clients.",
            "Create: New in the baseline: the App Catalog block installs Slack on All Managed Clients.",
            "Create: New in the baseline: the App Catalog block installs Zoom on All Managed Clients.",
            "Update: Reverts the change found in Jamf: updates were set to manual there; the baseline installs them automatically.",
        ])
        #expect(!summary.hasDestructiveChanges)
    }
}
