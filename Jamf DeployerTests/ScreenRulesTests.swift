import Foundation
import Testing
import JTKit
import JamfDeployerCore
@testable import Jamf_Deployer

/// The rules the screens follow, taken out of the views so they can be
/// tested: removing tenants, rollouts, Day 0, the support bundle, the
/// recovery sheet, catalog paths, secrets and baselines. Every name, ID and
/// address here is made up.
@MainActor
@Suite("Screen rules")
struct ScreenRulesTests {

    static func tenant(_ name: String = "Example Test", isProduction: Bool = false) -> Tenant {
        Tenant(name: name, region: .us, clientID: "fake-client-id", environmentID: "00000000-fake-env",
               isProduction: isProduction)
    }

    // MARK: Remove Tenant

    @Test func managedTenantsNeedTheirNameTyped() {
        #expect(TenantRemoval.needsTypedName(isManaged: true))
        #expect(!TenantRemoval.needsTypedName(isManaged: false))
        #expect(TenantRemoval.confirms(typed: "Example Test", tenantName: "Example Test"))
        #expect(!TenantRemoval.confirms(typed: "example test", tenantName: "Example Test"))
        #expect(!TenantRemoval.confirms(typed: "", tenantName: "Example Test"))
    }

    @Test func removalIsRefusedWhileEngineWorkRuns() {
        #expect(TenantRemoval.refusal(isEngineBusy: true) != nil)
        #expect(TenantRemoval.refusal(isEngineBusy: false) == nil)
    }

    @Test(arguments: [true, false])
    func managedRemovalSaysTheStateIsLostAndWhereToGoInstead(isTeamMode: Bool) {
        let managed = TenantRemoval.message(isTeamMode: isTeamMode, isManaged: true)
        #expect(managed.contains("deployment state"))
        #expect(managed.contains("Hand Over Tenant…"))
        #expect(managed.contains("Export as Terraform…"))
        #expect(managed.contains("Type the tenant name"))
        let unmanaged = TenantRemoval.message(isTeamMode: isTeamMode, isManaged: false)
        #expect(!unmanaged.contains("Type the tenant name"))
        for text in [managed, unmanaged, TenantRemoval.busyText, TenantRemoval.managedFromSettingsText] {
            #expect(!text.contains("'"), "straight apostrophe in “\(text)”")
            #expect(!text.localizedCaseInsensitiveContains("provider"))
        }
    }

    @Test func refusedRemovalsSpeakForThemselves() {
        let busy = SidebarView.removalErrorText(TenantDeployService.DeployError.tenantBusy)
        #expect(!busy.contains("team space"))
        let other = SidebarView.removalErrorText(TenantDeployService.DeployError.noTeamSpace)
        #expect(other.hasPrefix("Its deployment state couldn’t be deleted from the team space"))
    }

    // MARK: Rollout

    @Test func rolloutOrdersByRingThenName() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let names = [a: "Zulu", b: "alpha", c: "Mike", d: "Left out"]
        let queue = RolloutQueue([
            .init(id: a, include: true, ring: 1),
            .init(id: b, include: true, ring: 2),
            .init(id: c, include: true, ring: 1),
            .init(id: d, include: false, ring: 1),
        ], name: { names[$0] ?? "" })
        #expect(queue.steps.map(\.id) == [c, a, b])
        #expect(queue.ringCount == 2)
    }

    @Test func aFrozenRolloutKeepsItsOrderWhenATenantIsRenamed() {
        let first = UUID(), second = UUID()
        var names = [first: "Alpha", second: "Bravo"]
        let entries: [RolloutQueue.Entry] = [.init(id: first, include: true, ring: 1),
                                             .init(id: second, include: true, ring: 1)]
        let frozen = RolloutQueue(entries, name: { names[$0] ?? "" })
        // a team sync renames the first tenant mid-rollout
        names[first] = "Zulu"
        let live = RolloutQueue(entries, name: { names[$0] ?? "" })
        #expect(live[0].id == second, "a live queue would move another tenant into step 0")
        #expect(frozen[0].id == first)
        #expect(frozen.next(after: 0, pauseBetweenRings: true) == .start(1))
        #expect(frozen[1].id == second)
    }

    @Test func rolloutPausesBetweenRingsAndFinishes() {
        let ids = (0..<3).map { _ in UUID() }
        let queue = RolloutQueue([
            .init(id: ids[0], include: true, ring: 1),
            .init(id: ids[1], include: true, ring: 2),
            .init(id: ids[2], include: true, ring: 2),
        ], name: { id in "\(ids.firstIndex(of: id) ?? 0)" })
        #expect(queue.next(after: 0, pauseBetweenRings: true) == .pause(next: 1))
        #expect(queue.next(after: 0, pauseBetweenRings: false) == .start(1))
        #expect(queue.next(after: 1, pauseBetweenRings: true) == .start(2))
        #expect(queue.next(after: 2, pauseBetweenRings: true) == .finished)
    }

    // MARK: Day 0

    nonisolated struct TimedOut: Error {}

    @Test func day0ChecksTheTenantAgainAfterAFailedWrite() async {
        var detected = 0
        let failure = await Day0Action.perform({ throw TimedOut() }, thenDetect: { detected += 1 })
        #expect(failure is TimedOut)
        #expect(detected == 1)

        let success = await Day0Action.perform({}, thenDetect: { detected += 1 })
        #expect(success == nil)
        #expect(detected == 2)
    }

    @Test func day0WritesAskFirstOnProductionTenants() {
        #expect(Day0Action.needsConfirmation(isProduction: true))
        #expect(!Day0Action.needsConfirmation(isProduction: false))
        let writes: [Day0Write] = [.adeToken(URL(filePath: "/tmp/token.p7m")), .vppToken(URL(filePath: "/tmp/token.vpptoken")),
                                   .branding("Example Org"), .protect(url: "https://example.protect.invalid")]
        for write in writes {
            #expect(write.title(tenantName: "Example Production").hasSuffix("“Example Production”?"))
            #expect(write.message.contains("production tenant"))
            #expect(write.message.contains("without a preview"))
            #expect(!write.message.contains("Apple Business"))
        }
    }

    // MARK: Support bundle

    @Test func supportBundleMasksIdentifiers() {
        let serial = "C02FAKE0SN1X"
        let user = "jane.example"
        let email = "jane@example.invalid"
        let entries = [
            ActivityLogEntry(category: "API", operation: "GET", detail: "/api/v1/computers-inventory?serial=\(serial)",
                             status: 200, note: "Signed in as \(user)",
                             identifiers: [FoundIdentifier(.device, serial), FoundIdentifier(.user, user)]),
            ActivityLogEntry.action("Read the inventory", note: "Asked by \(email)", devices: [serial]),
        ]
        let app = ActivityLogAppInfo(name: "Jamf Deployer", version: "0.0.0", system: "macOS 0")
        let log = SupportBundle.activityLogText(entries, app: app)
        #expect(!log.contains(serial))
        #expect(!log.contains(user))
        #expect(!log.contains(email))
        #expect(log.contains("<device 1>"))
        #expect(log.contains("replaced with placeholders"))

        let versions = SupportBundle.versionsText(appVersion: "0.0.0", system: "macOS 0", isTeamMode: true,
                                                  lastSync: nil, syncMessage: "Pull failed for \(user) (\(email))",
                                                  entries: entries)
        #expect(!versions.contains(user))
        #expect(!versions.contains(email))
        #expect(versions.contains("Team Mode: on"))
    }

    // MARK: Recovery sheet

    @Test func theRecoverySheetCountsOnlyWithItsPassphrase() {
        #expect(!RecoveryEscrow.isUsable(nil))
        #expect(!RecoveryEscrow.isUsable(""))
        #expect(RecoveryEscrow.isUsable("fake-passphrase"))
        #expect(RecoveryEscrow.marksSaved(exportSucceeded: true, includesPassphrase: true))
        #expect(!RecoveryEscrow.marksSaved(exportSucceeded: true, includesPassphrase: false))
        #expect(!RecoveryEscrow.marksSaved(exportSucceeded: false, includesPassphrase: true))
    }

    // MARK: Catalog paths

    @Test func catalogPathsCompareWholeFolders() {
        #expect(FolderPath.isInside("/Users/example/Blocks/wifi", "/Users/example/Blocks"))
        #expect(FolderPath.isInside("/Users/example/Blocks/wifi", "/Users/example/Blocks/"))
        #expect(FolderPath.isInside("/Users/example/Blocks", "/Users/example/Blocks"))
        #expect(!FolderPath.isInside("/Users/example/Blocks-cache/wifi", "/Users/example/Blocks"))
        #expect(!FolderPath.isInside("/Users/example", "/Users/example/Blocks"))
        #expect(!FolderPath.isInside("/Users/example/Blocks/wifi", ""))
    }

    // MARK: Update Client Secret

    @Test func aNewClientIDNeedsItsSecret() {
        // Team Mode, ID changed: only with a secret
        #expect(!ClientSecretUpdate.canSave(isTeamMode: true, savedID: "old-id", typedID: "new-id", secret: "", passphrase: ""))
        #expect(!ClientSecretUpdate.canSave(isTeamMode: true, savedID: "old-id", typedID: "new-id", secret: "", passphrase: "fake"))
        #expect(ClientSecretUpdate.canSave(isTeamMode: true, savedID: "old-id", typedID: " new-id ", secret: "fake-secret", passphrase: ""))
        // same ID: a secret or a passphrase
        #expect(!ClientSecretUpdate.canSave(isTeamMode: true, savedID: "old-id", typedID: "old-id", secret: "", passphrase: ""))
        #expect(ClientSecretUpdate.canSave(isTeamMode: true, savedID: "old-id", typedID: "old-id", secret: "fake-secret", passphrase: ""))
        // outside Team Mode the ID can't change
        #expect(!ClientSecretUpdate.idChanged(isTeamMode: false, savedID: "old-id", typedID: "new-id"))
        #expect(ClientSecretUpdate.canSave(isTeamMode: false, savedID: "old-id", typedID: "old-id", secret: "", passphrase: "fake"))
    }

    // MARK: Export as Terraform

    @Test func movingToARepositoryNeedsTheUnencryptedStateAcknowledged() {
        func canExport(moves: Bool, acceptsMove: Bool, acceptsState: Bool) -> Bool {
            RepositoryExportSheet.canExport(hasTenants: true, hasFolder: true, isWorking: false, movesTenants: moves,
                                            remoteURL: "https://example.invalid/org/repo.git",
                                            acceptsMove: acceptsMove, acceptsUnencryptedState: acceptsState)
        }
        #expect(!canExport(moves: true, acceptsMove: true, acceptsState: false))
        #expect(!canExport(moves: true, acceptsMove: false, acceptsState: true))
        #expect(canExport(moves: true, acceptsMove: true, acceptsState: true))
        // keeping the tenants here pushes no state
        #expect(canExport(moves: false, acceptsMove: false, acceptsState: false))
    }

    // MARK: App Store picker

    @Test func appsTheLocationCantLicenseAreFlagged() {
        let apps = [AppStoreApp(adamID: "100000001", name: "Example One"), AppStoreApp(adamID: "100000002", name: "Example Two")]
        #expect(AppStoreLicenses.unlicensed(apps, contentIDs: ["100000001"]) == ["100000002"])
        #expect(AppStoreLicenses.unlicensed(apps, contentIDs: ["100000001", "100000002"]).isEmpty)
    }

    // MARK: App lists

    @Test func anUnreadableAppListIsKeptUntilAppsArePicked() {
        let unreadable = "{not a list"
        #expect(AppStoreApp.decodeIfReadable(settingValue: unreadable) == nil)
        let readable = AppStoreApp.decodeIfReadable(settingValue: unreadable) != nil
        // the picker shows it as empty; that empty list mustn't replace it
        #expect(AppListSetting.value(saving: AppStoreApp.encode([]), isEmpty: true, over: readable) == nil)
        let picked = [AppStoreApp(adamID: "100000001", name: "Example One")]
        #expect(AppListSetting.value(saving: AppStoreApp.encode(picked), isEmpty: false, over: readable)
                == AppStoreApp.encode(picked))
        // a readable list can be emptied on purpose
        #expect(AppListSetting.value(saving: AppCatalogApp.encode([]), isEmpty: true, over: true) == AppCatalogApp.encode([]))
        #expect(AppListSetting.unreadableText.contains("’"))
    }

    // MARK: Secret settings

    @Test func secretSettingsAreSavedOnlyWhenChanged() {
        #expect(!SecretSettingBuffer.needsSave(typed: "", stored: nil))
        #expect(!SecretSettingBuffer.needsSave(typed: "fake", stored: "fake"))
        #expect(SecretSettingBuffer.needsSave(typed: "fake-2", stored: "fake"))
        #expect(SecretSettingBuffer.needsSave(typed: "", stored: "fake"))
    }

    // MARK: Screen work

    @Test func screenWorkHoldsTheDemoSwitchUntilDone() async throws {
        let work = ScreenWork()
        let token = work.begin("export")
        #expect(work.isBusy)
        work.end(token)
        #expect(!work.isBusy)

        await #expect(throws: TimedOut.self) {
            try await work.tracking("Day 0") {
                #expect(work.isBusy)
                throw TimedOut()
            }
        }
        #expect(!work.isBusy)
    }

    // MARK: Snapshots

    @Test func aFailedSnapshotLeavesTheReplacedFileAlone() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "jd-snapshot-test-\(UUID().uuidString)")
        let source = folder.appending(path: "export")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("resource \"example\" {}".utf8).write(to: source.appending(path: "main.tf"))
        let destination = folder.appending(path: "Snapshot.zip")
        try Data("earlier snapshot".utf8).write(to: destination)

        #expect(!ExportView.zipSnapshot(source, to: destination, zipTool: URL(filePath: "/usr/bin/false")))
        #expect(try Data(contentsOf: destination) == Data("earlier snapshot".utf8))

        #expect(ExportView.zipSnapshot(source, to: destination))
        let zipped = try Data(contentsOf: destination)
        #expect(zipped.prefix(2) == Data("PK".utf8))
    }
}

/// Checking, unchecking and presets (`BaselineRules`).
@MainActor
@Suite("Baseline rules")
struct BaselineRulesTests {
    let folder: URL
    let catalog: LoadedCatalog

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "jd-baseline-rules-\(UUID().uuidString)")
        let blocks = [
            "base-block": #"{"id": "base-block", "name": "Base"}"#,
            "child-block": #"{"id": "child-block", "name": "Child", "requires": ["base-block"]}"#,
            "other-block": #"{"id": "other-block", "name": "Other"}"#,
        ]
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"id": "example", "name": "Example", "schemaVersion": 1}"#.utf8)
            .write(to: folder.appending(path: "catalog.json"))
        for (id, json) in blocks {
            let blockFolder = folder.appending(path: "blocks/\(id)")
            try fileManager.createDirectory(at: blockFolder, withIntermediateDirectories: true)
            try Data(json.utf8).write(to: blockFolder.appending(path: "block.json"))
        }
        catalog = try LoadedCatalog.load(from: folder)
    }

    func block(_ id: String) throws -> BlockMetadata {
        try #require(catalog.block(id: id))
    }

    @Test func checkingABlockPullsInItsPrerequisiteAndKeepsTheRest() throws {
        var tenant = ScreenRulesTests.tenant()
        let checked = Date(timeIntervalSince1970: 1_000_000)
        tenant.lastDriftCheck = checked
        let updated = try #require(BaselineRules.selecting(try block("child-block"), in: tenant, catalog: catalog))
        #expect(updated.blockSelections.map(\.blockID) == ["base-block", "child-block"])
        // only the baseline changes: a check that finished meanwhile is kept
        #expect(updated.lastDriftCheck == checked)
        #expect(BaselineRules.selecting(try block("child-block"), in: updated, catalog: catalog) == nil)
    }

    @Test func uncheckingIsRefusedWhileAnotherBlockNeedsIt() throws {
        let tenant = try #require(BaselineRules.selecting(try block("child-block"), in: ScreenRulesTests.tenant(), catalog: catalog))
        guard case .refused(let notice) = BaselineRules.unselecting(try block("base-block"), in: tenant, catalog: catalog) else {
            Issue.record("Base was removed although Child needs it")
            return
        }
        #expect(notice.contains("Child"))
        guard case .removed(let without) = BaselineRules.unselecting(try block("child-block"), in: tenant, catalog: catalog) else {
            Issue.record("Child could not be removed")
            return
        }
        #expect(without.blockSelections.map(\.blockID) == ["base-block"])
    }

    @Test func deployedBlocksAskHowAndAreReleasedNotDeleted() throws {
        var tenant = try #require(BaselineRules.selecting(try block("other-block"), in: ScreenRulesTests.tenant(), catalog: catalog))
        tenant.deployedBlockVersions = ["other-block": "1.0.0"]
        #expect(BaselineRules.unselecting(try block("other-block"), in: tenant, catalog: catalog) == .asksHowToRemove)
        let released = BaselineRules.removing("other-block", keepInJamf: true, in: tenant)
        #expect(released.blockSelections.isEmpty)
        #expect(released.pendingRemovals == [BlockRemoval(blockID: "other-block", keepInJamf: true)])
        // a missing catalog block that was deployed is released too
        #expect(BaselineRules.droppingMissing("other-block", in: tenant).pendingRemovals.first?.keepInJamf == true)
    }

    @Test func aPresetReleasesDeployedBlocksItLeavesOut() throws {
        var tenant = try #require(BaselineRules.selecting(try block("other-block"), in: ScreenRulesTests.tenant(), catalog: catalog))
        tenant.deployedBlockVersions = ["other-block": "1.0.0"]
        let preset = try JSONDecoder().decode(Preset.self, from: Data(#"{"id": "standard", "blocks": ["base-block", "child-block"]}"#.utf8))
        let result = BaselineRules.applying(preset, to: tenant, catalog: catalog, supports: { $0 != "child-block" })
        #expect(result.tenant.blockSelections.map(\.blockID) == ["base-block"])
        #expect(result.skipped == ["Child"])
        #expect(result.tenant.pendingRemovals == [BlockRemoval(blockID: "other-block", keepInJamf: true)])
    }
}
