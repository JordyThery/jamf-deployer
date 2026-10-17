import Foundation
import DeployerKit
import JamfDeployerCore

/// A plan the user is looking at. Only this exact saved plan can be
/// deployed — never a regenerated one.
nonisolated struct PreviewSession: Sendable {
    var planFileName: String
    var summary: PreviewSummary
    var diagnostics: [EngineStreamEvent.Diagnostic]
    var blockVersions: [String: String]
    var createdAt: Date
}

/// Orchestrates everything between "Preview changes" and "Deploy" for one
/// tenant: workspace generation, engine runs, history and state backups.
/// One runner per tenant means a tenant never has two runs at once.
@Observable
final class TenantDeployService {
    enum Phase: Equatable {
        case idle
        case generating
        case initializing
        case planning
        case applying
    }

    private(set) var phase: Phase = .idle
    /// Live per-object progress lines during apply, display-only.
    private(set) var progress: [String] = []

    private let tenantStore: TenantStore
    private let activityLog: ActivityLog
    private let catalogSources: CatalogSourceStore
    let gitStore = GitStoreService()
    let teamSecrets: TeamSecretsService
    private var runners: [UUID: EngineRunner] = [:]

    /// Tenants with an open preview; a drift check would regenerate the
    /// workspace and invalidate the saved plan, so it is blocked until the
    /// preview is deployed or closed.
    private var activePreviewTenants: Set<UUID> = []

    /// Team-space state the UI shows.
    private(set) var isTeamMode = false
    private(set) var teamRemoteURL: String?
    private(set) var locks: [UUID: GitStoreService.LockInfo] = [:]
    private(set) var lastSync: Date?
    private(set) var syncMessage: String?

    init(tenantStore: TenantStore, activityLog: ActivityLog, catalogSources: CatalogSourceStore? = nil) {
        self.tenantStore = tenantStore
        self.activityLog = activityLog
        self.catalogSources = catalogSources ?? CatalogSourceStore()
        self.teamSecrets = TeamSecretsService(tenantStore: tenantStore, gitStore: gitStore)
    }

    var isBusy: Bool {
        phase != .idle
    }

    // MARK: Team space

    /// Called at launch and from Sync Now: makes sure the repo exists, pulls
    /// when a team space is connected, and refreshes stores and locks.
    func syncTeamState() async {
        do {
            try await gitStore.ensureRepo()
            isTeamMode = await gitStore.isTeamMode()
            teamRemoteURL = try? await gitStore.remoteURL
            if isTeamMode {
                try await gitStore.pull()
                tenantStore.reload()
                catalogSources.reload()
            }
            let lockList = await gitStore.allLocks()
            locks = Dictionary(uniqueKeysWithValues: lockList.map { ($0.tenantID, $0) })
            if isTeamMode {
                // Shared credentials this Mac is missing decrypt straight
                // into the Keychain.
                teamSecrets.refresh()
                teamSecrets.absorbSecrets()
            }
            lastSync = .now
            syncMessage = nil
        } catch {
            syncMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func lock(for tenantID: UUID) -> GitStoreService.LockInfo? {
        locks[tenantID]
    }

    /// Releases a preview lock when the sheet closes without deploying.
    func abandonPreview(tenant: Tenant) {
        activePreviewTenants.remove(tenant.id)
        guard isTeamMode else { return }
        Task {
            try? await gitStore.releaseLock(
                tenantID: tenant.id,
                message: "Preview \(tenant.name) (no deploy) — \(engineerName)"
            )
            await syncTeamState()
        }
    }

    func breakLock(tenant: Tenant) async {
        try? await gitStore.breakLock(tenantID: tenant.id, by: engineerName)
        await syncTeamState()
    }

    // MARK: Workspace

    func loadCatalog() throws -> LoadedCatalog {
        try catalogSources.loadMerged()
    }

    /// The catalog as this tenant sees it: git sources resolve at the
    /// tenant's pinned tags.
    func loadCatalog(for tenant: Tenant) throws -> LoadedCatalog {
        try catalogSources.loadMerged(pins: tenant.catalogPins)
    }

    /// Downloads any tag checkouts the tenant's selections need before the
    /// (synchronous, disk-only) catalog loads run.
    private func ensureCatalogCheckouts(for tenant: Tenant) async throws {
        for source in catalogSources.customSources where source.kind == .gitRepository {
            var tags: Set<String?> = []
            if tenant.catalogPins[source.id.uuidString] != nil || tenant.blockSelections.contains(where: { $0.sourceID == source.id.uuidString }) {
                tags.insert(tenant.catalogPins[source.id.uuidString])
            }
            for selection in tenant.blockSelections
            where selection.sourceID == source.id.uuidString && selection.sourceTag != nil {
                tags.insert(selection.sourceTag)
            }
            for tag in tags {
                try await catalogSources.ensureCheckout(source: source, tag: tag)
            }
        }
    }

    /// Per-block updates available from newer tags of the tenant's git
    /// sources (fetches the remotes' tag lists).
    func availableBaselineUpdates(for tenant: Tenant) async throws -> [(source: CatalogSourceStore.CustomSource, tag: String, updates: [CatalogUpdatePlanner.BlockUpdate])] {
        var results: [(CatalogSourceStore.CustomSource, String, [CatalogUpdatePlanner.BlockUpdate])] = []
        let usedSourceIDs = Set(tenant.blockSelections.map(\.sourceID))
        for source in catalogSources.customSources
        where source.kind == .gitRepository && usedSourceIDs.contains(source.id.uuidString) {
            guard let gitURL = source.gitURL,
                  let latest = try await GitCatalogManager.availableTags(remote: gitURL).last else { continue }
            let pinned = tenant.catalogPins[source.id.uuidString] ?? source.defaultTag ?? latest
            guard latest != pinned else { continue }
            try await catalogSources.ensureCheckout(source: source, tag: pinned)
            try await catalogSources.ensureCheckout(source: source, tag: latest)
            let current = try catalogSources.load(source: source, tag: pinned)
            let candidate = try catalogSources.load(source: source, tag: latest)
            let selected = tenant.blockSelections
                .filter { $0.sourceID == source.id.uuidString }
                .map(\.blockID)
            let updates = CatalogUpdatePlanner.plan(current: current, candidate: candidate, selectedBlockIDs: selected)
            if !updates.isEmpty {
                results.append((source, latest, updates))
            }
        }
        return results
    }

    /// Opts the chosen blocks into a newer tag; when every block of the
    /// source moved, the tenant's pin advances and per-block tags clear.
    func applyBaselineUpdate(
        tenant: Tenant,
        source: CatalogSourceStore.CustomSource,
        tag: String,
        blockIDs: Set<String>
    ) {
        var updated = tenant
        for index in updated.blockSelections.indices
        where updated.blockSelections[index].sourceID == source.id.uuidString {
            if blockIDs.contains(updated.blockSelections[index].blockID) {
                updated.blockSelections[index].sourceTag = tag
            }
        }
        let sourceSelections = updated.blockSelections.filter { $0.sourceID == source.id.uuidString }
        if sourceSelections.allSatisfy({ $0.sourceTag == tag }) {
            updated.catalogPins[source.id.uuidString] = tag
            for index in updated.blockSelections.indices
            where updated.blockSelections[index].sourceID == source.id.uuidString {
                updated.blockSelections[index].sourceTag = nil
            }
        }
        tenantStore.update(updated)
    }

    @discardableResult
    private func generateWorkspace(for tenant: Tenant, catalog: LoadedCatalog) throws -> WorkspaceGenerator.Output {
        let selections = try generatedSelections(for: tenant, catalog: catalog)
        let output = try WorkspaceGenerator.generate(WorkspaceInput(
            namePrefix: tenant.namePrefix,
            selections: selections,
            providerVersion: EngineInfo.jamfPlatformProviderVersion,
            removals: tenant.pendingRemovals
        ))
        try WorkspaceGenerator.materialize(
            output,
            selections: selections,
            catalog: catalog,
            workspaceURL: generatedURL(for: tenant)
        )

        // Adopted configuration joins the workspace as root-level files.
        let fileManager = FileManager.default
        let adopted = adoptedURL(for: tenant)
        let generated = generatedURL(for: tenant)
        // The engine's lock file and unpacked provider cache record hashes of
        // the bundled provider archives, which change across app releases
        // (they are re-signed at build time). Providers only ever install
        // from the bundled mirror — cheap and local — so both are re-derived
        // on every init instead of kept; a stale cache makes init fail with
        // "does not match the content of the downloaded package".
        try? fileManager.removeItem(at: generated.appending(path: ".terraform.lock.hcl"))
        try? fileManager.removeItem(at: generated.appending(path: ".terraform"))
        // Clear previously copied adopted files first.
        for stale in (try? fileManager.contentsOfDirectory(at: generated, includingPropertiesForKeys: nil)) ?? []
        where stale.lastPathComponent.hasPrefix("adopted-") {
            try? fileManager.removeItem(at: stale)
        }
        if fileManager.fileExists(atPath: adopted.path) {
            for file in (try? fileManager.contentsOfDirectory(at: adopted, includingPropertiesForKeys: nil)) ?? [] {
                // versions.tf would duplicate the workspace's own provider
                // requirements and fail init.
                if file.pathExtension == "tf", file.lastPathComponent != "versions.tf" {
                    try? fileManager.copyItem(
                        at: file,
                        to: generated.appending(path: "adopted-\(file.lastPathComponent)")
                    )
                } else if file.lastPathComponent == "support_files" {
                    let target = generated.appending(path: "support_files")
                    try? fileManager.removeItem(at: target)
                    try? fileManager.copyItem(at: file, to: target)
                }
            }
        }
        return output
    }

    /// TF_VAR_* values for the workspace's secret settings, resolved from
    /// the Keychain at launch time — never from any file.
    private func secretSettingEnvironment(
        for tenant: Tenant,
        output: WorkspaceGenerator.Output
    ) throws -> [String: String] {
        var environment: [String: String] = [:]
        for (reference, variableName) in output.secretVariableNames {
            let parts = reference.split(separator: "/").map(String.init)
            guard parts.count == 2 else { continue }
            guard let value = TenantSecrets(tenantID: tenant.id)
                .blockSetting(blockID: parts[0], key: parts[1])
                .load()
            else {
                throw DeployError.missingSecretSetting(block: parts[0], setting: parts[1])
            }
            environment["TF_VAR_\(variableName)"] = value
        }
        return environment
    }

    private func generatedSelections(for tenant: Tenant, catalog: LoadedCatalog) throws -> [GeneratedSelection] {
        try tenant.blockSelections.map { selection in
            // Selections from a custom source resolve from that source at
            // the selection's tag (falling back to the tenant's pin). The
            // merged catalog keeps "official wins" on ID conflicts, so a
            // custom source can never shadow an official block by accident —
            // the explicit sourceID on the selection is the opt-in.
            if selection.sourceID != "official",
               let source = catalogSources.customSources.first(where: { $0.id.uuidString == selection.sourceID }) {
                let tag = selection.sourceTag ?? tenant.catalogPins[selection.sourceID]
                if let sourceCatalog = try? catalogSources.load(source: source, tag: tag),
                   let block = sourceCatalog.block(id: selection.blockID) {
                    return GeneratedSelection(
                        block: block,
                        settings: selection.settings,
                        scope: selection.scope,
                        folderURL: sourceCatalog.blockFolderURL(id: selection.blockID)
                    )
                }
            }
            guard let block = catalog.block(id: selection.blockID) else {
                throw DeployError.blockMissingFromCatalog(selection.blockID)
            }
            return GeneratedSelection(block: block, settings: selection.settings, scope: selection.scope)
        }
    }

    private func generatedURL(for tenant: Tenant) -> URL {
        tenantStore.workspaceURL(for: tenant).appending(path: "generated")
    }

    /// Hand-configured objects adopted into the tenant record live here as
    /// root-level configuration (plus one-shot import blocks until applied).
    func adoptedURL(for tenant: Tenant) -> URL {
        tenantStore.workspaceURL(for: tenant).appending(path: "adopted")
    }

    /// Whether the app manages anything in the tenant: deployed blocks, or
    /// adopted configuration that has been deployed. A tenant brought in
    /// entirely through Adopt has no blocks but is fully managed.
    func isManaged(_ tenant: Tenant) -> Bool {
        !tenant.deployedBlockVersions.isEmpty || (tenant.lastDeploy != nil && hasAdoptedConfig(for: tenant))
    }

    /// Whether adopted objects are still managed. After a hand-over the
    /// folder keeps only `removed` blocks, which manage nothing.
    func hasAdoptedConfig(for tenant: Tenant) -> Bool {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: adoptedURL(for: tenant), includingPropertiesForKeys: nil)) ?? []
        return files.contains { file in
            guard file.pathExtension == "tf",
                  let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
            return text.contains(/(?m)^resource\s+"/)
        }
    }

    private func historyURL(for tenant: Tenant) -> URL {
        tenantStore.workspaceURL(for: tenant).appending(path: "history")
    }

    // MARK: State passphrase and recovery escrow

    /// Returns the state passphrase, creating one on first use.
    func statePassphrase(for tenant: Tenant) -> String {
        let item = TenantSecrets(tenantID: tenant.id).statePassphrase
        if let existing = item.load() {
            return existing
        }
        let fresh = Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        item.save(fresh)
        return fresh
    }

    /// The user must save a recovery copy of the passphrase before the first
    /// deploy — losing it makes the tenant record unreadable.
    func needsRecoveryEscrow(for tenant: Tenant) -> Bool {
        !UserDefaults.standard.bool(forKey: recoveryEscrowKey(tenant))
    }

    func markRecoverySaved(for tenant: Tenant) {
        UserDefaults.standard.set(true, forKey: recoveryEscrowKey(tenant))
    }

    private func recoveryEscrowKey(_ tenant: Tenant) -> String {
        "recoverySaved.\(tenant.id.uuidString)"
    }

    func recoverySheetText(for tenant: Tenant) -> String {
        """
        Jamf Deployer — Tenant Record Recovery Sheet
        =============================================

        Tenant:     \(tenant.name)
        Identifier: \(tenant.id.uuidString)
        Created:    \(Date.now.formatted(.iso8601))

        Recovery passphrase:

            \(statePassphrase(for: tenant))

        This passphrase encrypts the tenant record (the app's memory of what
        it manages in this tenant). Keep this sheet in a password manager or
        another safe place. Without it, a reinstalled app cannot read the
        record and the tenant would have to be adopted again.
        """
    }

    // MARK: Engine plumbing

    private func environment(for tenant: Tenant) throws -> [String: String] {
        guard let secret = TenantSecrets(tenantID: tenant.id).platformClientSecret.load() else {
            throw DeployError.missingCredentials
        }
        let needsProtect = (try? loadCatalog()).map { catalog in
            tenant.blockSelections.contains { selection in
                catalog.block(id: selection.blockID)?.products.contains("jamf-protect") == true
            }
        } ?? false
        var environment: [String: String] = [
            "JAMFPLATFORM_BASE_URL": tenant.region.gatewayURL.absoluteString,
            "JAMFPLATFORM_CLIENT_ID": tenant.clientID,
            "JAMFPLATFORM_CLIENT_SECRET": secret,
        ]
        switch tenant.apiScope {
        case .environment:
            environment["JAMFPLATFORM_ENVIRONMENT_ID"] = tenant.scopeID
        case .tenant:
            environment["JAMFPLATFORM_TENANT_ID"] = tenant.scopeID
        }
        if needsProtect {
            guard let protectURL = tenant.protectURL,
                  let protectClientID = tenant.protectClientID,
                  let protectSecret = TenantSecrets(tenantID: tenant.id).protectClientSecret.load()
            else {
                throw DeployError.missingProtectConnection
            }
            environment["JAMFPROTECT_URL"] = protectURL
            environment["JAMFPROTECT_CLIENT_ID"] = protectClientID
            environment["JAMFPROTECT_CLIENT_SECRET"] = protectSecret
        }
        environment["TF_ENCRYPTION"] = """
        key_provider "pbkdf2" "passphrase" {
          passphrase = "\(statePassphrase(for: tenant))"
        }
        method "aes_gcm" "default" {
          keys = key_provider.pbkdf2.passphrase
        }
        state {
          method   = method.aes_gcm.default
          enforced = true
        }
        plan {
          method   = method.aes_gcm.default
          enforced = true
        }
        """
        return environment
    }

    private func makeRunner(for tenant: Tenant, extraEnvironment: [String: String] = [:]) throws -> EngineRunner {
        let runner = EngineRunner(configuration: EngineRunner.Configuration(
            engineURL: EngineLocator.tofuURL,
            workingDirectory: generatedURL(for: tenant),
            cliConfigURL: try EngineLocator.ensureCLIConfig(),
            environment: try environment(for: tenant).merging(extraEnvironment) { _, new in new }
        ))
        runners[tenant.id] = runner
        return runner
    }

    func cancel(tenant: Tenant, force: Bool = false) {
        let runner = runners[tenant.id]
        Task {
            await runner?.cancel(force: force)
        }
    }

    // MARK: Preview

    func preview(tenant: Tenant) async throws -> PreviewSession {
        phase = .generating
        progress = []
        defer { phase = .idle }

        if isTeamMode {
            switch try await gitStore.acquireLock(
                tenantID: tenant.id,
                engineer: engineerName,
                operation: "deploy"
            ) {
            case .acquired:
                tenantStore.reload()
                await syncTeamState()
            case .heldByOther(let holder):
                throw DeployError.lockedByOther(holder.engineer, holder.host)
            }
        }

        try await ensureCatalogCheckouts(for: tenant)
        let catalog = try loadCatalog(for: tenant)
        let output = try generateWorkspace(for: tenant, catalog: catalog)

        // Rebuilt per preview: the environment can change between runs.
        let runner = try makeRunner(
            for: tenant,
            extraEnvironment: try secretSettingEnvironment(for: tenant, output: output)
        )

        phase = .initializing
        logEngine("init", tenant: tenant)
        try await runner.run(arguments: ["init", "-input=false"])

        phase = .planning
        logEngine("plan", tenant: tenant)
        let planRun = try await runner.run(
            arguments: ["plan", "-input=false", "-out=plan.bin", "-json"]
        )
        let plan = try await runner.showPlan(planFileName: "plan.bin")

        var blockNames: [String: String] = ["tenant": "Adopted objects"]
        var blockVersions: [String: String] = [:]
        for resolved in (try? generatedSelections(for: tenant, catalog: catalog)) ?? [] {
            blockNames[resolved.block.id] = resolved.block.name
            blockVersions[resolved.block.id] = resolved.block.version
        }

        let diagnostics = planRun.events.compactMap(\.diagnostic)
        let summary = PreviewBuilder.build(plan: plan, diagnostics: diagnostics, blockNames: blockNames)
        activePreviewTenants.insert(tenant.id)
        return PreviewSession(
            planFileName: "plan.bin",
            summary: summary,
            diagnostics: diagnostics,
            blockVersions: blockVersions,
            createdAt: .now
        )
    }

    // MARK: Deploy

    struct DeployOutcome: Sendable {
        var succeeded: Int
        var failed: Int
        var errors: [String]
        /// Failed creates Jamf completed anyway; the next preview adopts them.
        var recovered: Int = 0
        var historyEntryID: String
    }

    func deploy(tenant: Tenant, session: PreviewSession) async throws -> DeployOutcome {
        guard let runner = runners[tenant.id] else { throw DeployError.planExpired }

        phase = .applying
        progress = []
        defer {
            phase = .idle
            activePreviewTenants.remove(tenant.id)
        }

        logEngine("apply", tenant: tenant)

        var result: EngineRunner.RunResult
        do {
            result = try await runner.run(
                // Jamf's classic API fails more creates under load; four
                // concurrent operations measurably reduce that at little cost.
                arguments: ["apply", "-input=false", "-json", "-parallelism=4", session.planFileName]
            ) { event in
                if event.type == .applyComplete || event.type == .applyErrored {
                    let message = event.message
                    Task { @MainActor in
                        self.progress.append(message)
                    }
                }
            }
        } catch let error as EngineRunner.EngineError {
            guard case .nonZeroExit(let partial) = error else { throw error }
            result = partial
        }

        let succeeded = result.events.count { $0.type == .applyComplete }
        let errors = result.errorDiagnostics.map { diagnostic in
            var text = diagnostic.summary
            if let address = diagnostic.address {
                text = "\(address): \(text)"
            }
            if let detail = diagnostic.detail {
                text += "\n\(detail)"
            }
            return text
        }

        // Objects Jamf created despite reporting an error become imports
        // the next preview adopts, instead of duplicate-name failures.
        var recovered = 0
        if !result.errorDiagnostics.isEmpty,
           let plan = try? await runner.showPlan(planFileName: session.planFileName) {
            recovered = await recoverCreatedObjects(
                tenant: tenant, diagnostics: result.errorDiagnostics, plan: plan, runner: runner)
        }

        // History: the approved plan, a summary, and the full event log.
        let entryID = DeployHistoryEntry.makeID()
        let entryURL = historyURL(for: tenant).appending(path: entryID)
        try? FileManager.default.createDirectory(at: entryURL, withIntermediateDirectories: true)
        // The engine prints sensitive values in clear text; history (and the
        // team repository) only ever gets the redacted copy.
        if let planData = try? await runner.showPlanData(planFileName: session.planFileName),
           let redacted = PlanRedactor.redact(planData) {
            try? redacted.write(to: entryURL.appending(path: "plan.json"))
        }
        let logText = result.rawLines.joined(separator: "\n")
        try? Data(logText.utf8).write(to: entryURL.appending(path: "log.jsonl"))

        let entry = DeployHistoryEntry(
            id: entryID,
            date: .now,
            kind: .deploy,
            engineerName: engineerName,
            macOSUserName: NSUserName(),
            blockVersions: session.blockVersions,
            added: session.summary.counts[.create] ?? 0,
            changed: session.summary.counts[.update] ?? 0,
            removed: session.summary.counts[.remove] ?? 0,
            stoppedManaging: session.summary.counts[.stopManaging] ?? 0,
            failed: errors.count
        )
        try? JSONFile.save(entry, to: entryURL.appending(path: "summary.json"))
        // Snapshot the baseline for rollback.
        try? JSONFile.save(tenant.blockSelections, to: entryURL.appending(path: "tenant-snapshot.json"))

        // Automatic state backup after every deploy.
        backUpState(for: tenant, entryID: entryID)

        activityLog.append(ActivityLogEntry(
            category: "Engine",
            operation: "deploy",
            detail: tenant.name,
            status: errors.isEmpty ? 200 : 500,
            duration: nil,
            note: "\(succeeded) deployed, \(errors.count) failed"
        ))

        var updated = tenant
        updated.lastDeploy = DeployRecord(
            date: .now,
            engineerName: entry.engineerName,
            succeeded: succeeded,
            failed: errors.count
        )
        if errors.isEmpty {
            // Imports are applied; the import blocks have done their job.
            let adopted = adoptedURL(for: tenant)
            for file in (try? FileManager.default.contentsOfDirectory(at: adopted, includingPropertiesForKeys: nil)) ?? []
            where file.lastPathComponent.hasSuffix("_import.tf") {
                try? FileManager.default.removeItem(at: file)
            }
            updated.deployedBlockVersions = session.blockVersions
            updated.pendingRemovals = []
            updated.driftReport = nil
            updated.acknowledgedDrift = []
            updated.lastDriftCheck = .now
            if updated.blockSelections.isEmpty && !hasAdoptedConfig(for: tenant) {
                // Hand over completed: no blocks and no adopted objects are
                // left; the record is archived and the tenant is read-only.
                updated.mode = .handedOver
            }
        }
        tenantStore.update(updated)

        // Record the outcome in the store's history: a commit either way,
        // a push + lock release in team mode.
        let commitMessage = "Deploy \(tenant.name): \(entry.added) added · \(entry.changed) changed · \(entry.removed) removed · \(errors.count) failed — \(entry.engineerName)"
        if isTeamMode {
            try? await gitStore.releaseLock(tenantID: tenant.id, message: commitMessage)
            await syncTeamState()
        } else {
            _ = try? await gitStore.commitAll(message: commitMessage)
        }

        return DeployOutcome(
            succeeded: succeeded,
            failed: errors.count,
            errors: errors,
            recovered: recovered,
            historyEntryID: entryID
        )
    }

    /// Looks up each failed create in Jamf by its planned name and records
    /// the ones that exist as import blocks. Returns how many were found.
    private func recoverCreatedObjects(
        tenant: Tenant,
        diagnostics: [EngineStreamEvent.Diagnostic],
        plan: PlanFile,
        runner: EngineRunner
    ) async -> Int {
        let candidates = CreateFailureRecovery.candidates(diagnostics: diagnostics, plan: plan)
        guard !candidates.isEmpty,
              let secret = TenantSecrets(tenantID: tenant.id).platformClientSecret.load(),
              let stateData = try? await runner.rawCommandOutput(arguments: ["show", "-json"])
        else { return 0 }
        // Objects the state already tracks are never adopted a second time.
        let managed = CreateFailureRecovery.managedIDs(stateJSON: stateData)
        let client = JamfPlatformClient(
            configuration: JamfAPIConfiguration(tenant: tenant, clientSecret: secret),
            activityLog: activityLog
        )
        let fileURL = adoptedURL(for: tenant).appending(path: "recovered_import.tf")
        // Keep recoveries from earlier deploys that have not been applied yet.
        var found: [String: String] = [:]
        if let existing = try? String(contentsOf: fileURL, encoding: .utf8) {
            for match in existing.matches(of: /to = (\S+)\n\s*id = "([^"]+)"/) {
                found[String(match.1)] = String(match.2)
            }
        }
        for candidate in candidates {
            guard let path = CreateFailureRecovery.lookupPath(for: candidate),
                  let (data, status) = try? await client.get(path, query: CreateFailureRecovery.lookupQuery(for: candidate)), status == 200,
                  let id = CreateFailureRecovery.objectID(
                      in: data, for: candidate, excluding: managed[candidate.resourceType] ?? [])
            else { continue }
            // Two failed creates with the same name must not share one object.
            guard !found.values.contains(id) else { continue }
            found[candidate.address] = id
        }
        guard !found.isEmpty else { return 0 }
        try? FileManager.default.createDirectory(at: adoptedURL(for: tenant), withIntermediateDirectories: true)
        let text = CreateFailureRecovery.importFile(found.map { (address: $0.key, id: $0.value) })
        try? Data(text.utf8).write(to: fileURL)
        return candidates.count { found[$0.address] != nil }
    }

    // MARK: Changes made in Jamf (drift)

    /// How many fleet drift checks run at once.
    private static let fleetCheckConcurrency = 3

    private(set) var fleetCheckProgress: (done: Int, total: Int)?

    /// Runs a refresh-only plan and stores what changed outside the app.
    /// Also refreshes the Apple token expiry shown on the dashboard.
    func checkDrift(tenant: Tenant) async throws {
        guard isManaged(tenant) else { return }
        guard !activePreviewTenants.contains(tenant.id) else {
            throw DeployError.previewInProgress
        }

        if isTeamMode {
            switch try await gitStore.acquireLock(
                tenantID: tenant.id,
                engineer: engineerName,
                operation: "check"
            ) {
            case .acquired:
                tenantStore.reload()
            case .heldByOther(let holder):
                throw DeployError.lockedByOther(holder.engineer, holder.host)
            }
        }
        defer {
            let name = tenant.name
            let id = tenant.id
            if isTeamMode {
                Task {
                    try? await self.gitStore.releaseLock(
                        tenantID: id,
                        message: "Check \(name) for changes — \(self.engineerName)"
                    )
                    await self.syncTeamState()
                }
            } else {
                Task {
                    _ = try? await self.gitStore.commitAll(message: "Check \(name) for changes")
                }
            }
        }

        try await ensureCatalogCheckouts(for: tenant)
        let catalog = try loadCatalog(for: tenant)
        let output = try generateWorkspace(for: tenant, catalog: catalog)
        let runner = try makeRunner(
            for: tenant,
            extraEnvironment: try secretSettingEnvironment(for: tenant, output: output)
        )

        logEngine("check", tenant: tenant)
        try await runner.run(arguments: ["init", "-input=false"])
        try await runner.run(arguments: ["plan", "-refresh-only", "-input=false", "-out=drift.bin", "-json"])
        let plan = try await runner.showPlan(planFileName: "drift.bin")

        var blockNames: [String: String] = ["tenant": "Adopted objects"]
        for selection in tenant.blockSelections {
            if let block = catalog.block(id: selection.blockID) {
                blockNames[block.id] = block.name
            }
        }

        var updated = tenantStore.tenant(id: tenant.id) ?? tenant
        updated.driftReport = DriftReportBuilder.build(plan: plan, blockNames: blockNames)
        updated.lastDriftCheck = .now
        await refreshTokenExpiry(&updated)
        tenantStore.update(updated)
        fleetCheckFailures[tenant.id] = nil
    }

    /// Tenants whose last fleet check failed, with a short reason — shown on
    /// the dashboard so a failing check never masquerades as "in sync".
    private(set) var fleetCheckFailures: [UUID: String] = [:]

    /// Checks every deployed tenant, a few at a time.
    func checkAllTenants() async {
        let candidates = tenantStore.tenants.filter {
            isManaged($0) && !$0.isHandedOver
                && !activePreviewTenants.contains($0.id)
        }
        guard !candidates.isEmpty else { return }
        fleetCheckProgress = (0, candidates.count)
        defer { fleetCheckProgress = nil }

        // Batches of three: simple, and plenty for a fleet check.
        var remaining = candidates[...]
        while !remaining.isEmpty {
            let batch = Array(remaining.prefix(Self.fleetCheckConcurrency))
            remaining = remaining.dropFirst(Self.fleetCheckConcurrency)
            // Plain child tasks; the engine work happens off-main inside
            // each tenant's runner, so the batch runs concurrently.
            let tasks = batch.map { tenant in
                Task {
                    do {
                        try await self.checkDrift(tenant: tenant)
                        self.fleetCheckFailures[tenant.id] = nil
                    } catch {
                        self.fleetCheckFailures[tenant.id] =
                            (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    }
                }
            }
            for task in tasks {
                _ = await task.value
                fleetCheckProgress?.done += 1
            }
        }
    }

    func fleetCheckFailure(for tenantID: UUID) -> String? {
        fleetCheckFailures[tenantID]
    }

    private func refreshTokenExpiry(_ tenant: inout Tenant) async {
        guard let secret = TenantSecrets(tenantID: tenant.id).platformClientSecret.load() else { return }
        let client = JamfPlatformClient(
            configuration: JamfAPIConfiguration(tenant: tenant, clientSecret: secret),
            activityLog: activityLog
        )
        nonisolated struct ADEPage: Decodable, Sendable {
            nonisolated struct Instance: Decodable, Sendable { let tokenExpirationDate: String? }
            let results: [Instance]
        }
        nonisolated struct VPPPage: Decodable, Sendable {
            nonisolated struct Location: Decodable, Sendable { let tokenExpiration: String? }
            let results: [Location]
        }
        var snapshot = tenant.preflight ?? PreflightSnapshot(date: .now, allGreen: true)
        if let page = try? await client.getDecoded(ADEPage.self, path: "/pro/v1/device-enrollments") {
            snapshot.adeTokenExpiration = page.results.compactMap(\.tokenExpirationDate).min()
        }
        if let page = try? await client.getDecoded(VPPPage.self, path: "/pro/v1/volume-purchasing-locations") {
            snapshot.vppTokenExpiration = page.results.compactMap(\.tokenExpiration).min()
        }
        snapshot.date = .now
        tenant.preflight = snapshot
    }

    // MARK: Drift actions

    enum KeepOutcome {
        /// The value was written into the controlling block setting — the
        /// baseline itself now carries it.
        case adoptedIntoSetting(String)
        /// No setting controls this field; the change is acknowledged but a
        /// deploy would still restore the baseline value.
        case acknowledged
    }

    /// "Keep this change": adopts the console value into the bound block
    /// setting where one exists, otherwise records an acknowledgment.
    @discardableResult
    func keepDrift(tenant: Tenant, object: DriftedObject, field: FieldDiff) -> KeepOutcome {
        var updated = tenant
        var outcome = KeepOutcome.acknowledged

        if let catalog = try? loadCatalog(),
           let block = catalog.block(id: object.blockID),
           let settingKey = block.settingKey(forResourceType: object.resourceType, fieldPath: field.path),
           let rawValue = field.rawAfter,
           let index = updated.blockSelections.firstIndex(where: { $0.blockID == object.blockID }) {
            updated.blockSelections[index].settings[settingKey] = rawValue
            outcome = .adoptedIntoSetting(settingKey)
        }

        let key = "\(object.address)|\(field.path)|\(field.after)"
        if !updated.acknowledgedDrift.contains(key) {
            updated.acknowledgedDrift.append(key)
        }
        tenantStore.update(updated)
        return outcome
    }

    // MARK: Rollback

    /// Restores a history entry's block selection so the next preview plans
    /// back to that baseline against the tenant's current state.
    func rollback(tenant: Tenant, toHistoryEntry entryID: String) throws {
        let snapshotURL = historyURL(for: tenant)
            .appending(path: entryID)
            .appending(path: "tenant-snapshot.json")
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else {
            throw DeployError.noSnapshot
        }
        let selections = try JSONFile.load([BlockSelection].self, from: snapshotURL)
        var updated = tenant
        updated.blockSelections = selections
        updated.pendingRemovals = []
        tenantStore.update(updated)
    }

    // MARK: Hand over

    /// Prepares hand-over: everything deployed is marked "stop managing".
    /// The user then previews and deploys; on success the tenant archives.
    func prepareHandOver(tenant: Tenant) {
        var updated = tenant
        updated.pendingRemovals = updated.deployedBlockVersions.keys.map {
            BlockRemoval(blockID: $0, keepInJamf: true)
        }
        updated.blockSelections = []
        releaseAdoptedConfig(for: tenant)
        tenantStore.update(updated)
    }

    /// Adopted objects are released the same way as blocks: their
    /// configuration is archived (kept, not deleted) and replaced by
    /// removed blocks, so the next deploy forgets them instead of deleting
    /// them from Jamf.
    private func releaseAdoptedConfig(for tenant: Tenant) {
        let fileManager = FileManager.default
        let adopted = adoptedURL(for: tenant)
        guard let addresses = try? ExportedObjectInventory.scan(directory: adopted).map(\.address),
              !addresses.isEmpty
        else { return }
        let archive = tenantStore.workspaceURL(for: tenant)
            .appending(path: "adopted-handed-over-\(DeployHistoryEntry.makeID())")
        do {
            try fileManager.moveItem(at: adopted, to: archive)
            try fileManager.createDirectory(at: adopted, withIntermediateDirectories: true)
            let blocks = addresses.sorted().map { address in
                "removed {\n  from = \(address)\n\n  lifecycle {\n    destroy = false\n  }\n}\n"
            }
            try Data(blocks.joined(separator: "\n").utf8)
                .write(to: adopted.appending(path: "handover_removed.tf"))
        } catch {
            activityLog.append(ActivityLogEntry(
                category: "Engine", operation: "hand over", detail: tenant.name,
                status: 500, duration: nil, note: "Adopted objects could not be prepared: \(error.localizedDescription)"
            ))
        }
    }

    // MARK: History reading

    func historyEntries(for tenant: Tenant) -> [DeployHistoryEntry] {
        let root = historyURL(for: tenant)
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders
            .compactMap { try? JSONFile.load(DeployHistoryEntry.self, from: $0.appending(path: "summary.json")) }
            .sorted { $0.date > $1.date }
    }

    // MARK: Helpers

    private var engineerName: String {
        let configured = UserDefaults.standard.string(forKey: "engineerName") ?? ""
        return configured.isEmpty ? NSFullUserName() : configured
    }

    private func backUpState(for tenant: Tenant, entryID: String) {
        let stateURL = tenantStore.workspaceURL(for: tenant).appending(path: "state/terraform.tfstate")
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return }
        let backupsURL = tenantStore.workspaceURL(for: tenant).appending(path: "state/backups")
        try? FileManager.default.createDirectory(at: backupsURL, withIntermediateDirectories: true)
        try? FileManager.default.copyItem(
            at: stateURL,
            to: backupsURL.appending(path: "\(entryID).tfstate")
        )
    }

    private func logEngine(_ operation: String, tenant: Tenant) {
        activityLog.append(ActivityLogEntry(
            category: "Engine",
            operation: operation,
            detail: tenant.name,
            status: nil,
            duration: nil,
            note: nil
        ))
    }

    nonisolated enum DeployError: LocalizedError {
        case missingCredentials
        case planExpired
        case blockMissingFromCatalog(String)
        case noSnapshot
        case missingProtectConnection
        case lockedByOther(String, String)
        case missingSecretSetting(block: String, setting: String)
        case previewInProgress

        var errorDescription: String? {
            switch self {
            case .missingCredentials:
                "The tenant's client secret is missing from the Keychain. Remove and reconnect the tenant."
            case .planExpired:
                "This preview is no longer valid. Run Preview Changes again before deploying."
            case .blockMissingFromCatalog(let id):
                "The building block \"\(id)\" is selected on this tenant, but it is not in any catalog this Mac follows. Add the catalog it comes from (Building Blocks library), or remove it from the baseline."
            case .noSnapshot:
                "This history entry is from before baseline snapshots existed, so it can't be rolled back to."
            case .missingProtectConnection:
                "This baseline includes Jamf Protect blocks, but the tenant has no Protect connection. Add the Protect console URL and API client in the Day 0 Setup tab first."
            case .lockedByOther(let engineer, let host):
                "This tenant is being worked on by \(engineer) on \(host). Try again when they finish, or break the lock from the tenant view if it is stale."
            case .missingSecretSetting(let block, let setting):
                "The \"\(block)\" block needs its \"\(setting)\" secret on this Mac. Enter it in the block's settings — secrets stay in each engineer's Keychain."
            case .previewInProgress:
                "A preview is open for this tenant. Finish or close it before checking for changes."
            }
        }
    }
}
