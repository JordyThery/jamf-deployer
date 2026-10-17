import Foundation
import DeployerKit
import JamfDeployerCore
import os

/// Loads and saves tenants from
/// `~/Library/Application Support/Jamf Deployer/tenants/<id>/`.
/// Each tenant folder is a full workspace: tenant.json plus the generated/,
/// state/, history/ and exports/ directories later phases fill in.
@Observable
final class TenantStore {
    private(set) var tenants: [Tenant] = []
    private let rootURL: URL
    private let logger = Logger(subsystem: "be.jordythery.jamf-deployer", category: "TenantStore")

    /// The default store under Application Support; injectable for tests.
    init(rootURL: URL? = nil) {
        self.rootURL = rootURL ?? GitStoreService.storeURL.appending(path: "tenants")
        Self.migrateLegacyLayoutIfNeeded()
        load()
    }

    /// Pre-team-mode installs kept tenants directly under
    /// Application Support/Jamf Deployer/; the store is now a Git repo one
    /// level down. One-time move.
    nonisolated static func migrateLegacyLayoutIfNeeded() {
        let fileManager = FileManager.default
        let base = URL.applicationSupportDirectory.appending(path: "Jamf Deployer")
        let legacyTenants = base.appending(path: "tenants")
        let store = GitStoreService.storeURL
        guard fileManager.fileExists(atPath: legacyTenants.path),
              !fileManager.fileExists(atPath: store.appending(path: "tenants").path)
        else { return }
        try? fileManager.createDirectory(at: store, withIntermediateDirectories: true)
        try? fileManager.moveItem(at: legacyTenants, to: store.appending(path: "tenants"))
        let legacySources = base.appending(path: "catalog-sources.json")
        if fileManager.fileExists(atPath: legacySources.path) {
            try? fileManager.moveItem(at: legacySources, to: store.appending(path: "catalog-sources.json"))
        }
    }

    /// Re-reads every tenant from disk — used after a team-space sync.
    func reload() {
        load()
    }

    func tenant(id: UUID) -> Tenant? {
        tenants.first { $0.id == id }
    }

    func workspaceURL(for tenant: Tenant) -> URL {
        rootURL.appending(path: tenant.id.uuidString)
    }

    func add(_ tenant: Tenant) {
        tenants.append(tenant)
        createWorkspace(for: tenant)
        save(tenant)
    }

    func update(_ tenant: Tenant) {
        guard let index = tenants.firstIndex(where: { $0.id == tenant.id }) else { return }
        tenants[index] = tenant
        save(tenant)
    }

    /// Removes the tenant from the app. Nothing in Jamf is touched; the
    /// caller is responsible for confirming with the user first.
    func remove(_ tenant: Tenant) {
        tenants.removeAll { $0.id == tenant.id }
        TenantSecrets(tenantID: tenant.id).deleteAll()
        try? FileManager.default.removeItem(at: workspaceURL(for: tenant))
    }

    private func load() {
        let fileManager = FileManager.default
        guard let folders = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil
        ) else { return }

        var loaded: [Tenant] = []
        for folder in folders {
            let file = folder.appending(path: "tenant.json")
            guard fileManager.fileExists(atPath: file.path) else { continue }
            do {
                var tenant = try JSONFile.load(Tenant.self, from: file)
                migrateDeployedVersionsIfNeeded(&tenant, workspace: folder)
                migratePreparedHandOverIfNeeded(&tenant, workspace: folder)
                loaded.append(tenant)
            } catch {
                logger.error("Could not read \(file.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        tenants = loaded.sorted { $0.createdAt < $1.createdAt }
    }

    /// Tenants deployed before the maintain features existed have no record
    /// of which block versions they run; seed it from the newest history
    /// entry once.
    /// Earlier versions prepared a hand-over by replacing the adopted
    /// configuration with removed blocks; mark such tenants as pending so
    /// their hand-over deploy archives them.
    private func migratePreparedHandOverIfNeeded(_ tenant: inout Tenant, workspace: URL) {
        let adopted = workspace.appending(path: "adopted")
        guard tenant.mode == .managed, !tenant.handOverPending, tenant.blockSelections.isEmpty,
              FileManager.default.fileExists(atPath: adopted.appending(path: "handover_removed.tf").path),
              !ExportedObjectInventory.containsResources(directory: adopted)
        else { return }
        tenant.handOverPending = true
    }

    private func migrateDeployedVersionsIfNeeded(_ tenant: inout Tenant, workspace: URL) {
        guard tenant.deployedBlockVersions.isEmpty, tenant.lastDeploy != nil else { return }
        // A tenant managed only through Adopt legitimately has no blocks.
        if ExportedObjectInventory.containsResources(directory: workspace.appending(path: "adopted")) { return }
        let historyURL = workspace.appending(path: "history")
        let entries = ((try? FileManager.default.contentsOfDirectory(at: historyURL, includingPropertiesForKeys: nil)) ?? [])
            .compactMap { try? JSONFile.load(DeployHistoryEntry.self, from: $0.appending(path: "summary.json")) }
            .sorted { $0.date > $1.date }
        guard let latest = entries.first, !latest.blockVersions.isEmpty else { return }
        tenant.deployedBlockVersions = latest.blockVersions
        save(tenant)
    }

    private func save(_ tenant: Tenant) {
        let file = workspaceURL(for: tenant).appending(path: "tenant.json")
        do {
            try JSONFile.save(tenant, to: file)
        } catch {
            logger.error("Could not save tenant.json: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func createWorkspace(for tenant: Tenant) {
        let base = workspaceURL(for: tenant)
        for sub in ["generated", "state", "history", "exports"] {
            try? FileManager.default.createDirectory(
                at: base.appending(path: sub),
                withIntermediateDirectories: true
            )
        }
    }
}
