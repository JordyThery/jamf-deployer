import Foundation
import DeployerKit
import JamfDeployerCore
import os

/// Loads and saves tenants from
/// `~/Library/Application Support/Jamf Deployer/store/tenants/<id>/`.
/// Each tenant folder is a full workspace: tenant.json plus its generated
/// configuration, encrypted state, adopted objects and history.
@Observable
final class TenantStore {
    private(set) var tenants: [Tenant] = []
    private let rootURL: URL
    private let logger = Logger(subsystem: "be.jordythery.jamf-deployer", category: "TenantStore")

    /// The default store under Application Support; injectable for tests.
    init(rootURL: URL? = nil) {
        self.rootURL = rootURL ?? GitStoreService.storeURL.appending(path: "tenants")
        load()
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
                loaded.append(try JSONFile.load(Tenant.self, from: file))
            } catch {
                logger.error("Could not read \(file.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        tenants = loaded.sorted { $0.createdAt < $1.createdAt }
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
