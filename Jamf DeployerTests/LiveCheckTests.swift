import Foundation
import Testing
import JamfDeployerCore
import JTKit
import JTKitLiveCheck
@testable import Jamf_Deployer

// Live checks (JTKit ROADMAP step 11), run only by Scripts/release-check.sh,
// which switches them on (JTKIT_LIVE=1) and passes the credentials it read
// from the login Keychain. ⌘U skips them. Tenants are named by role only:
// jamf-test-a over the Jamf Pro API (user account), jamf-test-b over the
// Jamf Platform API. Every request of the app's own client and of the
// checks goes through JTKitLiveCheck's guarded network; OpenTofu's own
// traffic doesn't, so each engine run is checked against the allow-list first.

private let live = LiveCheckRun.isEnabled

#if JTKIT_FAULT_BREAK_BUILD
// Set only by `release-check.sh --fault break-build`, to check that a broken
// build stops the release check before anything reaches a tenant.
#error("Build broken on purpose by the release check's --fault break-build")
#endif

/// One allow-listed tenant as the checks use it.
struct LiveTenant: Sendable {
    let role: String
    let service: AllowList.Service
    let entry: AllowList.Entry
    /// JTKit's client on the guarded network (reads, the one API change, cleanup).
    let api: JamfPlatform.Client
    /// The username (Jamf Pro) or client ID (Platform), and the secret.
    let signInID: String
    let secret: String

    static let roles: [(String, AllowList.Service)] = [("jamf-test-a", .jamfPro), ("jamf-test-b", .jamfPlatform)]

    static func all(_ run: LiveCheckRun) throws -> [LiveTenant] {
        try roles.filter { run.roles.contains($0.0) }.map { try LiveTenant(run: run, role: $0.0, service: $0.1) }
    }

    init(run: LiveCheckRun, role: String, service: AllowList.Service) throws {
        self.role = role
        self.service = service
        entry = try run.entry(role: role, service: service)
        let recorder = RequestRecorder(session: run.network.session, log: nil, category: "Live check")
        switch service {
        case .jamfPro:
            let host = try #require(entry.host)
            signInID = try run.credential(role, "jamfpro-username")
            let password = try run.credential(role, "jamfpro-password")
            secret = password
            let base = try #require(URL(string: "https://\(host)"))
            let tokens = JamfPlatform.TokenProvider(tokenURL: base.appending(path: "api/v1/auth/token"),
                                                    method: .usernamePassword(username: signInID),
                                                    secret: { password }, recorder: recorder)
            api = try JamfPlatform.Client(baseURL: base, scope: .organization, server: .jamfPro,
                                          signIn: .usernamePassword, tokens: tokens, recorder: recorder)
        default:
            let region = try #require(entry.region)
            let environment = try #require(entry.environmentID)
            signInID = try run.credential(role, "client-id")
            let clientSecret = try run.credential(role, "client-secret")
            secret = clientSecret
            let base = try #require(URL(string: "https://\(region).api.jamfcloud.com"))
            let tokens = JamfPlatform.TokenProvider(tokenURL: base.appending(path: "auth/token"),
                                                    method: .apiClient(clientID: signInID),
                                                    secret: { clientSecret }, recorder: recorder)
            api = try JamfPlatform.Client(baseURL: base, scope: .environment(environment), server: .platformAPI,
                                          signIn: .apiClient, tokens: tokens, recorder: recorder)
        }
    }

    /// The engine's tenant record (only ever in a temporary store).
    func tenant(name: String) throws -> Tenant {
        switch service {
        case .jamfPro:
            Tenant(name: name, region: .us, clientID: signInID, environmentID: nil, isProduction: false,
                   connection: .jamfPro, jamfProURL: "https://\(entry.host ?? "")", jamfProAuth: .userAccount)
        default:
            Tenant(name: name, region: try #require(JamfRegion(rawValue: entry.region ?? "")), clientID: signInID,
                   environmentID: entry.environmentID, isProduction: false)
        }
    }

    // MARK: Objects by API (Platform-form paths; JTKit maps them for Jamf Pro)

    struct Object: Decodable, Sendable {
        let id: String
        let name: String
        let priority: Int?

        enum CodingKeys: String, CodingKey { case id, name, priority }
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let text = try? container.decode(String.self, forKey: .id) { id = text } else { id = String(try container.decode(Int.self, forKey: .id)) }
            name = try container.decode(String.self, forKey: .name)
            priority = try? container.decode(Int.self, forKey: .priority)
        }
    }

    /// Jamf Pro API lists (`categories`, `scripts`).
    func list(_ resource: String) async throws -> [Object] {
        struct Page: Decodable { let results: [Object] }
        let response = try await api.send(HTTPRequest(path: "pro/v1/\(resource)",
                                                      query: [URLQueryItem(name: "page-size", value: "2000")],
                                                      accept: "application/json"))
        return try JSONDecoder().decode(Page.self, from: response.data).results
    }

    /// Classic API lists (`policies`, `computergroups`, `osxconfigurationprofiles`).
    func classicList(_ resource: String) async throws -> [Object] {
        let response = try await api.send(HTTPRequest(path: "proclassic/\(resource)", accept: "application/json"))
        let object = try JSONSerialization.jsonObject(with: response.data) as? [String: Any]
        let items = (object?.values.first as? [[String: Any]]) ?? []
        return try items.map { try JSONDecoder().decode(Object.self, from: JSONSerialization.data(withJSONObject: $0)) }
    }

    /// The kinds of object the sweep looks at, dependents first.
    static let sweepKinds: [(resource: String, classic: Bool)] = [
        ("policies", true), ("osxconfigurationprofiles", true), ("computergroups", true), ("scripts", false), ("categories", false),
    ]

    func delete(resource: String, id: String) async throws {
        let classic = Self.sweepKinds.first { $0.resource == resource }?.classic ?? false
        let path = classic ? "proclassic/\(resource)/id/\(id)" : "pro/v1/\(resource)/\(id)"
        _ = try await api.send(HTTPRequest(method: "DELETE", path: path))
    }
}

// MARK: Stage 1: sign in

@MainActor
@Suite("Live: sign in", .enabled(if: live), .serialized)
struct LiveSignInTests {
    /// A sign-in and one small read per tenant, plus a count of left-over
    /// test objects (removed in stage 4). Reads only.
    @Test func signInAndRead() async throws {
        let run = try LiveCheckRun.current()
        for target in try LiveTenant.all(run) {
            do {
                let version = try await target.api.send(HTTPRequest(path: "pro/v1/jamf-pro-version", accept: "application/json"))
                #expect(version.status == 200)
                var leftovers = 0
                for kind in LiveTenant.sweepKinds {
                    let objects = kind.classic ? try await target.classicList(kind.resource) : try await target.list(kind.resource)
                    leftovers += objects.filter { run.isSweepable($0.name) }.count
                }
                run.record(step: "sign in: \(target.role)", passed: true, note: "\(leftovers) left-over test objects")
            } catch {
                run.record(step: "sign in: \(target.role)", passed: false, note: String(describing: error))
                throw error
            }
        }
        #expect(run.network.refusals.isEmpty, "\(run.network.refusals)")
    }
}

// MARK: Stage 4: the main task, live

@MainActor
@Suite("Live: deploy, check for changes, revert", .enabled(if: live), .serialized)
struct LiveDeployTests {
    @Test func tenantA() async throws { try await exercise(role: "jamf-test-a") }
    @Test func tenantB() async throws { try await exercise(role: "jamf-test-b") }

    /// A tiny prefixed set (a category and a script) deployed with OpenTofu;
    /// Check for Changes clean; the category changed by API; Check for
    /// Changes finds it; a deploy reverts it; OpenTofu removes both.
    private func exercise(role: String) async throws {
        let run = try LiveCheckRun.current()
        guard let target = try LiveTenant.all(run).first(where: { $0.role == role }) else { return }
        try run.requireEngineTarget(role: role, service: target.service, host: target.entry.host,
                                    region: target.entry.region, environmentID: target.entry.environmentID)
        let step = { (name: String) in "\(role): \(name)" }

        // Secrets in memory for this whole process: the real Keychain is never touched.
        DemoSecretVault.keepEverythingInMemory()
        let root = FileManager.default.temporaryDirectory.appending(path: "jd-live-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appending(path: "store")
        let tools = ToolDoorway.real(isDemoOn: { false })
        let tenantStore = TenantStore(rootURL: storeURL.appending(path: "tenants"))
        let service = TenantDeployService(
            tenantStore: tenantStore, activityLog: ActivityLog(),
            catalogSources: CatalogSourceStore(fileURL: storeURL.appending(path: "catalog-sources.json"), tools: tools),
            storeURL: storeURL, tools: tools)
        #expect(!service.isTeamMode)

        var tenant = try target.tenant(name: "\(run.prefix) Tenant")
        tenant.namePrefix = "\(run.prefix) – "
        tenantStore.add(tenant)
        #expect(TenantSecrets(tenantID: tenant.id).platformClientSecret.save(target.secret))

        let categoryName = "\(run.prefix) – Category"
        let scriptName = "\(run.prefix) – Script"
        let override = service.adoptedURL(for: tenant).appending(path: "override-jtktest.tf")
        try FileManager.default.createDirectory(at: override.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(Self.configuration(for: target.service, category: categoryName, script: scriptName).utf8).write(to: override)

        // 1. Deploy the two objects.
        let first = try await service.preview(tenant: current(tenant, tenantStore))
        #expect(first.summary.counts[.create] == 2)
        try Self.requireOnlyTestObjects(first, run: run)
        let deployed = try await service.deploy(tenant: current(tenant, tenantStore), session: first)
        #expect(deployed.errors.isEmpty, "\(deployed.errors)")
        let category = try #require(try await target.list("categories").first { $0.name == categoryName })
        let script = try #require(try await target.list("scripts").first { $0.name == scriptName })
        try run.recordCreated(role: role, service: target.service, resource: "categories", id: category.id, name: categoryName)
        try run.recordCreated(role: role, service: target.service, resource: "scripts", id: script.id, name: scriptName)
        run.record(step: step("deploy a category and a script"), passed: deployed.errors.isEmpty)
        // Only with `release-check.sh --fault fail-live-step`: fails with
        // objects on the tenant, so cleanup has to remove them.
        try run.injectFault("fail-live-step", at: step("failure after creating objects"))

        // 2. Check for Changes: clean.
        try await service.checkDrift(tenant: current(tenant, tenantStore))
        let clean = try #require(current(tenant, tenantStore).driftReport)
        #expect(clean.actionableObjects.isEmpty, "\(clean.actionableObjects.map(\.address))")
        run.record(step: step("Check for Changes is clean"), passed: clean.actionableObjects.isEmpty)

        // 3. Change the category in Jamf (only allowed because the run made it).
        let changed = try JSONSerialization.data(withJSONObject: ["name": categoryName, "priority": 3])
        _ = try await target.api.send(HTTPRequest(method: "PUT", path: "pro/v1/categories/\(category.id)",
                                                  body: changed, contentType: "application/json"))
        try await service.checkDrift(tenant: current(tenant, tenantStore))
        let drift = try #require(current(tenant, tenantStore).driftReport)
        let found = drift.actionableObjects.contains { $0.resourceType.hasSuffix("category") }
        #expect(found, "The change to the category wasn't found")
        run.record(step: step("Check for Changes finds the change"), passed: found)

        // 4. Deploy reverts it.
        let revert = try await service.preview(tenant: current(tenant, tenantStore))
        try Self.requireOnlyTestObjects(revert, run: run)
        #expect((revert.summary.counts[.update] ?? 0) >= 1)
        let reverted = try await service.deploy(tenant: current(tenant, tenantStore), session: revert)
        let priority = try await target.list("categories").first { $0.id == category.id }?.priority
        #expect(reverted.errors.isEmpty && priority == 9, "priority \(String(describing: priority))")
        run.record(step: step("deploy reverts the change"), passed: reverted.errors.isEmpty && priority == 9)

        // 5. OpenTofu removes both.
        try FileManager.default.removeItem(at: override)
        let removal = try await service.preview(tenant: current(tenant, tenantStore))
        try Self.requireOnlyTestObjects(removal, run: run)
        #expect(removal.summary.counts[.remove] == 2)
        let removed = try await service.deploy(tenant: current(tenant, tenantStore), session: removal)
        let categories = try await target.list("categories")
        let scripts = try await target.list("scripts")
        // The ledger still lists both: the cleanup's delete reads each back
        // and marks it removed once it's gone (OpenTofu's delete doesn't count).
        let gone = !categories.contains { $0.id == category.id } && !scripts.contains { $0.id == script.id }
        #expect(removed.errors.isEmpty && gone)
        run.record(step: step("OpenTofu removes both"), passed: removed.errors.isEmpty && gone)
        try await service.removeTenant(current(tenant, tenantStore))
        #expect(run.network.refusals.isEmpty, "\(run.network.refusals)")
    }

    private func current(_ tenant: Tenant, _ store: TenantStore) throws -> Tenant {
        try #require(store.tenant(id: tenant.id))
    }

    /// Before an engine run: every object the plan touches is a test object
    /// (or the plan touches nothing).
    static func requireOnlyTestObjects(_ session: PreviewSession, run: LiveCheckRun) throws {
        let touched = session.summary.groups.flatMap(\.changes).filter { $0.kind != .unchanged }
        for change in touched where !change.displayName.hasPrefix(run.prefix) {
            throw LiveCheckRun.RunError.notAllowed("The plan touches \(change.address) (“\(change.displayName)”), not a test object")
        }
    }

    static func configuration(for service: AllowList.Service, category: String, script: String) -> String {
        let kind = service == .jamfPro ? "jamfpro" : "jamfplatform_pro"
        return """
        resource "\(kind)_category" "jtktest" {
          name     = "\(category)"
          priority = 9
        }

        resource "\(kind)_script" "jtktest" {
          name            = "\(script)"
          priority        = "AFTER"
          script_contents = "#!/bin/sh\\necho JTKTEST"
        }

        """
    }
}

// MARK: Cleanup (every exit of stage 4)

@MainActor
@Suite("Live: cleanup", .enabled(if: live), .serialized)
struct LiveCleanupTests {
    /// Deletes what the run's ledger still lists, after adding anything on
    /// the full tenants still named as a test object. Fails if a read-back
    /// still finds anything.
    @Test func removeTestObjects() async throws {
        let run = try LiveCheckRun.current()
        // Engine folders an interrupted run couldn't remove (no secrets in them).
        let temp = FileManager.default.temporaryDirectory
        for folder in (try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? [] where folder.hasPrefix("jd-live-") {
            try? FileManager.default.removeItem(at: temp.appending(path: folder))
        }
        let targets = try LiveTenant.all(run)
        for target in targets {
            let ledgerTarget = try run.target(role: target.role, service: target.service)
            for kind in LiveTenant.sweepKinds {
                let objects = kind.classic ? try await target.classicList(kind.resource) : try await target.list(kind.resource)
                for object in objects where run.isSweepable(object.name) {
                    try run.adoptForSweep(role: target.role, service: target.service, resource: kind.resource, id: object.id, name: object.name)
                }
            }
            for item in run.ledger.outstanding where item.target == ledgerTarget {
                let resource = LiveTenant.sweepKinds.first { Ledger.Item(target: "", resource: $0.resource, id: "", name: "").resource == item.resource }?.resource ?? item.resource
                do {
                    try await target.delete(resource: resource, id: item.id)
                } catch {
                    // Already gone (OpenTofu removed it): Jamf answers 404,
                    // and the delete's read-back has marked it removed.
                    let removed = !run.ledger.outstanding.contains {
                        $0.target == item.target && $0.resource == item.resource && $0.id == item.id
                    }
                    guard !removed else { continue }
                    run.record(step: "cleanup: \(target.role) \(item.resource) \(item.id)", passed: false, note: String(describing: error))
                }
            }
        }
        let left = run.ledger.outstanding
        run.record(step: "cleanup", passed: left.isEmpty, note: left.isEmpty ? nil : "\(left.count) not removed")
        try run.requireNothingLeft()
    }
}
