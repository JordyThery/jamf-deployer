import Foundation
import Testing
import JTKit
import JamfDeployerCore
@testable import Jamf_Deployer

/// The deploy service's guards around shared resources, Team Mode syncs and
/// record changes, on a throwaway store. No engine runs, no tenant is
/// reached, and no Keychain item is read or written.
@MainActor
@Suite("Deploy service guards")
struct DeployServiceGuardTests {
    final class Attempts: @unchecked Sendable {
        private let lock = NSLock()
        private var tools: [ExternalTool] = []
        func record(_ tool: ExternalTool) { lock.withLock { tools.append(tool) } }
        var all: [ExternalTool] { lock.withLock { tools } }
    }

    struct Fixture {
        let service: TenantDeployService
        let tenantStore: TenantStore
        let root: URL
        var storeURL: URL { root.appending(path: "store") }
    }

    static func make(tools: ToolDoorway = .real(isDemoOn: { false })) -> Fixture {
        let root = TestGit.folder("service")
        let storeURL = root.appending(path: "store")
        let tenantStore = TenantStore(rootURL: storeURL.appending(path: "tenants"))
        let service = TenantDeployService(
            tenantStore: tenantStore, activityLog: ActivityLog(),
            catalogSources: CatalogSourceStore(fileURL: storeURL.appending(path: "catalog-sources.json"), tools: tools),
            storeURL: storeURL, tools: tools)
        return Fixture(service: service, tenantStore: tenantStore, root: root)
    }

    static func tenant(_ name: String = "Example Tenant", managed: Bool = false) -> Tenant {
        var tenant = Tenant(name: name, region: .us, clientID: "client", environmentID: "env", isProduction: false)
        if managed { tenant.deployedBlockVersions = ["example-block": "1.0.0"] }
        return tenant
    }

    static func isError(_ error: any Error, _ expected: String) -> Bool {
        guard let error = error as? TenantDeployService.DeployError else { return false }
        return "\(error)".hasPrefix(expected)
    }

    // MARK: Shared resources

    @Test("Force Unlock waits for every other tenant's engine work")
    func forceUnlockRefusedWhileAnyWorkRuns() async throws {
        let attempts = Attempts()
        let fixture = Self.make(tools: .trap { attempts.record($0) })
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let a = Self.tenant("A"), b = Self.tenant("B")
        let lock = StateBackendService.StateLock(lockID: "lock", who: "alex@mac", operation: "OperationTypeApply")

        fixture.service.busyTenants.insert(b.id)
        #expect(fixture.service.isEngineWorkRunning)
        await #expect { try await fixture.service.forceUnlock(tenant: a, lock: lock) } throws: {
            Self.isError($0, "engineWorkInProgress")
        }
        fixture.service.busyTenants.remove(b.id)

        fixture.service.activePreviewTenants.insert(b.id)
        await #expect { try await fixture.service.forceUnlock(tenant: a, lock: lock) } throws: {
            Self.isError($0, "engineWorkInProgress")
        }
        #expect(attempts.all.isEmpty, "nothing was started")
    }

    @Test("Remove Tenant waits for engine work and open previews, also outside Team Mode")
    func removeRefusedWhileWorkRuns() async throws {
        let fixture = Self.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let tenant = Self.tenant()
        fixture.tenantStore.add(tenant)
        #expect(!fixture.service.isTeamMode)

        fixture.service.busyTenants.insert(tenant.id)
        await #expect { try await fixture.service.removeTenant(tenant) } throws: { Self.isError($0, "engineWorkInProgress") }
        fixture.service.busyTenants.remove(tenant.id)

        let other = Self.tenant("Other")
        fixture.service.activePreviewTenants.insert(other.id)
        await #expect { try await fixture.service.removeTenant(tenant) } throws: { Self.isError($0, "engineWorkInProgress") }

        #expect(fixture.tenantStore.tenant(id: tenant.id) != nil, "the tenant and its workspace stay")
        #expect(FileManager.default.fileExists(atPath: fixture.tenantStore.workspaceURL(for: tenant).path))
    }

    @Test("State moves wait for engine work")
    func stateMovesRefusedWhileWorkRuns() async throws {
        let fixture = Self.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.service.activePreviewTenants.insert(UUID())
        await #expect { try await fixture.service.moveStateToTeam(tenants: []) } throws: { Self.isError($0, "engineWorkInProgress") }
        await #expect { try await fixture.service.moveStateToLocal() } throws: { Self.isError($0, "engineWorkInProgress") }
    }

    @Test("Leaving Team Mode skips tenants without state on the state branch")
    func leaveSkipsTenantsWithoutTeamState() async throws {
        let fixture = Self.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let remote = fixture.root.appending(path: "remote.git")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try TestGit.run(["init", "--bare", "--initial-branch", "main"], in: remote)
        try await fixture.service.gitStore.ensureRepo()
        try await fixture.service.gitStore.attachRemote(remote.path)
        try await fixture.service.gitStore.ensureStateBranch()
        await fixture.service.syncTeamState()
        #expect(fixture.service.isTeamMode)

        // Never deployed: a block from a catalog this Mac doesn't follow, and
        // no client secret on this Mac. It has no state, so it can't block leaving.
        var unfinished = Self.tenant("Unfinished")
        unfinished.blockSelections = [BlockSelection(blockID: "not-in-any-catalog", sourceID: "elsewhere")]
        fixture.tenantStore.add(unfinished)

        let moved = try await fixture.service.moveStateToLocal()
        #expect(moved.isEmpty)
        #expect(!fixture.service.isBusy)

        let deployed = Self.tenant("Deployed"), handedOver = { var t = Self.tenant("Handed over"); t.mode = .handedOver; return t }()
        let chosen = TenantDeployService.tenantsToMoveToLocal(
            [unfinished, deployed, handedOver], withTeamState: [deployed.id, handedOver.id])
        #expect(chosen.map(\.id) == [deployed.id])
    }

    @Test("Only state that was moved into the team space is retired")
    func onlyMovedStateIsRetired() throws {
        let fixture = Self.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        // A first deploy that partly failed: not "managed", but its state holds objects.
        let tenant = Self.tenant()
        fixture.tenantStore.add(tenant)
        let state = fixture.tenantStore.workspaceURL(for: tenant).appending(path: "state/terraform.tfstate")
        try Data("{\"encrypted_data\": \"…\"}".utf8).write(to: state)
        #expect(!fixture.service.isManaged(tenant))
        #expect(fixture.service.hasLocalState(tenant), "it still counts as having state")

        fixture.service.retireLocalState(of: fixture.tenantStore.tenants)
        #expect(FileManager.default.fileExists(atPath: state.path), "state that didn't move stays")

        try Data().write(to: state)
        #expect(!fixture.service.hasLocalState(tenant))
        #expect(!TenantDeployService.holdsState(Data(" \n".utf8)))
        #expect(TenantDeployService.holdsState(Data("{\"version\": 4}".utf8)))
    }

    // MARK: Handed-over tenants

    @Test("A handed-over tenant is never previewed, checked or deployed")
    func handedOverTenantsAreRefused() async throws {
        let attempts = Attempts()
        let fixture = Self.make(tools: .trap { attempts.record($0) })
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var tenant = Self.tenant(managed: true)
        tenant.mode = .handedOver

        await #expect { _ = try await fixture.service.preview(tenant: tenant) } throws: { Self.isError($0, "handedOver") }
        await #expect { try await fixture.service.checkDrift(tenant: tenant) } throws: { Self.isError($0, "handedOver") }
        let session = PreviewSession(planFileName: "plan.bin", summary: PreviewBuilder.build(
            plan: try JSONDecoder().decode(PlanFile.self, from: Data("{\"format_version\": \"1.2\"}".utf8)),
            diagnostics: [], blockNames: [:]),
            diagnostics: [], blockVersions: [:], createdAt: .now)
        await #expect { _ = try await fixture.service.deploy(tenant: tenant, session: session) } throws: { Self.isError($0, "handedOver") }
        #expect(attempts.all.isEmpty)
        #expect(!fixture.service.isBusy)
    }

    // MARK: Team sync

    /// A store in Team Mode whose team space can't be reached.
    static func unreachableTeamSpace() async throws -> Fixture {
        let fixture = make()
        try await fixture.service.gitStore.ensureRepo()
        try TestGit.run(["remote", "add", "origin", fixture.root.appending(path: "missing.git").path], in: fixture.storeURL)
        await fixture.service.syncTeamState()
        return fixture
    }

    @Test("Preview and checks stop when the team sync failed")
    func failedSyncStopsEngineWork() async throws {
        let fixture = try await Self.unreachableTeamSpace()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        #expect(fixture.service.isTeamMode)
        #expect(fixture.service.syncMessage != nil)
        let tenant = Self.tenant(managed: true)
        fixture.tenantStore.add(tenant)

        await #expect { _ = try await fixture.service.preview(tenant: tenant) } throws: { Self.isError($0, "teamSyncFailed") }
        await #expect { try await fixture.service.checkDrift(tenant: tenant) } throws: { Self.isError($0, "teamSyncFailed") }
        #expect(!fixture.service.isBusy)
        #expect(fixture.service.phase(for: tenant.id) == .idle)
    }

    @Test("A fleet check syncs once and stops on a failed sync")
    func fleetCheckSyncsFirst() async throws {
        let fixture = try await Self.unreachableTeamSpace()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let a = Self.tenant("A", managed: true), b = Self.tenant("B", managed: true)
        fixture.tenantStore.add(a)
        fixture.tenantStore.add(b)
        await fixture.service.checkAllTenants()
        for tenant in [a, b] {
            #expect(fixture.service.fleetCheckFailure(for: tenant.id)?.contains("couldn’t be synced") == true)
        }
        #expect(fixture.service.fleetCheckProgress == nil)
    }

    @Test("A wrong passphrase can't be checked without a team space; decryption errors are recognized")
    func passphraseCheck() async throws {
        let fixture = Self.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await #expect { _ = try await fixture.service.checkTeamPassphrase() } throws: { Self.isError($0, "noTeamSpace") }
        #expect(TenantDeployService.isDecryptionFailure(["│ Error: decryption failed for all provided methods"]))
        #expect(!TenantDeployService.isDecryptionFailure(["Error: Failed to get state"]))
        #expect(TenantDeployService.DeployError.passphraseNotVerified.errorDescription?.contains("wasn’t accepted") == true)
    }

    @Test("A team space with no state yet accepts the passphrase without reading the Keychain")
    func passphraseWithEmptyTeamSpace() async throws {
        let fixture = Self.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let remote = fixture.root.appending(path: "remote.git")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try TestGit.run(["init", "--bare", "--initial-branch", "main"], in: remote)
        try await fixture.service.gitStore.ensureRepo()
        try await fixture.service.gitStore.attachRemote(remote.path)
        try await fixture.service.gitStore.ensureStateBranch()
        await fixture.service.syncTeamState()
        #expect(fixture.service.syncMessage == nil)
        #expect(try await fixture.service.checkTeamPassphrase())
    }

    // MARK: Record changes

    @Test("Every record change is committed: delayed, and before any sync")
    func recordChangesAreCommitted() async throws {
        let fixture = Self.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.service.syncTeamState()
        var tenant = Self.tenant("Recorded")
        fixture.tenantStore.add(tenant)
        tenant.namePrefix = "ACME - "
        fixture.tenantStore.update(tenant)
        #expect(fixture.service.hasPendingRecords)

        await fixture.service.syncTeamState()
        #expect(!fixture.service.hasPendingRecords)
        let subject = try TestGit.run(["log", "-1", "--format=%s"], in: fixture.storeURL)
        #expect(subject.hasPrefix("Add tenant Recorded; Update tenant Recorded — "))
        #expect(try TestGit.run(["status", "--porcelain"], in: fixture.storeURL).isEmpty)

        // Changes the service makes carry their own message.
        fixture.service.prepareHandOver(tenant: tenant)
        await fixture.service.flushPendingRecords()
        #expect(try TestGit.run(["log", "-1", "--format=%s"], in: fixture.storeURL).hasPrefix("Prepare hand-over of Recorded"))
    }

    @Test("Rapid edits become one commit after a short pause")
    func rapidEditsAreCoalesced() async throws {
        let fixture = Self.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.service.syncTeamState()
        var tenant = Self.tenant("Typed")
        fixture.tenantStore.add(tenant)
        for prefix in ["A", "AC", "ACM", "ACME"] {
            tenant.namePrefix = prefix
            fixture.tenantStore.update(tenant)
        }
        let before = try TestGit.run(["rev-list", "--count", "HEAD"], in: fixture.storeURL)
        try await Task.sleep(for: TenantDeployService.recordDelay + .seconds(2))
        #expect(!fixture.service.hasPendingRecords)
        let after = try TestGit.run(["rev-list", "--count", "HEAD"], in: fixture.storeURL)
        #expect(Int(after) == Int(before)! + 1)
    }

    // MARK: This Mac's flags

    @Test("Test runs never set the real app's flags")
    func flagsStayInMemory() async throws {
        let fixture = Self.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let tenant = Self.tenant()
        let key = "recoverySaved.\(tenant.id.uuidString)"
        let storeCheck = UserDefaults.standard.object(forKey: TenantDeployService.storeSecretCheckDefaultsKey) as? Bool

        #expect(fixture.service.needsRecoveryEscrow(for: tenant))
        fixture.service.markRecoverySaved(for: tenant)
        #expect(!fixture.service.needsRecoveryEscrow(for: tenant))
        #expect(UserDefaults.standard.object(forKey: key) == nil)

        // The one-time check looks at this store (not the real one) and
        // remembers it only for this run.
        try await fixture.service.gitStore.ensureRepo()
        await fixture.service.checkExistingStoreOnce()
        #expect(fixture.service.flags.bool(forKey: TenantDeployService.storeSecretCheckDefaultsKey))
        #expect(UserDefaults.standard.object(forKey: TenantDeployService.storeSecretCheckDefaultsKey) as? Bool == storeCheck)
    }

    // MARK: Ordered deploy retry

    @Test("Retry plans don't refresh, and a plan that left the approved one asks for a new preview")
    func orderedRetryStaysWithinTheApprovedPlan() {
        let arguments = TenantDeployService.retryPlanArguments(file: "retry.bin", targets: ["module.a"], tenant: Self.tenant())
        #expect(arguments.contains("-refresh=false"))
        #expect(arguments.contains("-target=module.a"))
        #expect(arguments.contains("-out=retry.bin"))
        #expect(TenantDeployService.retryLeftApprovedPlan.contains("Preview the changes again"))
    }

    // MARK: Decisions log

    @Test("The decisions log is in this user's own temporary folder")
    func decisionsLogIsPrivate() {
        #expect(!TenantDeployService.decisionsLogURL.path.hasPrefix("/tmp/"))
        #expect(TenantDeployService.decisionsLogURL.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }
}
