import Foundation
import AppKit
import os
import JTKit
import JamfDeployerCore

/// A plan the user is looking at. Only this exact saved plan can be
/// deployed — never a regenerated one.
nonisolated struct PreviewSession: Sendable {
    var planFileName: String
    var summary: PreviewSummary
    var diagnostics: [EngineStreamEvent.Diagnostic]
    var blockVersions: [String: String]
    var createdAt: Date
    /// The engine commands this preview ran, and the one Deploy runs, as a
    /// person would type them in the workspace (credentials stay in the
    /// environment, never on the command line).
    var engineCommands: [String] = []
    var deployCommand: String = ""
    /// The generated configuration the commands ran in, and its main files
    /// as they were when the preview ran.
    var workspaceURL: URL?
    var generatedFiles: [GeneratedFile] = []

    struct GeneratedFile: Sendable, Hashable {
        var name: String
        var text: String
    }

    static func generatedFiles(in workspace: URL) -> [GeneratedFile] {
        ["main.tf", "providers.tf"].compactMap { name in
            (try? String(contentsOf: workspace.appending(path: name), encoding: .utf8))
                .map { GeneratedFile(name: name, text: $0) }
        }
    }
}

/// Orchestrates everything between "Preview Changes" and "Deploy" for every
/// tenant: workspace generation, engine runs, drift checks, history and
/// state backups. A tenant never has two engine runs at once.
@Observable
final class TenantDeployService {
    enum Phase: Equatable {
        case idle
        case generating
        case initializing
        case planning
        case applying
    }

    /// Engine phase and live apply progress, per tenant: previews and
    /// deploys of different tenants may run at the same time.
    private var phases: [UUID: Phase] = [:]
    private var progressLines: [UUID: [String]] = [:]

    func phase(for tenantID: UUID) -> Phase { phases[tenantID] ?? .idle }
    func progress(for tenantID: UUID) -> [String] { progressLines[tenantID] ?? [] }

    private let tenantStore: TenantStore
    private let activityLog: ActivityLog
    private let catalogSources: CatalogSourceStore
    let gitStore: GitStoreService
    let stateBackend: StateBackendService
    /// The doorway OpenTofu, jamformer, the state backend and git start
    /// through; demo mode's never starts them.
    let tools: ToolDoorway
    /// Demo mode's service: its own store in the temporary folder, no Git,
    /// no Team Mode, no engine. Previews show a fixed plan and stop there;
    /// checks for changes compare against the demo server.
    let isDemo: Bool
    private var runners: [UUID: EngineRunner] = [:]

    /// Tenants with an open preview; a drift check would regenerate the
    /// workspace and invalidate the saved plan, so it is blocked until the
    /// preview is deployed or closed. (Not private: tests stage one.)
    var activePreviewTenants: Set<UUID> = []
    /// Tenants with an engine run in progress (preview, check, deploy, a
    /// state move or a passphrase check): one run per tenant workspace at a
    /// time. (Not private: tests stage one.)
    var busyTenants: Set<UUID> = []
    /// Tenants whose team-space state is being deleted (Remove Tenant).
    private var removingTenants: Set<UUID> = []
    /// State is moving between this Mac and the team space.
    private var isMovingState = false
    /// Tenants whose state the last move into the team space copied there:
    /// the only local copies `retireLocalState(of:)` retires.
    private var stateMovedToTeam: Set<UUID> = []

    func isRemoving(_ tenantID: UUID) -> Bool {
        removingTenants.contains(tenantID)
    }

    /// Team-space state the UI shows.
    private(set) var isTeamMode = false
    private(set) var teamRemoteURL: String?
    /// The engine's state locks in the team space, by tenant.
    private(set) var locks: [UUID: StateBackendService.StateLock] = [:]
    private(set) var lastSync: Date?
    private(set) var syncMessage: String?

    /// Possible secrets shown in the store review sheet: a commit they
    /// stopped, or the one-time check of a store from before the check.
    struct StoreSecretReview: Identifiable {
        enum Kind {
            /// The commit that was stopped, to try again.
            case commitBlocked(message: String)
            /// Stopped elsewhere (Team settings): nothing to retry here.
            case commitStopped
            case existingStore
        }
        let id = UUID()
        var kind: Kind
        var findings: [GitStoreService.StoreFinding]
        /// Marked "not a secret" while the sheet is open.
        var acknowledged: Set<SecretFinding> = []
    }
    var storeSecretReview: StoreSecretReview?

    /// Set once every store on this Mac has had the one-time check.
    static let storeSecretCheckDefaultsKey = "storeSecretCheckDone"

    /// The store's Git repository (demo mode's and test runs' are their own).
    let storeURL: URL

    /// This Mac's flags (one-time store check done, recovery sheet saved):
    /// the app's UserDefaults, and in test runs (unit tests, sandbox
    /// launches) a set kept in memory, so a test never marks the real app's.
    let flags: Flags

    final class Flags {
        private let defaults: UserDefaults?
        private var memory: [String: Bool] = [:]

        init(inMemory: Bool) {
            defaults = inMemory ? nil : .standard
        }

        func bool(forKey key: String) -> Bool {
            defaults?.bool(forKey: key) ?? memory[key] ?? false
        }

        func set(_ value: Bool, forKey key: String) {
            if let defaults { defaults.set(value, forKey: key) } else { memory[key] = value }
        }

        func remove(_ key: String) {
            if let defaults { defaults.removeObject(forKey: key) } else { memory[key] = nil }
        }
    }

    /// - Parameters:
    ///   - storeURL: the store's Git repository; demo mode's lives in its temporary folder.
    ///   - tools: the doorway outside programs start through (`.demo` in demo mode).
    init(
        tenantStore: TenantStore,
        activityLog: ActivityLog,
        catalogSources: CatalogSourceStore,
        storeURL: URL = GitStoreService.storeURL,
        tools: ToolDoorway,
        isDemo: Bool = false
    ) {
        self.tenantStore = tenantStore
        self.activityLog = activityLog
        self.catalogSources = catalogSources
        self.tools = tools
        self.isDemo = isDemo
        self.storeURL = storeURL
        flags = Flags(inMemory: TestRun.isActive)
        gitStore = GitStoreService(storeURL: storeURL, tools: tools)
        stateBackend = StateBackendService(tools: tools)
        // A changed source list is recorded in the store like every other
        // change (and shared in Team Mode).
        self.catalogSources.onChange = { [weak self] message in
            Task { @MainActor in
                guard let self else { return }
                await self.recordInStore("\(message) — \(self.engineerName)")
            }
        }
        // Every change to a tenant record is recorded in the store (and
        // shared in Team Mode), wherever in the app it is made.
        self.tenantStore.onChange = { [weak self] tenant, kind in
            self?.noteRecordChange(tenant: tenant, kind: kind)
        }
        // A backend left behind by a crash or force-quit is stopped (not
        // by demo mode: it never started one, nor by the unit tests' host:
        // the installed app may be running its own).
        if !isDemo && !TestRun.isUnitTestHost { StateBackendService.stopLeftoverBackend() }
        // The state backend is a child process; it must not outlive the app.
        let backend = stateBackend
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { backend.stop() }
        }
    }

    var isBusy: Bool {
        !busyTenants.isEmpty
    }

    /// Any engine work at all: a preview, check or deploy running, a preview
    /// open, a fleet check, a state move or a removal. Force Unlock and
    /// Remove Tenant wait for it; the UI disables them meanwhile.
    var isEngineWorkRunning: Bool {
        !busyTenants.isEmpty || !activePreviewTenants.isEmpty || !removingTenants.isEmpty
            || isMovingState || fleetCheckProgress != nil
    }

    // MARK: Team space

    /// Called at launch and from Sync Now: makes sure the repo exists, pulls
    /// when a team space is connected, and refreshes stores and locks.
    /// Every record change is committed before the pull (no stash), a pull
    /// that conflicts is undone, and this Mac's commits are published. A
    /// failed sync is kept in `syncMessage`; previews, checks and deploys
    /// stop on it.
    func syncTeamState() async {
        // demo mode has no store repository and no team space
        guard !isDemo else { return }
        do {
            try await gitStore.ensureRepo()
            isTeamMode = await gitStore.isTeamMode()
            teamRemoteURL = try? await gitStore.remoteURL
            let message = takePendingRecordMessage() ?? "Save changes before syncing — \(engineerName)"
            if isTeamMode {
                do {
                    try await gitStore.sync(savingChangesAs: message)
                } catch GitStoreService.GitError.possibleSecrets(let findings) {
                    storeSecretReview = StoreSecretReview(
                        kind: .commitBlocked(message: message),
                        findings: findings.map { .init(finding: $0, inEarlierVersion: false) })
                    throw GitStoreService.GitError.possibleSecrets(findings)
                }
                tenantStore.reload()
                catalogSources.reload()
                locks = await gitStore.stateLocks()
            } else {
                do {
                    _ = try await gitStore.commitAll(message: message)
                } catch GitStoreService.GitError.possibleSecrets(let findings) {
                    storeSecretReview = StoreSecretReview(
                        kind: .commitBlocked(message: message),
                        findings: findings.map { .init(finding: $0, inEarlierVersion: false) })
                } catch {
                    // As before: a store that cannot commit (no Git) keeps working.
                }
                locks = [:]
                stateBackend.stop()
            }
            lastSync = .now
            syncMessage = nil
        } catch {
            syncMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// In Team Mode, syncs and stops when that failed: engine work never
    /// runs on a baseline that may be behind the team's.
    private func syncBeforeEngineWork() async throws {
        if isTeamMode {
            await syncTeamState()
            if let syncMessage { throw DeployError.teamSyncFailed(syncMessage) }
        } else {
            await flushPendingRecords()
        }
    }

    func lock(for tenantID: UUID) -> StateBackendService.StateLock? {
        locks[tenantID]
    }

    /// The preview sheet closed without deploying.
    func abandonPreview(tenant: Tenant) {
        activePreviewTenants.remove(tenant.id)
    }

    /// Releases a lock left behind by an interrupted run on another Mac,
    /// by deleting its lock branch (see GitStoreService.deleteStateLock).
    func forceUnlock(tenant: Tenant, lock: StateBackendService.StateLock) async throws {
        guard !isDemo else { throw DeployError.notInDemoMode }
        // The state backend is shared by every tenant: restarting it under
        // another tenant's run would cut that run off from its state.
        try guardNoEngineWork()
        busyTenants.insert(tenant.id)
        defer { busyTenants.remove(tenant.id) }
        try await gitStore.deleteStateLock(tenantID: tenant.id, lockID: lock.lockID)
        await stateBackend.restartFresh()
        activityLog.append(ActivityLogEntry(
            category: "Team", operation: "force-unlock", detail: tenant.name,
            status: 200, duration: nil, note: "Lock held by \(lock.who)"))
        await syncTeamState()
    }

    // MARK: Moving state between this Mac and the team space

    /// Copies the given tenants' state from their workspaces into the team
    /// space, re-encrypted with the team passphrase. Runs with Team Mode on.
    /// State is piped from `state pull` into `state push` and never written
    /// to disk decrypted. Every tenant with state moves, deployed or not: a
    /// first deploy that partly failed still has objects in its state. The
    /// local copies stay in place until `retireLocalState(of:)`, so a setup
    /// that fails later can be undone. Returns the tenants whose state moved.
    @discardableResult
    func moveStateToTeam(tenants: [Tenant]) async throws -> [Tenant] {
        guard !isDemo else { throw DeployError.notInDemoMode }
        try guardNoEngineWork()
        stateMovedToTeam = []
        let candidates = tenants.filter { !$0.isHandedOver && hasLocalState($0) }
        isMovingState = true
        busyTenants.formUnion(candidates.map(\.id))
        defer {
            isMovingState = false
            busyTenants.subtract(candidates.map(\.id))
        }
        var moved: [Tenant] = []
        for tenant in candidates {
            let catalog = try loadCatalog(for: tenant)

            try generateWorkspace(for: tenant, catalog: catalog, stateBackend: .local)
            let local = try await makeRunner(for: tenant, stateBackend: .local, passphrase: try ownStatePassphrase(for: tenant))
            try await runEngine(local, ["init", "-input=false"])
            let state = try await local.checkedOutput(arguments: ["state", "pull"])
            guard Self.holdsState(state) else { continue }

            try generateWorkspace(for: tenant, catalog: catalog, stateBackend: .http)
            let team = try await makeRunner(for: tenant, stateBackend: .http)
            try await runEngine(team, ["init", "-input=false"])
            _ = try await team.checkedOutput(arguments: ["state", "push", "-"], input: state)
            moved.append(tenant)
            stateMovedToTeam.insert(tenant.id)
        }
        // The first state in a team space without a passphrase check gets one.
        if !moved.isEmpty { try await ensurePassphraseCheck() }
        return moved
    }

    /// Once the team space holds their state, the local copies of the
    /// tenants the last `moveStateToTeam` moved become encrypted backups.
    /// Any other tenant's state stays where it is.
    func retireLocalState(of tenants: [Tenant]) {
        let moved = tenants.filter { stateMovedToTeam.contains($0.id) }
        stateMovedToTeam.subtract(moved.map(\.id))
        retire(moved, reason: "before-team-space")
    }

    /// The tenants' local state files become encrypted backups.
    private func retire(_ tenants: [Tenant], reason: String) {
        for tenant in tenants {
            let stateURL = localStateURL(for: tenant)
            guard FileManager.default.fileExists(atPath: stateURL.path) else { continue }
            let backups = stateURL.deletingLastPathComponent().appending(path: "backups")
            try? FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
            try? FileManager.default.moveItem(
                at: stateURL, to: backups.appending(path: "\(reason)-\(DeployHistoryEntry.makeID()).tfstate"))
        }
    }

    private func localStateURL(for tenant: Tenant) -> URL {
        tenantStore.workspaceURL(for: tenant).appending(path: "state/terraform.tfstate")
    }

    /// Whether the tenant's workspace has a state file with anything in it.
    func hasLocalState(_ tenant: Tenant) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: localStateURL(for: tenant).path)[.size] as? Int) ?? 0
        return size > 0
    }

    /// Whether `state pull` printed a state (it prints nothing when there is none).
    nonisolated static func holdsState(_ output: Data) -> Bool {
        !String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// State moves, Force Unlock and Remove Tenant touch the shared state
    /// backend or a tenant's workspace, so nothing else may run.
    private func guardNoEngineWork() throws {
        guard !isEngineWorkRunning else { throw DeployError.engineWorkInProgress }
    }

    /// Moves every tenant's state from the team space back into its
    /// workspace, encrypted with the tenant's own passphrase (a new one when
    /// the tenant was created in the team space). Runs before leaving. Every
    /// tenant with state in the team space moves, deployed or not; a
    /// handed-over tenant's never does. Returns the tenants whose state moved.
    @discardableResult
    func moveStateToLocal() async throws -> [Tenant] {
        guard !isDemo else { throw DeployError.notInDemoMode }
        try guardNoEngineWork()
        let candidates = tenantStore.tenants.filter { !$0.isHandedOver }
        isMovingState = true
        busyTenants.formUnion(candidates.map(\.id))
        defer {
            isMovingState = false
            busyTenants.subtract(candidates.map(\.id))
        }
        var moved: [Tenant] = []
        for tenant in candidates {
            let catalog = try loadCatalog(for: tenant)
            try generateWorkspace(for: tenant, catalog: catalog, stateBackend: .http)
            let team = try await makeRunner(for: tenant, stateBackend: .http)
            try await runEngine(team, ["init", "-input=false"])
            let state = try await team.checkedOutput(arguments: ["state", "pull"])
            guard Self.holdsState(state) else { continue }

            let hadPassphrase = TenantSecrets(tenantID: tenant.id).statePassphrase.load() != nil
            let passphrase = try ownStatePassphrase(for: tenant)
            if !hadPassphrase {
                // A new passphrase needs a new recovery sheet.
                flags.remove(recoveryEscrowKey(tenant))
            }
            try generateWorkspace(for: tenant, catalog: catalog, stateBackend: .local)
            let local = try await makeRunner(for: tenant, stateBackend: .local, passphrase: passphrase)
            try await runEngine(local, ["init", "-input=false"])
            _ = try await local.checkedOutput(arguments: ["state", "push", "-"], input: state)
            moved.append(tenant)
        }
        return moved
    }

    // MARK: Export as Terraform

    struct RepositoryExportResult {
        var folder: URL
        var tenantFolders: [String]
        /// Published, state moved, tenants archived here.
        var moved: Bool
    }

    /// Writes `tenants` as a plain Terraform repository in `folder`. With
    /// `remote` (an empty repository), also publishes it, moves each
    /// tenant's state to the repository's state branch, and stops managing
    /// the tenants in this app: the repository manages them from then on.
    func exportRepository(_ chosen: [Tenant], to folder: URL, remote: String?) async throws -> RepositoryExportResult {
        guard !isDemo else { throw DeployError.notInDemoMode }
        try guardNoEngineWork()
        if let remote, RepositoryPublisher.hasCredentials(remote) { throw DeployError.remoteHasCredentials }
        // In Team Mode the team space is the truth: pull it, and refuse
        // while a teammate is working on one of the tenants.
        if isTeamMode {
            await syncTeamState()
            if let syncMessage { throw DeployError.teamSyncFailed(syncMessage) }
        }
        let tenants = chosen.map { tenantStore.tenant(id: $0.id) ?? $0 }
        for tenant in tenants {
            if let lock = locks[tenant.id] { throw DeployError.locked(lock) }
            if tenant.isHandedOver || tenant.handOverPending || !tenant.pendingRemovals.isEmpty {
                throw StandaloneExport.ExportError.pendingRemovals(tenant: tenant.name)
            }
        }
        for tenant in tenants { busyTenants.insert(tenant.id) }
        defer { for tenant in tenants { busyTenants.remove(tenant.id) } }

        var exports: [StandaloneExport.Tenant] = []
        var folders: [UUID: String] = [:]
        var outputs: [UUID: WorkspaceGenerator.Output] = [:]
        for tenant in tenants {
            let catalog = try loadCatalog(for: tenant)
            // Regenerating the workspace also lays out its adopted files.
            outputs[tenant.id] = try generateWorkspace(for: tenant, catalog: catalog)
            let selections = try WorkspaceGenerator.resolveModules(
                generatedSelections(for: tenant, catalog: catalog), catalog: catalog, connection: tenant.connection)
            let slug = StandaloneExport.slug(for: tenant.name, taken: Set(folders.values))
            folders[tenant.id] = slug
            let generated = generatedURL(for: tenant)
            let adopted = ((try? FileManager.default.contentsOfDirectory(at: generated, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasPrefix("adopted-") || $0.lastPathComponent == "support_files" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            exports.append(StandaloneExport.Tenant(
                slug: slug,
                input: WorkspaceInput(
                    namePrefix: tenant.namePrefix,
                    selections: selections,
                    providerVersion: EngineInfo.jamfPlatformProviderVersion,
                    protectProviderVersion: EngineInfo.jamfProtectProviderVersion,
                    connection: tenant.connection,
                    jamfProProviderVersion: EngineInfo.jamfProProviderVersion,
                    stateBackend: .http),
                blockFolders: Dictionary(uniqueKeysWithValues: selections.map {
                    ($0.block.id, $0.folderURL ?? catalog.blockFolderURL(id: $0.block.id))
                }),
                adoptedFiles: adopted))
        }
        let script = environmentScript(for: tenants, exports: exports, folders: folders)
        let templates = EngineLocator.exportTemplatesURL
        try await Task.detached {
            try StandaloneExport.write(exports, templatesURL: templates, to: folder, repository: remote)
            let url = folder.appending(path: "create-environments.sh")
            try Data(script.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }.value
        // Adopted files come from the exporter and the object editor in
        // their own layout; the repository's pipeline checks the canonical
        // one, so everything is formatted the way terraform fmt formats it.
        try await Self.formatConfiguration(in: folder, tools: tools)

        let result = RepositoryExportResult(
            folder: folder, tenantFolders: tenants.compactMap { folders[$0.id] }, moved: remote != nil)
        guard let remote else { return result }

        // The repository starts with nothing to apply: whatever is not
        // deployed (or was changed in Jamf) is settled here first.
        var states: [(slug: String, state: Data)] = []
        for tenant in tenants {
            // The plan needs the tenant's secret settings, as a preview does.
            let secrets = try outputs[tenant.id].map { try secretSettingEnvironment(for: tenant, output: $0) } ?? [:]
            let runner = try await makeRunner(for: tenant, extraEnvironment: secrets)
            try await runEngine(runner, ["init", "-input=false"])
            do {
                try await runner.run(arguments: ["plan", "-input=false", "-detailed-exitcode", "-lock=false", "-json"]
                    + Self.readParallelism(for: tenant))
            } catch EngineRunner.EngineError.nonZeroExit(let run) where run.exitCode == 2 {
                throw DeployError.exportHasChanges(tenant: tenant.name)
            }
            let state = try await runner.checkedOutput(arguments: ["state", "pull"])
            guard !state.isEmpty, let slug = folders[tenant.id] else { continue }
            states.append((slug, try StandaloneExport.stateForTerraform(state)))
        }

        // State lands before main, so the repository's first commit has
        // its state behind it; that commit skips the workflows.
        try await RepositoryPublisher.prepare(folder, remote: remote, tools: tools)
        do {
            for (slug, state) in states {
                try await stateBackend.pushState(
                    state, remote: remote, ref: RepositoryPublisher.stateBranch,
                    path: "tenants/\(slug)/terraform.tfstate")
            }
            try await RepositoryPublisher.publishMain(folder, tools: tools)
        } catch {
            throw DeployError.exportStateNotMoved(Self.describe(error))
        }

        // The repository manages these tenants now; here they are archived.
        for tenant in tenants {
            var updated = tenantStore.tenant(id: tenant.id) ?? tenant
            archiveAdoptedConfig(for: tenant)
            updated.mode = .handedOver
            updated.exportedTo = remote
            tenantStore.update(updated)
        }
        retire(tenants, reason: "before-export")
        // The repository holds their state now; a copy left in the team
        // space could be brought back (Leave Team Mode) and used against it.
        if isTeamMode, let teamRemote = teamRemoteURL {
            for tenant in tenants {
                do {
                    try await stateBackend.deleteState(tenantID: tenant.id, remote: teamRemote)
                } catch {
                    activityLog.append(ActivityLogEntry(
                        category: "Team", operation: "delete state", detail: tenant.name, status: 500, duration: nil,
                        note: EngineOutputCleaner.cleaned("The team space’s copy of the state couldn’t be deleted: \(Self.describe(error))")))
                }
            }
        }
        await recordInStore("Move \(tenants.map(\.name).joined(separator: ", ")) to \(remote) — \(engineerName)")
        return result
    }

    /// A one-time setup script for the exported repository. Each tenant
    /// gets two GitHub Environments: `<tenant>`, which only main may use,
    /// with the credentials that change Jamf, and `<tenant>-plan` for pull
    /// request plans, which may take a read-only client instead. Secrets are
    /// asked for with typing hidden; the script holds none, and the
    /// repository ignores it.
    private func environmentScript(
        for tenants: [Tenant], exports: [StandaloneExport.Tenant], folders: [UUID: String]
    ) -> String {
        func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        var lines = [
            "#!/bin/sh",
            "# Creates each tenant's GitHub Environments in the exported repository:",
            "# <tenant>, which only main may use (apply, restore, destroy, checks),",
            "# and <tenant>-plan for pull request plans. Sets their identifiers and",
            "# asks for each secret (typing is hidden; gh reads the value from",
            "# standard input). Run once, after publishing:",
            "#   ./create-environments.sh OWNER/REPOSITORY",
            "set -eu",
            "REPO=\"${1:?usage: $0 OWNER/REPOSITORY}\"",
            "trap 'stty echo 2> /dev/null || true' EXIT INT TERM",
            "environment() {",
            "  printf '{\"deployment_branch_policy\":{\"protected_branches\":false,\"custom_branch_policies\":true}}' \\",
            "    | gh api -X PUT \"repos/$REPO/environments/$1\" --input - --silent",
            "  gh api -X POST \"repos/$REPO/environments/$1/deployment-branch-policies\" -f name=main --silent 2> /dev/null || true",
            "  gh api -X PUT \"repos/$REPO/environments/$1-plan\" --silent",
            "}",
            "variable() {",
            "  gh variable set \"$2\" --repo \"$REPO\" --env \"$1\" --body \"$3\"",
            "  gh variable set \"$2\" --repo \"$REPO\" --env \"$1-plan\" --body \"$3\"",
            "}",
            "ask() { stty -echo 2> /dev/null || true; read -r value || value=; stty echo 2> /dev/null || true; printf '\\n'; }",
            "secret() {",
            "  printf '%s for %s: ' \"$2\" \"$1\"; ask",
            "  printf '%s' \"$value\" | gh secret set \"$2\" --repo \"$REPO\" --env \"$1\"",
            "  printf '%s for %s plans (Return: the same; a read-only client is safer): ' \"$2\" \"$1\"",
            "  same=\"$value\"; ask; [ -n \"$value\" ] || value=\"$same\"",
            "  printf '%s' \"$value\" | gh secret set \"$2\" --repo \"$REPO\" --env \"$1-plan\"",
            "}",
        ]
        for (tenant, export) in zip(tenants, exports) {
            guard let slug = folders[tenant.id] else { continue }
            let env = quoted(slug)
            // A name is only a comment here; nothing in it may end the line.
            let comment = String(tenant.name.unicodeScalars.map {
                CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) ? " " : Character($0)
            })
            lines.append("")
            lines.append("# \(comment)")
            lines.append("environment \(env)")
            if tenant.isJamfPro {
                lines.append("variable \(env) JAMFPRO_INSTANCE_FQDN \(quoted(tenant.jamfProURL ?? ""))")
                let basic = tenant.jamfProAuth == .userAccount
                lines.append("variable \(env) JAMFPRO_AUTH_METHOD \(basic ? "basic" : "oauth2")")
                lines.append("variable \(env) PARALLELISM 1")
                lines.append("secret \(env) \(basic ? "JAMFPRO_BASIC_USERNAME" : "JAMFPRO_CLIENT_ID")")
                lines.append("secret \(env) \(basic ? "JAMFPRO_BASIC_PASSWORD" : "JAMFPRO_CLIENT_SECRET")")
            } else {
                lines.append("variable \(env) JAMFPLATFORM_BASE_URL \(quoted(tenant.region.gatewayURL.absoluteString))")
                if let environmentID = tenant.environmentID {
                    lines.append("variable \(env) JAMFPLATFORM_ENVIRONMENT_ID \(quoted(environmentID))")
                } else if let tenantID = tenant.tenantID {
                    // Older API clients are scoped to the tenant.
                    lines.append("variable \(env) JAMFPLATFORM_TENANT_ID \(quoted(tenantID))")
                }
                lines.append("secret \(env) JAMFPLATFORM_CLIENT_ID")
                lines.append("secret \(env) JAMFPLATFORM_CLIENT_SECRET")
            }
            if let protectURL = tenant.protectURL {
                lines.append("variable \(env) JAMFPROTECT_URL \(quoted(protectURL))")
                lines.append("secret \(env) JAMFPROTECT_CLIENT_ID")
                lines.append("secret \(env) JAMFPROTECT_CLIENT_SECRET")
            }
            for secret in (try? WorkspaceGenerator.moduleCalls(export.input).secrets) ?? [] {
                lines.append("secret \(env) TF_VAR_\(secret.name.uppercased())")
            }
            // The adopted configuration's sensitive values, like secret settings.
            for name in adoptedSensitiveVariables(for: tenant) {
                lines.append("secret \(env) TF_VAR_\(name.uppercased())")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func formatConfiguration(in folder: URL, tools: ToolDoorway) async throws {
        try await Task.detached {
            let process = try tools.process(.openTofu, executable: EngineLocator.tofuURL,
                                            arguments: ["fmt", "-recursive", "-list=false", folder.path])
            let errors = Pipe()
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errors
            try process.run()
            let output = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw DeployError.exportNotFormatted(String(decoding: output, as: UTF8.self))
            }
        }.value
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// Whether the team passphrase on this Mac opens the team space's
    /// deployment state. Checked first against the team space's passphrase
    /// check (a small state OpenTofu encrypted with the team passphrase when
    /// the team space was created), else against tenants whose state is in
    /// the team space, in a throwaway workspace of its own. True only when
    /// that state opened, or when the team space holds neither (a team space
    /// from an earlier version that nobody deployed to yet: nothing is
    /// encrypted to compare against). Throws when there is state but none of
    /// it could be read: a passphrase that wasn't verified is never accepted.
    func checkTeamPassphrase() async throws -> Bool {
        guard !isDemo else { throw DeployError.notInDemoMode }
        guard let remote = teamRemoteURL else { throw DeployError.noTeamSpace }
        let contents = try await gitStore.teamStateContents()
        let plan = Self.passphraseCheckPlan(contents)
        guard plan != .nothingToCompare else { return true }
        guard let passphrase = TeamPassphrase.item.load(), !passphrase.isEmpty else {
            throw DeployError.missingTeamPassphrase
        }
        if plan == .passphraseCheck {
            do {
                let output = try await pullTeamState(
                    path: StateBackendService.passphraseCheckPath, remote: remote, passphrase: passphrase)
                if Self.holdsState(output) { return true }
            } catch EngineRunner.EngineError.nonZeroExit(let result) {
                if Self.isDecryptionFailure(result.rawLines) { return false }
            }
        }
        for tenantID in contents.tenantIDs.sorted(by: { $0.uuidString < $1.uuidString }).prefix(3)
        where !busyTenants.contains(tenantID) {
            busyTenants.insert(tenantID)
            defer { busyTenants.remove(tenantID) }
            let output: Data
            do {
                output = try await pullTeamState(
                    path: StateBackendService.statePath(tenantID: tenantID), remote: remote, passphrase: passphrase)
            } catch EngineRunner.EngineError.nonZeroExit(let result) {
                if Self.isDecryptionFailure(result.rawLines) { return false }
                continue
            }
            if Self.holdsState(output) {
                // Verified: a team space from an earlier version gets its check now.
                if !contents.hasPassphraseCheck { try? await ensurePassphraseCheck() }
                return true
            }
        }
        throw DeployError.passphraseNotVerified
    }

    enum PassphraseCheckPlan: Equatable {
        /// Open the passphrase check (then tenants' state, if it was empty).
        case passphraseCheck
        /// No check yet: open tenants' state.
        case tenantState
        /// Nothing encrypted in the team space at all.
        case nothingToCompare
    }

    nonisolated static func passphraseCheckPlan(_ contents: GitStoreService.TeamStateContents) -> PassphraseCheckPlan {
        if contents.hasPassphraseCheck { return .passphraseCheck }
        return contents.tenantIDs.isEmpty ? .nothingToCompare : .tenantState
    }

    nonisolated static func isDecryptionFailure(_ lines: [String]) -> Bool {
        lines.contains { $0.localizedCaseInsensitiveContains("decryption failed") }
    }

    /// Writes the team space's passphrase check when it has none yet (or,
    /// with `replacing`, always: a team space being created). The check is a
    /// state with nothing in it, pushed through the state backend with
    /// OpenTofu's own encryption under this Mac's team passphrase.
    func ensurePassphraseCheck(replacing: Bool = false) async throws {
        guard !isDemo else { throw DeployError.notInDemoMode }
        guard let remote = teamRemoteURL else { throw DeployError.noTeamSpace }
        guard let passphrase = TeamPassphrase.item.load(), !passphrase.isEmpty else {
            throw DeployError.missingTeamPassphrase
        }
        if !replacing, try await gitStore.teamStateContents().hasPassphraseCheck { return }
        try await withTeamStateRunner(path: StateBackendService.passphraseCheckPath, remote: remote,
                                      passphrase: passphrase) { runner in
            _ = try await runner.checkedOutput(arguments: ["state", "push", "-force", "-"],
                                               input: Self.passphraseCheckState())
        }
    }

    /// The passphrase check's content: an empty state, nothing secret in it.
    nonisolated static func passphraseCheckState(lineage: UUID = UUID()) -> Data {
        let state: [String: Any] = [
            "version": 4,
            "terraform_version": EngineInfo.openTofuVersion,
            "serial": 1,
            "lineage": lineage.uuidString.lowercased(),
            "outputs": [String: Any](),
            "resources": [Any](),
        ]
        return (try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])) ?? Data()
    }

    /// `state pull` of one state on the state branch with `passphrase`.
    private func pullTeamState(path: String, remote: String, passphrase: String) async throws -> Data {
        try await withTeamStateRunner(path: path, remote: remote, passphrase: passphrase) { runner in
            try await runner.checkedOutput(arguments: ["state", "pull"])
        }
    }

    /// An engine set up for one state on the state branch, in a temporary
    /// workspace: no tenant workspace or runner is touched.
    private func withTeamStateRunner<T>(
        path: String, remote: String, passphrase: String, _ body: (EngineRunner) async throws -> T
    ) async throws -> T {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "jamf-deployer-passphrase-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("terraform {\n  backend \"http\" {}\n}\n".utf8).write(to: folder.appending(path: "main.tf"))
        var environment = try await stateBackend.environment(statePath: path, remote: remote)
        environment["TF_ENCRYPTION"] = Self.encryptionConfiguration(passphrase: passphrase)
        let runner = EngineRunner(configuration: EngineRunner.Configuration(
            engineURL: EngineLocator.tofuURL,
            workingDirectory: folder,
            cliConfigURL: try EngineLocator.ensureCLIConfig(),
            environment: environment,
            tools: tools
        ))
        try await runner.run(arguments: ["init", "-input=false"])
        return try await body(runner)
    }

    /// Removes a tenant from the app — and, in Team Mode, from the team
    /// space, state included. Nothing in Jamf is touched. When the team
    /// space's state cannot be deleted (a teammate holds its lock, say),
    /// the tenant stays. Refused while any engine work runs or a preview is
    /// open: its workspace (the engine's folder) is deleted.
    func removeTenant(_ tenant: Tenant) async throws {
        try guardNoEngineWork()
        busyTenants.insert(tenant.id)
        removingTenants.insert(tenant.id)
        defer {
            busyTenants.remove(tenant.id)
            removingTenants.remove(tenant.id)
        }
        if isTeamMode, let remote = teamRemoteURL {
            // A tenant that never had state in the team space has none to delete.
            let withState = try? await gitStore.tenantIDsWithTeamState()
            if withState?.contains(tenant.id) ?? true {
                do {
                    try await stateBackend.deleteState(tenantID: tenant.id, remote: remote)
                } catch {
                    locks = await gitStore.stateLocks()
                    if let lock = locks[tenant.id] { throw DeployError.locked(lock) }
                    throw error
                }
            }
        }
        tenantStore.remove(tenant)
        await recordInStore("Remove tenant \(tenant.name) — \(engineerName)")
    }

    // MARK: Recording changes in the store

    /// Record changes not committed yet, and the delayed commit that takes
    /// them. Rapid edits (typing a name prefix) become one commit; engine
    /// work and syncs commit whatever is waiting before they start.
    private var pendingRecordMessages: [String] = []
    private var pendingRecordTask: Task<Void, Never>?
    /// The commit message for the next record change this service makes.
    private var nextChangeMessage: String?
    static let recordDelay: Duration = .seconds(2)
    /// The team space's passphrase check is known to exist (this launch).
    private var passphraseCheckSeen = false

    var hasPendingRecords: Bool { !pendingRecordMessages.isEmpty }

    /// A tenant record was added or changed (anywhere in the app).
    private func noteRecordChange(tenant: Tenant, kind: TenantStore.Change) {
        guard !isDemo else { return }
        let message = nextChangeMessage ?? (kind == .added ? "Add tenant \(tenant.name)" : "Update tenant \(tenant.name)")
        nextChangeMessage = nil
        if !pendingRecordMessages.contains(message) { pendingRecordMessages.append(message) }
        pendingRecordTask?.cancel()
        pendingRecordTask = Task { [weak self] in
            try? await Task.sleep(for: Self.recordDelay)
            guard !Task.isCancelled else { return }
            await self?.flushPendingRecords()
        }
    }

    /// Saves a record change this service makes, with its own commit message.
    private func saveTenant(_ tenant: Tenant, change: String) {
        nextChangeMessage = change
        tenantStore.update(tenant)
        nextChangeMessage = nil
    }

    /// The waiting changes as one commit message (nil when none wait); they
    /// count as recorded from here on.
    private func takePendingRecordMessage() -> String? {
        pendingRecordTask?.cancel()
        pendingRecordTask = nil
        guard !pendingRecordMessages.isEmpty else { return nil }
        let messages = pendingRecordMessages
        pendingRecordMessages = []
        let summary = messages.count <= 3
            ? messages.joined(separator: "; ")
            : messages.prefix(2).joined(separator: "; ") + " and \(messages.count - 2) more changes"
        return "\(summary) — \(engineerName)"
    }

    /// Commits (and in Team Mode shares) every record change still waiting.
    func flushPendingRecords() async {
        guard let message = takePendingRecordMessage() else { return }
        await recordInStore(message)
    }

    /// Commits the store and, in Team Mode, syncs it (pull, then publish)
    /// as one unit. Possible secrets stop both and open the review sheet;
    /// nothing leaves this Mac.
    private func recordInStore(_ message: String) async {
        // demo mode's store is never committed, let alone shared
        guard !isDemo else { return }
        // This commit takes every change made so far.
        _ = takePendingRecordMessage()
        do {
            if isTeamMode {
                try await gitStore.sync(savingChangesAs: message)
                tenantStore.reload()
                catalogSources.reload()
                locks = await gitStore.stateLocks()
                lastSync = .now
                syncMessage = nil
            } else {
                _ = try await gitStore.commitAll(message: message)
            }
        } catch GitStoreService.GitError.possibleSecrets(let findings) {
            storeSecretReview = StoreSecretReview(
                kind: .commitBlocked(message: message),
                findings: findings.map { .init(finding: $0, inEarlierVersion: false) })
        } catch {
            // As before: a store that cannot commit (no Git) keeps working
            // alone; in Team Mode the failed sync stops engine work.
            if isTeamMode { syncMessage = Self.describe(error) }
        }
    }

    /// Commits the store for Team settings; possible secrets open the
    /// review sheet and the error goes on to the caller.
    @discardableResult
    func commitStore(message: String) async throws -> Bool {
        guard !isDemo else { throw DeployError.notInDemoMode }
        do {
            return try await gitStore.commitAll(message: message)
        } catch GitStoreService.GitError.possibleSecrets(let findings) {
            storeSecretReview = StoreSecretReview(
                kind: .commitStopped, findings: findings.map { .init(finding: $0, inEarlierVersion: false) })
            throw GitStoreService.GitError.possibleSecrets(findings)
        }
    }

    /// Marks a finding in the review sheet as not a secret.
    func acknowledgeStoreFinding(_ finding: SecretFinding) async throws {
        try await gitStore.acknowledge(finding)
        storeSecretReview?.acknowledged.insert(finding)
    }

    /// Closes the review sheet; a stopped commit is tried again when asked.
    func closeStoreSecretReview(retry: Bool) async {
        guard let review = storeSecretReview else { return }
        storeSecretReview = nil
        if case .existingStore = review.kind {
            flags.set(true, forKey: Self.storeSecretCheckDefaultsKey)
        }
        if retry, case .commitBlocked(let message) = review.kind {
            await recordInStore(message)
        }
    }

    /// The one-time check of a store from before the secret check: its
    /// files and its history. Findings open the review sheet, which advises
    /// rotating those secrets; nothing in the history is rewritten.
    func checkExistingStoreOnce() async {
        guard !isDemo, !flags.bool(forKey: Self.storeSecretCheckDefaultsKey),
              GitStoreService.isGitAvailable,
              FileManager.default.fileExists(atPath: storeURL.appending(path: ".git").path),
              let findings = try? await gitStore.fullCheck()
        else { return }
        if findings.isEmpty {
            flags.set(true, forKey: Self.storeSecretCheckDefaultsKey)
        } else if storeSecretReview == nil {
            storeSecretReview = StoreSecretReview(kind: .existingStore, findings: findings)
        }
    }

    /// Runs an engine command, turning "state is locked" into a message
    /// naming who holds the lock.
    @discardableResult
    private func runEngine(_ runner: EngineRunner, _ arguments: [String]) async throws -> EngineRunner.RunResult {
        do {
            return try await runner.run(arguments: arguments)
        } catch EngineRunner.EngineError.nonZeroExit(let result) {
            if let lock = await lockHolding(result, runner: runner) { throw DeployError.locked(lock) }
            throw EngineRunner.EngineError.nonZeroExit(result)
        }
    }

    /// The lock that stopped a run. The state backend refuses a held lock
    /// without naming its holder, so the lock is read from the team space.
    private func lockHolding(_ result: EngineRunner.RunResult, runner: EngineRunner) async -> StateBackendService.StateLock? {
        if let lock = StateBackendService.lock(fromEngineOutput: result.rawLines) { return lock }
        // A held lock stops a run with "Error acquiring the state lock"; a
        // backend started fresh while one is held cannot read the state at
        // all ("Failed to get state").
        guard isTeamMode,
              result.rawLines.contains(where: { $0.contains("Error acquiring the state lock") || $0.contains("Failed to get state") }),
              let tenantID = runners.first(where: { $0.value === runner })?.key
        else { return nil }
        locks = await gitStore.stateLocks()
        return locks[tenantID]
    }

    // MARK: Workspace

    func loadCatalog() throws -> LoadedCatalog {
        try catalogSources.loadMerged()
    }

    /// The catalog as this tenant sees it: git sources resolve at the
    /// tenant's pinned tags.
    /// Selections whose catalog source was removed still deploy — from the
    /// merged catalog, at the default tag of whichever source now provides
    /// the block — but never see that source's releases. When a source with
    /// the block exists (typically the same catalog added again), the
    /// selection moves to it. What deploys does not change; the removed
    /// source's pin is dropped.
    @discardableResult
    func reattachOrphanedSelections(of tenant: Tenant) -> Tenant {
        let known = Set(catalogSources.customSources.map(\.id.uuidString))
        let isOrphan: (BlockSelection) -> Bool = { $0.sourceID != "official" && !known.contains($0.sourceID) }
        guard tenant.blockSelections.contains(where: isOrphan) else { return tenant }
        // The source the merged catalog resolves the block from — the one
        // the selection already deploys from.
        guard let merged = try? loadCatalog(for: tenant) else { return tenant }
        var updated = tenant
        var removed: Set<String> = []
        for index in updated.blockSelections.indices where isOrphan(updated.blockSelections[index]) {
            let blockID = updated.blockSelections[index].blockID
            guard merged.block(id: blockID) != nil else { continue }
            let target = merged.sourceIDByBlockID[blockID] ?? "official"
            removed.insert(updated.blockSelections[index].sourceID)
            updated.blockSelections[index].sourceID = target
            updated.blockSelections[index].sourceTag = nil
        }
        for sourceID in removed where !updated.blockSelections.contains(where: { $0.sourceID == sourceID }) {
            updated.catalogPins.removeValue(forKey: sourceID)
        }
        guard updated != tenant else { return tenant }
        Self.trace("Reattached \(removed.count) removed catalog source(s) for \(tenant.name)")
        saveTenant(updated, change: "Reattach removed catalog sources for \(tenant.name)")
        return updated
    }

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
    static let decisionsLog = Logger(subsystem: "be.jordythery.jamf-deployer", category: "decisions")

    /// Release-check and deploy-retry decisions, to Console; Debug builds
    /// also append them to a file so test runs can be read back without log
    /// access.
    static func trace(_ message: String) {
        // engine error summaries can quote a server's answer
        let message = EngineOutputCleaner.cleaned(message)
        decisionsLog.info("\(message, privacy: .public)")
        #if DEBUG
        let line = Data("\(Date().formatted(.iso8601)) \(message)\n".utf8)
        // Only this user can read it: the per-user temporary folder, mode 600.
        let descriptor = open(decisionsLogURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        _ = line.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        #endif
    }

    /// Debug builds' decisions file, in this user's own temporary folder
    /// (not the shared /tmp).
    nonisolated static var decisionsLogURL: URL {
        FileManager.default.temporaryDirectory.appending(path: "jamf-deployer-decisions.log")
    }

    func availableBaselineUpdates(for original: Tenant) async throws -> [(source: CatalogSourceStore.CustomSource, tag: String, updates: [CatalogUpdatePlanner.BlockUpdate])] {
        let tenant = reattachOrphanedSelections(of: original)
        var results: [(CatalogSourceStore.CustomSource, String, [CatalogUpdatePlanner.BlockUpdate])] = []
        let usedSourceIDs = Set(tenant.blockSelections.map(\.sourceID))
        Self.trace("Release check for \(tenant.name): sources in use \(usedSourceIDs.sorted()), git sources \(self.catalogSources.customSources.filter { $0.kind == .gitRepository }.map(\.id.uuidString))")
        for source in catalogSources.customSources
        where source.kind == .gitRepository && usedSourceIDs.contains(source.id.uuidString) {
            guard let gitURL = source.gitURL,
                  let latest = try await GitCatalogManager.availableTags(remote: gitURL, tools: tools).last else {
                Self.trace("\(source.name): no release tags found")
                continue
            }
            let pinned = tenant.catalogPins[source.id.uuidString] ?? source.defaultTag ?? latest
            Self.trace("\(source.name): pinned \(pinned) (tenant pin \(tenant.catalogPins[source.id.uuidString] ?? "none"), default \(source.defaultTag ?? "none")), latest \(latest)")
            guard latest != pinned else { continue }
            try await catalogSources.ensureCheckout(source: source, tag: pinned)
            try await catalogSources.ensureCheckout(source: source, tag: latest)
            let current = try catalogSources.load(source: source, tag: pinned)
            let candidate = try catalogSources.load(source: source, tag: latest)
            let selected = tenant.blockSelections
                .filter { $0.sourceID == source.id.uuidString }
                .map(\.blockID)
            let updates = CatalogUpdatePlanner.plan(current: current, candidate: candidate, selectedBlockIDs: selected)
            Self.trace("\(source.name): \(updates.count) block update(s) for \(selected)")
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
        var updated = tenantStore.tenant(id: tenant.id) ?? tenant
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
        saveTenant(updated, change: "Update \(updated.name) to \(source.name) \(tag)")
    }

    static func applyArguments(for tenant: Tenant, planFile: String) -> [String] {
        ["apply", "-input=false", "-json", parallelism(for: tenant), planFile]
    }

    /// An engine invocation as it reads on a command line.
    nonisolated static func commandLine(_ arguments: [String]) -> String {
        "tofu " + arguments.joined(separator: " ")
    }

    /// Changes go one at a time. The jamfpro plugin expects that, and through
    /// the Platform gateway Jamf Pro answers concurrent configuration profile
    /// creates with server errors while creating the profiles anyway — even
    /// two at a time. One at a time ran 124 creates cleanly in under a minute.
    static func parallelism(for tenant: Tenant) -> String {
        "-parallelism=1"
    }

    /// Previews and checks only read: the engine default suits the Platform
    /// gateway, the jamfpro plugin still goes one at a time.
    static func readParallelism(for tenant: Tenant) -> [String] {
        tenant.isJamfPro ? ["-parallelism=1"] : []
    }

    @discardableResult
    private func generateWorkspace(
        for tenant: Tenant,
        catalog: LoadedCatalog,
        stateBackend backend: StateBackend? = nil
    ) throws -> WorkspaceGenerator.Output {
        let selections = try WorkspaceGenerator.resolveModules(
            generatedSelections(for: tenant, catalog: catalog),
            catalog: catalog,
            connection: tenant.connection)
        let output = try WorkspaceGenerator.generate(WorkspaceInput(
            namePrefix: tenant.namePrefix,
            selections: selections,
            providerVersion: EngineInfo.jamfPlatformProviderVersion,
            protectProviderVersion: EngineInfo.jamfProtectProviderVersion,
            removals: tenant.pendingRemovals,
            connection: tenant.connection,
            jamfProProviderVersion: EngineInfo.jamfProProviderVersion,
            stateBackend: backend ?? (isTeamMode ? .http : .local)
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
        if tenant.handOverPending {
            // Hand-over releases adopted objects like blocks: the engine
            // forgets them and Jamf keeps them.
            let addresses = ((try? ExportedObjectInventory.scan(directory: adopted)) ?? []).map(\.address)
            if !addresses.isEmpty {
                let blocks = addresses.sorted().map { address in
                    "removed {\n  from = \(address)\n\n  lifecycle {\n    destroy = false\n  }\n}\n"
                }
                try Data(blocks.joined(separator: "\n").utf8)
                    .write(to: generated.appending(path: "adopted-handover_removed.tf"))
            }
        } else if fileManager.fileExists(atPath: adopted.path) {
            let selectedModules = Set(selections.map { "module.\(WorkspaceGenerator.sanitized($0.block.id))" })
            for file in (try? fileManager.contentsOfDirectory(at: adopted, includingPropertiesForKeys: nil)) ?? [] {
                if file.lastPathComponent == Self.recoveredImportsFile {
                    // Recovered creates of blocks no longer selected have
                    // nothing left to import into.
                    let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                    let kept = ExportedObjectInventory.topLevelBlocks(in: text).filter { block in
                        guard let to = block.firstMatch(of: /\bto\s*=\s*(module\.[A-Za-z0-9_-]+)/) else { return true }
                        return selectedModules.contains(String(to.1))
                    }
                    if !kept.isEmpty {
                        try Data((kept.joined(separator: "\n\n") + "\n").utf8)
                            .write(to: generated.appending(path: "adopted-\(file.lastPathComponent)"))
                    }
                } else if file.pathExtension == "tf", !file.lastPathComponent.hasSuffix("versions.tf") {
                    // versions.tf would duplicate the workspace's own provider
                    // requirements and fail init.
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
        writeTerminalScript(
            for: tenant, catalog: catalog, output: output,
            teamMode: (backend ?? (isTeamMode ? .http : .local)) == .http)
        return output
    }

    /// `plan.sh` beside the generated configuration: the preview's plan, to
    /// run yourself in Terminal. Plain values are written in; secrets are
    /// Keychain references the script reads when it runs.
    private func writeTerminalScript(
        for tenant: Tenant, catalog: LoadedCatalog, output: WorkspaceGenerator.Output, teamMode: Bool
    ) {
        let secrets = TenantSecrets(tenantID: tenant.id)
        func ref(_ item: KeychainItem) -> TerminalScript.KeychainRef {
            TerminalScript.KeychainRef(service: item.service, account: item.account)
        }
        var environment: [String: String] = [:]
        var secretRefs: [String: TerminalScript.KeychainRef] = [:]
        if tenant.isJamfPro {
            environment["JAMFPRO_INSTANCE_FQDN"] = JamfAPIConfiguration.instanceURL(tenant.jamfProURL ?? "")?.absoluteString ?? ""
            environment["JAMFPRO_AUTH_PROVIDER"] = "direct"
            if tenant.jamfProAuth == .userAccount {
                environment["JAMFPRO_AUTH_METHOD"] = "basic"
                environment["JAMFPRO_BASIC_USERNAME"] = tenant.engineerClientID
                secretRefs["JAMFPRO_BASIC_PASSWORD"] = ref(secrets.platformClientSecret)
            } else {
                environment["JAMFPRO_AUTH_METHOD"] = "oauth2"
                environment["JAMFPRO_CLIENT_ID"] = tenant.engineerClientID
                secretRefs["JAMFPRO_CLIENT_SECRET"] = ref(secrets.platformClientSecret)
            }
        } else {
            environment["JAMFPLATFORM_BASE_URL"] = tenant.region.gatewayURL.absoluteString
            environment["JAMFPLATFORM_CLIENT_ID"] = tenant.engineerClientID
            environment[tenant.apiScope == .environment ? "JAMFPLATFORM_ENVIRONMENT_ID" : "JAMFPLATFORM_TENANT_ID"] = tenant.scopeID
            secretRefs["JAMFPLATFORM_CLIENT_SECRET"] = ref(secrets.platformClientSecret)
        }
        let needsProtect = effectiveSelections(for: tenant, catalog: catalog).contains {
            catalog.block(id: $0.blockID)?.products.contains("jamf-protect") == true
        }
        if needsProtect, let protectURL = tenant.protectURL, let protectClientID = tenant.protectClientID {
            environment["JAMFPROTECT_URL"] = protectURL
            environment["JAMFPROTECT_CLIENT_ID"] = protectClientID
            secretRefs["JAMFPROTECT_CLIENT_SECRET"] = ref(secrets.protectClientSecret)
        }
        for (reference, variableName) in output.secretVariableNames {
            let parts = reference.split(separator: "/").map(String.init)
            guard parts.count == 2 else { continue }
            secretRefs["TF_VAR_\(variableName)"] = ref(secrets.blockSetting(blockID: parts[0], key: parts[1]))
        }
        for name in adoptedSensitiveVariables(for: tenant) {
            secretRefs["TF_VAR_\(name)"] = ref(secrets.adoptedVariable(name))
        }
        guard let cliConfig = try? EngineLocator.ensureCLIConfig() else { return }
        let script = TerminalScript.render(TerminalScript.Input(
            enginePath: EngineLocator.tofuURL.path,
            cliConfigPath: cliConfig.path,
            environment: environment,
            secrets: secretRefs,
            statePassphrase: ref(secrets.statePassphrase),
            planArguments: Self.readParallelism(for: tenant),
            isTeamMode: teamMode))
        let url = generatedURL(for: tenant).appending(path: TerminalScript.fileName)
        try? Data(script.utf8).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
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
        for name in adoptedSensitiveVariables(for: tenant) {
            guard let value = TenantSecrets(tenantID: tenant.id).adoptedVariable(name).load() else {
                throw DeployError.missingAdoptedSecret(name)
            }
            environment["TF_VAR_\(name)"] = value
        }
        return environment
    }

    /// The adopted configuration's sensitive variables: declared in the
    /// tenant record, their values in this Mac's Keychain. Not used while
    /// a hand-over releases the adopted objects.
    static let adoptedSensitiveVariablesFile = "adopted_sensitive_variables.tf"

    func adoptedSensitiveVariables(for tenant: Tenant) -> [String] {
        guard !tenant.handOverPending else { return [] }
        return ExportedObjectInventory.declaredVariableNames(
            in: adoptedURL(for: tenant).appending(path: Self.adoptedSensitiveVariablesFile))
    }

    /// The tenant's selections plus every always-on block the catalog has
    /// for its connection and it has not selected, with the block's
    /// defaults. Nothing is saved: an always-on block is part of every
    /// baseline, so a tenant without a record of it still deploys it. A
    /// hand-over releases everything, always-on blocks included.
    func effectiveSelections(for tenant: Tenant, catalog: LoadedCatalog) -> [BlockSelection] {
        guard !tenant.handOverPending, !tenant.isHandedOver else { return tenant.blockSelections }
        var selections = tenant.blockSelections
        let selectedIDs = Set(selections.map(\.blockID))
        for block in catalog.blocks
        where block.alwaysOn && !selectedIDs.contains(block.id) && catalog.supports(blockID: block.id, connection: tenant.connection) {
            selections.append(.defaults(for: block, catalog: catalog, selectedIDs: selectedIDs))
        }
        return selections
    }

    private func generatedSelections(for tenant: Tenant, catalog: LoadedCatalog) throws -> [GeneratedSelection] {
        try effectiveSelections(for: tenant, catalog: catalog).map { selection in
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
                        folderURL: sourceCatalog.blockFolderURL(id: selection.blockID),
                        existingScopeID: selection.existingScope?.id,
                        existingCategoryID: selection.existingCategory?.id,
                        providedScope: selection.providedScope,
                        providedCategory: selection.providedCategory
                    )
                }
            }
            guard let block = catalog.block(id: selection.blockID) else {
                throw DeployError.blockMissingFromCatalog(selection.blockID)
            }
            return GeneratedSelection(
                block: block, settings: selection.settings,
                existingScopeID: selection.existingScope?.id,
                existingCategoryID: selection.existingCategory?.id,
                providedScope: selection.providedScope,
                providedCategory: selection.providedCategory)
        }
    }

    private func generatedURL(for tenant: Tenant) -> URL {
        tenantStore.workspaceURL(for: tenant).appending(path: "generated")
    }

    /// Import blocks for objects Jamf created despite an error.
    static let recoveredImportsFile = "recovered_import.tf"

    /// Hand-configured objects adopted into the tenant record live here as
    /// root-level configuration (plus one-shot import blocks until applied).
    func adoptedURL(for tenant: Tenant) -> URL {
        tenantStore.workspaceURL(for: tenant).appending(path: "adopted")
    }

    /// Whether the app manages anything in the tenant: deployed blocks, or
    /// adopted objects once the tenant has been deployed. A tenant brought
    /// in entirely through Adopt has no blocks but is fully managed.
    func isManaged(_ tenant: Tenant) -> Bool {
        !tenant.deployedBlockVersions.isEmpty || (tenant.lastDeploy != nil && hasAdoptedConfig(for: tenant))
    }

    /// Whether a rollout can include the tenant: it has a baseline, adopted or
    /// staged objects, and is not being handed over.
    func canRollOut(_ tenant: Tenant) -> Bool {
        guard !tenant.isHandedOver, !tenant.handOverPending else { return false }
        return isManaged(tenant) || !tenant.blockSelections.isEmpty || hasAdoptedConfig(for: tenant)
    }

    /// Whether the tenant has adopted objects.
    func hasAdoptedConfig(for tenant: Tenant) -> Bool {
        ExportedObjectInventory.containsResources(directory: adoptedURL(for: tenant))
    }

    /// Adopted objects by plain-language type, most common first.
    func adoptedSummary(for tenant: Tenant) -> [(label: String, count: Int)] {
        let objects = (try? ExportedObjectInventory.scan(directory: adoptedURL(for: tenant))) ?? []
        let counts = Dictionary(grouping: objects, by: \.resourceType).mapValues(\.count)
        return counts
            .map { (label: BlockCapture.objectLabel(for: $0.key), count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.label < $1.label }
    }

    private func historyURL(for tenant: Tenant) -> URL {
        tenantStore.workspaceURL(for: tenant).appending(path: "history")
    }

    // MARK: State passphrase and recovery escrow

    /// Returns the state passphrase, creating one for a tenant that has no
    /// record yet. A missing passphrase for an existing record is an error:
    /// a new one could never decrypt it.
    func statePassphrase(for tenant: Tenant) throws -> String {
        if isTeamMode {
            guard let team = TeamPassphrase.item.load(), !team.isEmpty else { throw DeployError.missingTeamPassphrase }
            return team
        }
        return try ownStatePassphrase(for: tenant)
    }

    /// The tenant's own passphrase, used outside Team Mode.
    private func ownStatePassphrase(for tenant: Tenant) throws -> String {
        let item = TenantSecrets(tenantID: tenant.id).statePassphrase
        if let existing = item.load() {
            return existing
        }
        let stateURL = tenantStore.workspaceURL(for: tenant).appending(path: "state/terraform.tfstate")
        guard !FileManager.default.fileExists(atPath: stateURL.path) else {
            throw DeployError.missingStatePassphrase
        }
        let fresh = Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        guard item.save(fresh) else { throw DeployError.missingStatePassphrase }
        return fresh
    }

    /// The user must save a recovery copy of the passphrase before the first
    /// deploy — losing it makes the tenant record unreadable.
    func needsRecoveryEscrow(for tenant: Tenant) -> Bool {
        // nothing is deployed in demo mode, so there's no state to recover
        !isDemo && !flags.bool(forKey: recoveryEscrowKey(tenant))
    }

    func markRecoverySaved(for tenant: Tenant) {
        guard !isDemo else { return }
        flags.set(true, forKey: recoveryEscrowKey(tenant))
    }

    private func recoveryEscrowKey(_ tenant: Tenant) -> String {
        "recoverySaved.\(tenant.id.uuidString)"
    }

    func recoverySheetText(for tenant: Tenant) -> String {
        if isTeamMode {
            return """
            Jamf Deployer — Team Space Recovery Sheet
            =========================================

            Team space: \(teamRemoteURL ?? "")
            Tenant:     \(tenant.name)
            Identifier: \(tenant.id.uuidString)
            Created:    \(Date.now.formatted(.iso8601))

            Team passphrase:

                \(TeamPassphrase.item.load() ?? "(not available on this Mac)")

            The team passphrase encrypts the deployment state of every tenant
            in this team space, stored on the \(StateBackendService.stateBranch)
            branch of the team repository. Keep this sheet in your team’s
            password manager. Without the passphrase the state can’t be read
            and the tenants would have to be adopted again.
            """
        }
        return """
        Jamf Deployer — Recovery Sheet
        ===============================

        Tenant:     \(tenant.name)
        Identifier: \(tenant.id.uuidString)
        Created:    \(Date.now.formatted(.iso8601))

        Recovery passphrase:

            \((try? statePassphrase(for: tenant)) ?? "(not available on this Mac)")

        This passphrase encrypts the tenant’s deployment state (the app’s
        memory of what it manages in this tenant). Keep this sheet in a
        password manager or another safe place. Without it, a reinstalled app
        can’t read the state and the tenant would have to be adopted again.
        """
    }

    // MARK: Engine plumbing

    /// A value for a quoted HCL string: a typed passphrase may contain
    /// quotes, backslashes or interpolation markers.
    nonisolated static func hclEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "${", with: "$${")
            .replacingOccurrences(of: "%{", with: "%%{")
    }

    /// Encrypts the deployment state and saved plans with the passphrase.
    private func encryptionConfiguration(for tenant: Tenant, passphrase: String? = nil) throws -> String {
        Self.encryptionConfiguration(passphrase: try passphrase ?? statePassphrase(for: tenant))
    }

    nonisolated static func encryptionConfiguration(passphrase: String) -> String {
        """
        key_provider "pbkdf2" "passphrase" {
          passphrase = "\(hclEscaped(passphrase))"
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
    }

    /// The community jamfpro plugin reads its instance and credentials
    /// from JAMFPRO_* variables; nothing is written to the workspace.
    private func jamfProEnvironment(for tenant: Tenant, secret: String) throws -> [String: String] {
        guard let url = JamfAPIConfiguration.instanceURL(tenant.jamfProURL ?? "") else {
            throw DeployError.missingCredentials(usesPassword: tenant.usesPassword)
        }
        var environment: [String: String] = [
            "JAMFPRO_INSTANCE_FQDN": url.absoluteString,
            "JAMFPRO_AUTH_PROVIDER": "direct",
        ]
        switch tenant.jamfProAuth ?? .apiClient {
        case .apiClient:
            environment["JAMFPRO_AUTH_METHOD"] = "oauth2"
            environment["JAMFPRO_CLIENT_ID"] = tenant.engineerClientID
            environment["JAMFPRO_CLIENT_SECRET"] = secret
        case .userAccount:
            environment["JAMFPRO_AUTH_METHOD"] = "basic"
            environment["JAMFPRO_BASIC_USERNAME"] = tenant.engineerClientID
            environment["JAMFPRO_BASIC_PASSWORD"] = secret
        }
        try environment.merge(protectEnvironment(for: tenant)) { $1 }
        environment["TF_ENCRYPTION"] = try encryptionConfiguration(for: tenant)
        return environment
    }

    /// JAMFPROTECT_* for baselines with Jamf Protect blocks; empty otherwise.
    private func protectEnvironment(for tenant: Tenant) throws -> [String: String] {
        let needsProtect = (try? loadCatalog()).map { catalog in
            effectiveSelections(for: tenant, catalog: catalog).contains { selection in
                catalog.block(id: selection.blockID)?.products.contains("jamf-protect") == true
            }
        } ?? false
        guard needsProtect else { return [:] }
        guard let protectURL = tenant.protectURL,
              let protectClientID = tenant.protectClientID,
              let protectSecret = TenantSecrets(tenantID: tenant.id).protectClientSecret.load()
        else {
            throw DeployError.missingProtectConnection
        }
        return [
            "JAMFPROTECT_URL": protectURL,
            "JAMFPROTECT_CLIENT_ID": protectClientID,
            "JAMFPROTECT_CLIENT_SECRET": protectSecret,
        ]
    }

    private func environment(for tenant: Tenant) throws -> [String: String] {
        guard let secret = TenantSecrets(tenantID: tenant.id).platformClientSecret.load() else {
            throw DeployError.missingCredentials(usesPassword: tenant.usesPassword)
        }
        if tenant.isJamfPro {
            return try jamfProEnvironment(for: tenant, secret: secret)
        }
        var environment: [String: String] = [
            "JAMFPLATFORM_BASE_URL": tenant.region.gatewayURL.absoluteString,
            "JAMFPLATFORM_CLIENT_ID": tenant.engineerClientID,
            "JAMFPLATFORM_CLIENT_SECRET": secret,
        ]
        switch tenant.apiScope {
        case .environment:
            environment["JAMFPLATFORM_ENVIRONMENT_ID"] = tenant.scopeID
        case .tenant:
            environment["JAMFPLATFORM_TENANT_ID"] = tenant.scopeID
        }
        try environment.merge(protectEnvironment(for: tenant)) { $1 }
        environment["TF_ENCRYPTION"] = try encryptionConfiguration(for: tenant)
        return environment
    }

    /// The engine for one tenant. In Team Mode its state goes through the
    /// state backend; `backend` and `passphrase` override that for moving
    /// state between the two.
    private func makeRunner(
        for tenant: Tenant,
        extraEnvironment: [String: String] = [:],
        stateBackend backend: StateBackend? = nil,
        passphrase: String? = nil
    ) async throws -> EngineRunner {
        var environment = try environment(for: tenant).merging(extraEnvironment) { _, new in new }
        if let passphrase {
            environment["TF_ENCRYPTION"] = try encryptionConfiguration(for: tenant, passphrase: passphrase)
        }
        if backend ?? (isTeamMode ? .http : .local) == .http {
            guard let remote = teamRemoteURL else { throw DeployError.noTeamSpace }
            try environment.merge(await stateBackend.environment(tenantID: tenant.id, remote: remote)) { $1 }
        }
        let runner = EngineRunner(configuration: EngineRunner.Configuration(
            engineURL: EngineLocator.tofuURL,
            workingDirectory: generatedURL(for: tenant),
            cliConfigURL: try EngineLocator.ensureCLIConfig(),
            environment: environment,
            tools: tools
        ))
        runners[tenant.id] = runner
        return runner
    }

    func cancel(tenant: Tenant) {
        let runner = runners[tenant.id]
        Task {
            await runner?.cancel()
        }
    }

    // MARK: Preview

    func preview(tenant original: Tenant) async throws -> PreviewSession {
        guard !busyTenants.contains(original.id) else { throw DeployError.tenantBusy }
        guard !(tenantStore.tenant(id: original.id) ?? original).isHandedOver else { throw DeployError.handedOver }
        busyTenants.insert(original.id)
        phases[original.id] = .generating
        progressLines[original.id] = []
        defer {
            phases[original.id] = nil
            busyTenants.remove(original.id)
        }

        if isDemo {
            let session = try demoPreview(of: tenantStore.tenant(id: original.id) ?? original)
            try Task.checkCancellation()
            activePreviewTenants.insert(original.id)
            return session
        }

        // Preview stops when the team sync failed.
        try await syncBeforeEngineWork()
        // Read after the pull: a teammate may have changed the baseline.
        let tenant = reattachOrphanedSelections(of: tenantStore.tenant(id: original.id) ?? original)
        guard !tenant.isHandedOver else { throw DeployError.handedOver }

        try await ensureCatalogCheckouts(for: tenant)
        let catalog = try loadCatalog(for: tenant)
        let output = try generateWorkspace(for: tenant, catalog: catalog)

        // Rebuilt per preview: the environment can change between runs.
        let runner = try await makeRunner(
            for: tenant,
            extraEnvironment: try secretSettingEnvironment(for: tenant, output: output)
        )

        let initArguments = ["init", "-input=false"]
        let planArguments = ["plan", "-input=false", "-out=plan.bin", "-json"] + Self.readParallelism(for: tenant)

        phases[original.id] = .initializing
        logEngine("init", tenant: tenant)
        try await runEngine(runner, initArguments)

        phases[original.id] = .planning
        logEngine("plan", tenant: tenant)
        let planRun = try await runEngine(runner, planArguments)
        let plan = try await runner.showPlan(planFileName: "plan.bin")

        var blockNames: [String: String] = ["tenant": "Adopted objects"]
        var blockVersions: [String: String] = [:]
        for resolved in (try? generatedSelections(for: tenant, catalog: catalog)) ?? [] {
            blockNames[resolved.block.id] = resolved.block.name
            blockVersions[resolved.block.id] = resolved.block.version
        }

        let diagnostics = planRun.events.compactMap(\.diagnostic)
        let summary = PreviewBuilder.build(plan: plan, diagnostics: diagnostics, blockNames: blockNames)
        // A preview whose sheet already closed must not block later checks.
        try Task.checkCancellation()
        activePreviewTenants.insert(tenant.id)
        return PreviewSession(
            planFileName: "plan.bin",
            summary: summary,
            diagnostics: diagnostics,
            blockVersions: blockVersions,
            createdAt: .now,
            engineCommands: [initArguments, planArguments].map(Self.commandLine),
            deployCommand: Self.commandLine(Self.applyArguments(for: tenant, planFile: "plan.bin")),
            workspaceURL: generatedURL(for: tenant),
            generatedFiles: PreviewSession.generatedFiles(in: generatedURL(for: tenant))
        )
    }

    /// Demo mode's preview: the fixed demo plan, read as a real one is
    /// (`PreviewBuilder`), with the block names from the catalog. Nothing is
    /// generated or run.
    private func demoPreview(of tenant: Tenant) throws -> PreviewSession {
        let catalog = try loadCatalog(for: tenant)
        var blockNames: [String: String] = ["tenant": "Adopted objects"]
        var blockVersions: [String: String] = [:]
        for selection in effectiveSelections(for: tenant, catalog: catalog) {
            if let block = catalog.block(id: selection.blockID) {
                blockNames[block.id] = block.name
                blockVersions[block.id] = block.version
            }
        }
        let (plan, diagnostics) = try DemoPlan.plan(for: tenant)
        return PreviewSession(
            planFileName: "demo",
            summary: PreviewBuilder.build(plan: plan, diagnostics: diagnostics, blockNames: blockNames),
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
        // the engine talks to Jamf itself, so demo mode stops at the plan
        guard !isDemo else { throw DeployError.notInDemoMode }
        guard !(tenantStore.tenant(id: tenant.id) ?? tenant).isHandedOver else { throw DeployError.handedOver }
        guard let runner = runners[tenant.id] else { throw DeployError.planExpired }
        guard !busyTenants.contains(tenant.id) else { throw DeployError.tenantBusy }
        busyTenants.insert(tenant.id)

        phases[tenant.id] = .applying
        progressLines[tenant.id] = []
        defer {
            phases[tenant.id] = nil
            activePreviewTenants.remove(tenant.id)
            busyTenants.remove(tenant.id)
        }

        // Record changes made since the preview are committed first; in Team
        // Mode a failed sync or an unfinished merge stops the deploy.
        await flushPendingRecords()
        if isTeamMode {
            if let syncMessage { throw DeployError.teamSyncFailed(syncMessage) }
            do {
                try await gitStore.checkHealthy()
            } catch {
                throw DeployError.teamSyncFailed(Self.describe(error))
            }
        }

        // Objects that already carry a planned create's name before the
        // apply are never adopted after a failed create: they're someone
        // else's (made by hand, say), not what this apply left behind.
        let existingBeforeApply = await existingObjects(
            forPlannedCreatesIn: try? await runner.showPlan(planFileName: session.planFileName), tenant: tenant)

        logEngine("apply", tenant: tenant)

        var result: EngineRunner.RunResult
        do {
            result = try await runner.run(
                arguments: Self.applyArguments(for: tenant, planFile: session.planFileName)
            ) { event in
                if event.type == .applyComplete || event.type == .applyErrored {
                    let message = event.message
                    Task { @MainActor in
                        self.progressLines[tenant.id]?.append(message)
                    }
                }
            }
        } catch let error as EngineRunner.EngineError {
            guard case .nonZeroExit(let partial) = error else { throw error }
            result = partial
        }

        var succeeded = result.events.count { $0.type == .applyComplete }
        var errors = result.errorDiagnostics.map(Self.describe)

        // The engine can delete an object before updating what still uses it
        // (a block renamed a group another block scopes to); Jamf refuses the
        // delete. Finish the approved plan in order instead of failing.
        let approvedPlan = try? await runner.showPlan(planFileName: session.planFileName)
        if !result.errorDiagnostics.isEmpty {
            Self.trace("Deploy \(tenant.name): \(result.errorDiagnostics.count) error(s) \(result.errorDiagnostics.map { "\($0.address ?? "-"): \($0.summary)" }); approved plan read: \(approvedPlan != nil); failed deletes: \(approvedPlan.flatMap { DeleteOrderRetry.failedDeletes(events: result.events, diagnostics: result.errorDiagnostics, approved: $0) }.map { Array($0) } ?? [])")
        }
        if let approved = approvedPlan,
           DeleteOrderRetry.failedDeletes(events: result.events, diagnostics: result.errorDiagnostics, approved: approved) != nil {
            let retry = await finishInOrder(tenant: tenant, runner: runner, approved: approved)
            succeeded += retry.succeeded
            result.rawLines += retry.rawLines
            if let retryErrors = retry.errors {
                errors = retryErrors
                result.errorDiagnostics = retry.diagnostics
                result.exitCode = retryErrors.isEmpty ? 0 : 1
            }
            activityLog.append(ActivityLogEntry(
                category: "Engine", operation: "deploy-in-order", detail: tenant.name,
                status: retry.errors?.isEmpty == true ? 200 : 500, duration: nil,
                note: retry.errors == nil ? "stopped: the remaining changes differ from the approved plan" : "\(retry.succeeded) deployed after reordering"
            ))
            if retry.errors == nil {
                errors.append(Self.retryLeftApprovedPlan)
            }
        }
        // A teammate deployed after this preview: the engine refuses the
        // saved plan, and nothing was changed.
        if errors.contains(where: { $0.contains("Saved plan is stale") }) {
            errors = ["Another engineer changed this tenant after your preview, so nothing was deployed. Preview the changes again."]
        }
        if let lock = StateBackendService.lock(fromEngineOutput: result.rawLines) {
            errors = [DeployError.locked(lock).errorDescription ?? ""]
        }
        // A non-zero exit without a reported error (a crash or a kill) is
        // still a failed deploy.
        if result.exitCode != 0 && errors.isEmpty {
            errors.append("The engine stopped unexpectedly (exit code \(result.exitCode)). The Activity Log has the details.")
        }

        // Objects Jamf created despite reporting an error become imports
        // the next preview adopts, instead of duplicate-name failures.
        var recovered = 0
        if !result.errorDiagnostics.isEmpty,
           let plan = try? await runner.showPlan(planFileName: session.planFileName) {
            recovered = await recoverCreatedObjects(
                tenant: tenant, diagnostics: result.errorDiagnostics, plan: plan, runner: runner,
                existingBeforeApply: existingBeforeApply)
        }

        // History: the approved plan, a summary, and the full event log.
        let entryID = DeployHistoryEntry.makeID()
        let entryURL = historyURL(for: tenant).appending(path: entryID)
        try? FileManager.default.createDirectory(at: entryURL, withIntermediateDirectories: true)
        // `show -json` prints sensitive values in clear text, so history (and
        // the team repository) keeps the redacted plan. The event log holds
        // what the engine printed during the run, sensitive values masked.
        if let planData = try? await runner.showPlanData(planFileName: session.planFileName),
           let redacted = PlanRedactor.redact(planData) {
            try? redacted.write(to: entryURL.appending(path: "plan.json"))
        }
        // The engine's own masking misses secrets inside a server's answer
        // (a provider error can quote what it sent), so every line is
        // cleaned before it reaches the team repository.
        let logText = EngineOutputCleaner.cleanedLog(result.rawLines)
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

        // The store copy: the tenant passed in was read when the sheet opened.
        var updated = tenantStore.tenant(id: tenant.id) ?? tenant
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
            if tenant.handOverPending && updated.blockSelections.isEmpty {
                // Hand-over completed: everything was released. The record is
                // archived and the tenant is read-only in this app.
                archiveAdoptedConfig(for: tenant)
                updated.handOverPending = false
                updated.selectionsBeforeHandOver = nil
                updated.removalsBeforeHandOver = nil
                updated.mode = .handedOver
            }
        }
        tenantStore.update(updated)

        // A team space from an earlier version gets its passphrase check
        // with the first state written to it (once per launch is enough).
        if isTeamMode && !passphraseCheckSeen && succeeded > 0 {
            passphraseCheckSeen = (try? await ensurePassphraseCheck()) != nil
        }

        // Record the outcome in the store's history, published in Team Mode.
        await recordInStore("Deploy \(tenant.name): \(entry.added) added · \(entry.changed) changed · \(entry.removed) removed · \(errors.count) failed — \(entry.engineerName)")

        return DeployOutcome(
            succeeded: succeeded,
            failed: errors.count,
            errors: errors,
            recovered: recovered,
            historyEntryID: entryID
        )
    }

    /// An engine error as the deploy result shows it.
    static func describe(_ diagnostic: EngineStreamEvent.Diagnostic) -> String {
        var text = diagnostic.summary
        if let address = diagnostic.address {
            text = "\(address): \(text)"
        }
        if let detail = diagnostic.detail {
            text += "\n\(detail)"
        }
        return text
    }

    /// Shown when the ordered retry stopped because what was left to deploy
    /// was no longer the approved plan.
    static let retryLeftApprovedPlan = "The remaining changes are no longer the ones in the preview you approved, so they weren’t deployed. Preview the changes again."

    /// Finishes a deploy whose only failures were deletes the engine ran too
    /// early: first the approved changes that are not deletes, then the
    /// deletes. Each step plans again without refreshing (the approved plan
    /// already holds what Jamf had at preview time) and applies only a plan
    /// whose changes and values stay within the approved one. `errors` is
    /// nil when a step left that plan: the original errors stand.
    private func finishInOrder(
        tenant: Tenant,
        runner: EngineRunner,
        approved: PlanFile
    ) async -> (succeeded: Int, errors: [String]?, diagnostics: [EngineStreamEvent.Diagnostic], rawLines: [String]) {
        var succeeded = 0
        var lines: [String] = []
        let targets = DeleteOrderRetry.nonDeleteTargets(approved: approved)
        var steps: [(file: String, targets: [String])] = []
        if !targets.isEmpty { steps.append(("retry-ordered.bin", targets)) }
        steps.append(("retry-deletes.bin", []))
        for step in steps {
            let planArguments = Self.retryPlanArguments(file: step.file, targets: step.targets, tenant: tenant)
            logEngine("plan", tenant: tenant)
            let planRun: EngineRunner.RunResult
            do { planRun = try await runner.run(arguments: planArguments) } catch {
                Self.trace("Ordered deploy: plan \(step.file) failed: \(error)")
                return (succeeded, nil, [], lines)
            }
            guard let plan = try? await runner.showPlan(planFileName: step.file) else {
                Self.trace("Ordered deploy: couldn’t read \(step.file)")
                return (succeeded, nil, [], lines)
            }
            Self.trace("Ordered deploy: \(step.file) changes \(DeleteOrderRetry.actionsByAddressForDisplay(plan)); outside the approved plan: \(DeleteOrderRetry.changesOutside(plan, approved: approved))")
            guard DeleteOrderRetry.staysWithin(plan, approved: approved) else { return (succeeded, nil, [], lines) }
            lines += planRun.rawLines
            guard DeleteOrderRetry.hasChanges(plan) else { continue }

            logEngine("apply", tenant: tenant)
            var applied: EngineRunner.RunResult
            do {
                applied = try await runner.run(arguments: Self.applyArguments(for: tenant, planFile: step.file)) { event in
                    if event.type == .applyComplete || event.type == .applyErrored {
                        let message = event.message
                        Task { @MainActor in self.progressLines[tenant.id]?.append(message) }
                    }
                }
            } catch EngineRunner.EngineError.nonZeroExit(let partial) {
                applied = partial
            } catch {
                return (succeeded, nil, [], lines)
            }
            succeeded += applied.events.count { $0.type == .applyComplete }
            lines += applied.rawLines
            if !applied.errorDiagnostics.isEmpty || applied.exitCode != 0 {
                let errors = applied.errorDiagnostics.map(Self.describe)
                return (succeeded, errors.isEmpty ? ["The engine stopped unexpectedly (exit code \(applied.exitCode)). The Activity Log has the details."] : errors,
                        applied.errorDiagnostics, lines)
            }
        }
        return (succeeded, [], [], lines)
    }

    /// One ordered-retry plan: no refresh, so nothing changed in Jamf since
    /// the preview enters it.
    static func retryPlanArguments(file: String, targets: [String], tenant: Tenant) -> [String] {
        ["plan", "-input=false", "-refresh=false", "-out=\(file)", "-json"]
            + targets.map { "-target=\($0)" } + readParallelism(for: tenant)
    }

    /// Looks up each failed create in Jamf by its planned name and records
    /// the ones that exist as import blocks. Returns how many were found.
    private func recoverCreatedObjects(
        tenant: Tenant,
        diagnostics: [EngineStreamEvent.Diagnostic],
        plan: PlanFile,
        runner: EngineRunner,
        existingBeforeApply: [String: Set<String>?]
    ) async -> Int {
        let candidates = Self.recoverable(
            CreateFailureRecovery.candidates(diagnostics: diagnostics, plan: plan), existingBeforeApply: existingBeforeApply)
        // A state that can't be read (lock, backend error) skips recovery:
        // without it, an object the state already tracks could be adopted
        // a second time.
        guard !candidates.isEmpty,
              TenantSecrets(tenantID: tenant.id).platformClientSecret.load() != nil,
              let stateData = try? await runner.rawCommandOutput(arguments: ["show", "-json"]),
              Self.isReadableState(stateData)
        else { return 0 }
        // Objects the state already tracks are never adopted a second time.
        let managed = CreateFailureRecovery.managedIDs(stateJSON: stateData)
        let client = TenantClients.shared.client(for: tenant, activityLog: activityLog)
        let fileURL = adoptedURL(for: tenant).appending(path: Self.recoveredImportsFile)
        // Keep recoveries from earlier deploys that have not been applied yet.
        var found: [String: String] = [:]
        if let existing = try? String(contentsOf: fileURL, encoding: .utf8) {
            for match in existing.matches(of: /to = (\S+)\n\s*id = "([^"]+)"/) {
                found[String(match.1)] = String(match.2)
            }
        }
        for candidate in candidates {
            guard let id = await Self.createdObjectID(
                for: candidate, client: client, excluding: managed[candidate.resourceType] ?? [],
                existedBefore: (existingBeforeApply[candidate.address] ?? nil) ?? [])
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

    /// Whether `show -json` printed a state: an object with a format version.
    nonisolated static func isReadableState(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["format_version"] != nil
    }

    /// The Jamf ID of the object a failed create left behind, looked up by
    /// its planned name; nil when there is none or it is ambiguous. Asks for
    /// JSON: the Classic API otherwise answers in XML, which the lookup
    /// can't read.
    nonisolated static func createdObjectID(
        for candidate: CreateFailureRecovery.Candidate,
        client: JamfPlatformClient,
        excluding managed: Set<String>,
        existedBefore: Set<String> = []
    ) async -> String? {
        guard let data = await lookup(candidate, client: client) else { return nil }
        return CreateFailureRecovery.objectID(in: data, for: candidate, excluding: managed, existedBefore: existedBefore)
    }

    /// The name lookup's answer for a candidate; nil when it failed.
    nonisolated static func lookup(_ candidate: CreateFailureRecovery.Candidate, client: JamfPlatformClient) async -> Data? {
        guard let (data, status) = await lookupResponse(candidate, client: client), status == 200 else { return nil }
        return data
    }

    /// The name lookup's answer and status; nil when it couldn't be made.
    private nonisolated static func lookupResponse(
        _ candidate: CreateFailureRecovery.Candidate, client: JamfPlatformClient
    ) async -> (Data, Int)? {
        guard let path = CreateFailureRecovery.lookupPath(for: candidate) else { return nil }
        return try? await client.get(
            path, query: CreateFailureRecovery.lookupQuery(for: candidate), accept: "application/json",
            privileges: lookupPrivileges(for: candidate))
    }

    /// Before an apply: the IDs of objects that already carry a planned
    /// create's name; nil when that's unknown. A by-name lookup answers 404
    /// when no object has the name, which is an empty set, not a failure.
    nonisolated static func existingIDsBeforeApply(
        _ candidate: CreateFailureRecovery.Candidate, client: JamfPlatformClient
    ) async -> Set<String>? {
        guard let (data, status) = await lookupResponse(candidate, client: client) else { return nil }
        switch status {
        case 200:
            return CreateFailureRecovery.matchingIDs(in: data, for: candidate)
        case 404:
            guard case .byName = CreateFailureRecovery.lookups[candidate.resourceType] else { return nil }
            return []
        default:
            return nil
        }
    }

    /// Before an apply: per planned create (only types recovery can look
    /// up), the IDs of objects that already have its name; nil for an
    /// address whose lookup failed, which is then never recovered.
    private func existingObjects(forPlannedCreatesIn plan: PlanFile?, tenant: Tenant) async -> [String: Set<String>?] {
        guard let plan else { return [:] }
        let creates = CreateFailureRecovery.plannedCreates(plan: plan)
        guard !creates.isEmpty, TenantSecrets(tenantID: tenant.id).platformClientSecret.load() != nil else {
            return Dictionary(uniqueKeysWithValues: creates.map { ($0.address, Set<String>?.none) })
        }
        let client = TenantClients.shared.client(for: tenant, activityLog: activityLog)
        var existing: [String: Set<String>?] = [:]
        for candidate in creates {
            existing[candidate.address] = .some(await Self.existingIDsBeforeApply(candidate, client: client))
        }
        return existing
    }

    /// The failed creates recovery may look for: those whose objects were
    /// looked up before the apply. One whose lookup failed then (or that
    /// wasn't looked up) is left alone; the next preview reports it.
    nonisolated static func recoverable(
        _ candidates: [CreateFailureRecovery.Candidate], existingBeforeApply: [String: Set<String>?]
    ) -> [CreateFailureRecovery.Candidate] {
        candidates.filter { candidate in
            guard let known = existingBeforeApply[candidate.address] else { return false }
            return known != nil
        }
    }

    /// The Jamf Pro privilege each lookup reads with, from JTKit's table.
    /// Jamf Pro lists no privilege for App Installers.
    nonisolated static func lookupPrivileges(for candidate: CreateFailureRecovery.Candidate) -> [JamfPro.Privilege] {
        guard let path = CreateFailureRecovery.lookupPath(for: candidate) else { return [] }
        if path.hasPrefix("/proclassic/policies/") { return [.readPolicies] }
        if path.hasPrefix("/proclassic/osxconfigurationprofiles/") { return [.readMacOSConfigurationProfiles] }
        if path.hasPrefix("/proclassic/patchsoftwaretitles") { return [.readPatchManagementSoftwareTitles] }
        return []
    }

    // MARK: Changes made in Jamf (drift)

    /// How many fleet drift checks run at once.
    private static let fleetCheckConcurrency = 3

    private(set) var fleetCheckProgress: (done: Int, total: Int)?

    /// Runs a refresh-only plan and stores what changed outside the app.
    /// Also refreshes the Apple token expiry shown on the dashboard.
    func checkDrift(tenant original: Tenant) async throws {
        try await checkDrift(tenant: original, syncing: true)
    }

    /// - Parameter syncing: false when the caller synced already (a fleet
    ///   check syncs once for all its tenants).
    private func checkDrift(tenant original: Tenant, syncing: Bool) async throws {
        guard isManaged(original) else { return }
        guard !(tenantStore.tenant(id: original.id) ?? original).isHandedOver else { throw DeployError.handedOver }
        guard !activePreviewTenants.contains(original.id) else {
            throw DeployError.previewInProgress
        }
        guard !busyTenants.contains(original.id) else { throw DeployError.tenantBusy }
        busyTenants.insert(original.id)
        defer { busyTenants.remove(original.id) }

        if syncing && !isDemo {
            try await syncBeforeEngineWork()
        } else if isTeamMode, let syncMessage {
            throw DeployError.teamSyncFailed(syncMessage)
        }
        // Read after the pull: a teammate may have changed the baseline.
        let tenant = tenantStore.tenant(id: original.id) ?? original
        guard !tenant.isHandedOver else { throw DeployError.handedOver }
        defer {
            let message = "Check \(tenant.name) for changes — \(engineerName)"
            Task { await self.recordInStore(message) }
        }

        let catalog: LoadedCatalog
        let plan: PlanFile
        if isDemo {
            // what a refresh-only plan would find, read from the demo server
            catalog = try loadCatalog(for: tenant)
            let client = TenantClients.shared.client(for: tenant, activityLog: activityLog)
            plan = try await DemoDrift.refreshPlan(for: tenant, client: client)
        } else {
            try await ensureCatalogCheckouts(for: tenant)
            catalog = try loadCatalog(for: tenant)
            let output = try generateWorkspace(for: tenant, catalog: catalog)
            let runner = try await makeRunner(
                for: tenant,
                extraEnvironment: try secretSettingEnvironment(for: tenant, output: output)
            )

            logEngine("check", tenant: tenant)
            try await runEngine(runner, ["init", "-input=false"])
            try await runEngine(runner, ["plan", "-refresh-only", "-input=false", "-out=drift.bin", "-json"] + Self.readParallelism(for: tenant))
            plan = try await runner.showPlan(planFileName: "drift.bin")
        }

        var blockNames: [String: String] = ["tenant": "Adopted objects"]
        for selection in effectiveSelections(for: tenant, catalog: catalog) {
            if let block = catalog.block(id: selection.blockID) {
                blockNames[block.id] = block.name
            }
        }

        // Token lookups can take a while; read the tenant afterwards so edits
        // made meanwhile are kept.
        var expiry = tenantStore.tenant(id: tenant.id) ?? tenant
        await refreshTokenExpiry(&expiry)
        var updated = tenantStore.tenant(id: tenant.id) ?? tenant
        updated.preflight = expiry.preflight
        updated.driftReport = DriftReportBuilder.build(plan: plan, blockNames: blockNames)
        updated.lastDriftCheck = .now
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

        // One sync for the whole check, before the batches: three tenants
        // pulling the same repository at once would collide.
        if !isDemo {
            do {
                try await syncBeforeEngineWork()
            } catch {
                let reason = Self.describe(error)
                for tenant in candidates { fleetCheckFailures[tenant.id] = reason }
                return
            }
        }

        // Batches of three: simple, and plenty for a fleet check.
        var remaining = candidates[...]
        while !remaining.isEmpty {
            let batch = Array(remaining.prefix(Self.fleetCheckConcurrency))
            remaining = remaining.dropFirst(Self.fleetCheckConcurrency)
            // Unstructured tasks; the engine work happens off-main inside
            // each tenant's runner, so the batch runs concurrently.
            let tasks = batch.map { tenant in
                Task {
                    do {
                        try await self.checkDrift(tenant: tenant, syncing: false)
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

    /// One tenant's check from the UI: a failure is recorded where the
    /// dashboard and the tenant page show it, instead of being dropped.
    func checkDriftRecordingFailure(tenant: Tenant) async {
        do {
            try await checkDrift(tenant: tenant)
            fleetCheckFailures[tenant.id] = nil
        } catch {
            fleetCheckFailures[tenant.id] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func refreshTokenExpiry(_ tenant: inout Tenant) async {
        guard TenantSecrets(tenantID: tenant.id).platformClientSecret.load() != nil else { return }
        let client = TenantClients.shared.client(for: tenant, activityLog: activityLog)
        var snapshot = tenant.preflight ?? PreflightSnapshot(date: .now, allGreen: true)
        if let expiry = try? await PreflightService.adeTokenExpiry(client: client) {
            snapshot.adeTokenExpiration = expiry
        }
        if let expiry = try? await PreflightService.vppTokenExpiry(client: client) {
            snapshot.vppTokenExpiration = expiry
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
        saveTenant(updated, change: "Keep a change found in Jamf on \(tenant.name)")
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
        // Restoring an earlier baseline cancels a prepared hand-over.
        updated.handOverPending = false
        updated.selectionsBeforeHandOver = nil
        updated.removalsBeforeHandOver = nil
        saveTenant(updated, change: "Roll back \(tenant.name) to an earlier baseline")
    }

    // MARK: Hand over

    /// Prepares hand-over: every deployed block and adopted object is
    /// marked "stop managing". Nothing changes until the user previews and
    /// deploys; on success the tenant archives. Until then it can be
    /// cancelled.
    func prepareHandOver(tenant: Tenant) {
        var updated = tenant
        updated.selectionsBeforeHandOver = tenant.blockSelections
        updated.removalsBeforeHandOver = tenant.pendingRemovals
        updated.pendingRemovals = updated.deployedBlockVersions.keys.sorted().map {
            BlockRemoval(blockID: $0, keepInJamf: true)
        }
        updated.blockSelections = []
        updated.handOverPending = true
        saveTenant(updated, change: "Prepare hand-over of \(tenant.name)")
    }

    func cancelHandOver(tenant: Tenant) {
        var updated = tenant
        updated.blockSelections = tenant.selectionsBeforeHandOver ?? tenant.blockSelections
        updated.pendingRemovals = tenant.removalsBeforeHandOver ?? []
        updated.selectionsBeforeHandOver = nil
        updated.removalsBeforeHandOver = nil
        updated.handOverPending = false
        saveTenant(updated, change: "Cancel hand-over of \(tenant.name)")
    }

    /// After a hand-over the adopted configuration is kept for reference,
    /// out of the workspace.
    private func archiveAdoptedConfig(for tenant: Tenant) {
        let fileManager = FileManager.default
        let adopted = adoptedURL(for: tenant)
        guard fileManager.fileExists(atPath: adopted.path) else { return }
        let archive = tenantStore.workspaceURL(for: tenant)
            .appending(path: "adopted-handed-over-\(DeployHistoryEntry.makeID())")
        do {
            try fileManager.moveItem(at: adopted, to: archive)
        } catch {
            activityLog.append(ActivityLogEntry(
                category: "Engine", operation: "hand over", detail: tenant.name,
                status: 500, duration: nil, note: EngineOutputCleaner.cleaned("The adopted configuration couldn’t be archived: \(error.localizedDescription)")
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
        // Team state is versioned on the state branch instead.
        guard !isTeamMode else { return }
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
        case missingCredentials(usesPassword: Bool)
        case planExpired
        case blockMissingFromCatalog(String)
        case noSnapshot
        case missingProtectConnection
        case locked(StateBackendService.StateLock)
        case missingTeamPassphrase
        case noTeamSpace
        case missingSecretSetting(block: String, setting: String)
        case missingAdoptedSecret(String)
        case previewInProgress
        case tenantBusy
        case missingStatePassphrase
        case engineWorkInProgress
        case exportStateNotMoved(String)
        case exportHasChanges(tenant: String)
        case exportNotFormatted(String)
        case remoteHasCredentials
        case teamSyncFailed(String)
        case notInDemoMode
        case handedOver
        case passphraseNotVerified

        var errorDescription: String? {
            switch self {
            case .missingCredentials(let usesPassword):
                JamfAPIError.missingSecret(usesPassword: usesPassword)
            case .planExpired:
                "This preview is no longer valid. Run Preview Changes again before deploying."
            case .blockMissingFromCatalog(let id):
                "The building block “\(id)” is selected on this tenant, but it isn’t in any catalog this Mac follows. Add the catalog it comes from (Building Blocks library), or remove it from the baseline."
            case .noSnapshot:
                "This history entry has no baseline snapshot, so it can’t be rolled back to."
            case .missingProtectConnection:
                "This baseline includes Jamf Protect blocks, but the tenant has no Protect connection. Add the Protect console URL and API client in the Day 0 Setup tab first."
            case .locked(let lock):
                "This tenant is being \(lock.activity) by \(lock.engineer)\(lock.host.isEmpty ? "" : " on \(lock.host)")\(lock.created.map { " since \($0.formatted(date: .omitted, time: .shortened))" } ?? ""). Try again when they finish; if their Mac stopped mid-run, use Force Unlock… on the tenant page."
            case .missingTeamPassphrase:
                "This Mac doesn’t have the team passphrase. Enter it under Settings › Team."
            case .noTeamSpace:
                "Team Mode is on, but this Mac has no team space connected. Check Settings › Team."
            case .missingSecretSetting(let block, let setting):
                "The “\(block)” block needs its “\(setting)” secret on this Mac. Enter it in the block’s settings — secrets stay in each engineer’s Keychain."
            case .missingAdoptedSecret(let name):
                "The adopted configuration needs its sensitive value “\(name)”, which is kept in the Keychain of the Mac that adopted it. Adopt the object again on this Mac to store the value here."
            case .previewInProgress:
                "A preview is open for this tenant. Finish or close it before checking for changes."
            case .missingStatePassphrase:
                "This tenant’s deployment state is encrypted with a passphrase this Mac doesn’t have. Enter the passphrase from the tenant’s recovery sheet with Update Client Secret… in the tenant’s Connection section."
            case .exportStateNotMoved(let detail):
                "The tenants’ state couldn’t be moved to the repository: \(detail) Nothing was published to main, and the tenants are still managed in this app. Delete the repository’s terraform-state branch (or the repository), then export again to an empty folder."
            case .exportHasChanges(let tenant):
                "\(tenant) has changes that aren’t deployed, or changes made in Jamf. Preview and deploy them, or check for changes, so the repository starts with nothing to apply."
            case .exportNotFormatted(let detail):
                "The exported configuration couldn’t be formatted: \(detail.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))"
            case .remoteHasCredentials:
                "The repository URL contains a user name or password. Use the plain URL; Git signs in with your own credentials (gh, a credential helper or SSH)."
            case .notInDemoMode:
                "This isn’t available in Demo Mode. Turn off Demo Mode in the Tenant menu to use it."
            case .teamSyncFailed(let detail):
                "The team space couldn’t be synced, so nothing was started: this Mac may not have the team’s latest changes. \(detail)"
            case .engineWorkInProgress:
                "A preview, check or deploy is still running, or a preview is still open. Finish or close it, then try again."
            case .handedOver:
                "This tenant was handed over: this app no longer manages it, so it can’t be previewed, checked or deployed here."
            case .passphraseNotVerified:
                "The team passphrase couldn’t be checked against the team space’s deployment state, so it wasn’t accepted. Try again in a moment."
            case .tenantBusy:
                "This tenant is already being previewed, checked or deployed. Try again when that finishes."
            }
        }
    }
}
