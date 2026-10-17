import Foundation
import DeployerKit
import JamfDeployerCore
import os

/// The catalog sources blocks come from: the built-in official source plus
/// any custom local folders (captured blocks land in one of these).
/// Git-tag sources join later with the team features.
@Observable
final class CatalogSourceStore {
    nonisolated struct CustomSource: Codable, Sendable, Identifiable, Equatable {
        enum Kind: String, Codable {
            case localFolder
            case gitRepository
        }

        var id: UUID
        var name: String
        /// Local folders: the folder itself. Git sources: the cache root
        /// holding one checkout per tag.
        var path: String
        var kind: Kind
        var gitURL: String?
        /// The tag new tenants start on (tenants pin their own).
        var defaultTag: String?

        init(id: UUID, name: String, path: String, kind: Kind = .localFolder, gitURL: String? = nil, defaultTag: String? = nil) {
            self.id = id
            self.name = name
            self.path = path
            self.kind = kind
            self.gitURL = gitURL
            self.defaultTag = defaultTag
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            path = try container.decode(String.self, forKey: .path)
            kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .localFolder
            gitURL = try container.decodeIfPresent(String.self, forKey: .gitURL)
            defaultTag = try container.decodeIfPresent(String.self, forKey: .defaultTag)
        }
    }

    private(set) var customSources: [CustomSource] = []
    private let logger = Logger(subsystem: "be.jordythery.jamf-deployer", category: "CatalogSources")

    private var fileURL: URL {
        GitStoreService.storeURL.appending(path: "catalog-sources.json")
    }

    init() {
        customSources = (try? JSONFile.load([CustomSource].self, from: fileURL)) ?? []
    }

    /// Re-reads sources from disk — used after a team-space sync.
    func reload() {
        customSources = (try? JSONFile.load([CustomSource].self, from: fileURL)) ?? []
    }

    /// Creates (or registers) a local folder as a catalog source, writing
    /// catalog.json if the folder is new.
    @discardableResult
    func addSource(name: String, folderURL: URL) throws -> CustomSource {
        let manifestURL = folderURL.appending(path: "catalog.json")
        if !FileManager.default.fileExists(atPath: manifestURL.path) {
            let manifest: [String: Any] = [
                "id": "custom-\(UUID().uuidString.prefix(8).lowercased())",
                "name": name,
                "schemaVersion": 1,
            ]
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
                .write(to: manifestURL)
        }
        let source = CustomSource(id: UUID(), name: name, path: folderURL.path)
        customSources.append(source)
        save()
        return source
    }

    func removeSource(_ source: CustomSource) {
        customSources.removeAll { $0.id == source.id }
        save()
    }

    /// Official catalog merged with every readable custom source; the
    /// official source wins on conflicting block IDs. Git sources resolve at
    /// the given pins (tenant `catalogPins`), falling back to their default
    /// tag.
    func loadMerged(pins: [String: String] = [:]) throws -> LoadedCatalog {
        var catalogs = [try LoadedCatalog.load(from: EngineLocator.catalogURL)]
        for source in customSources {
            do {
                catalogs.append(try load(source: source, tag: pins[source.id.uuidString]))
            } catch {
                logger.error("Catalog source \(source.name, privacy: .public) unreadable: \(error.localizedDescription, privacy: .public)")
            }
        }
        return LoadedCatalog.merge(catalogs)
    }

    /// One source at a specific tag (git) or as-is (local folder). Reads from
    /// disk only — download tags first with `ensureCheckout(source:tag:)`.
    func load(source: CustomSource, tag: String? = nil) throws -> LoadedCatalog {
        switch source.kind {
        case .localFolder:
            return try LoadedCatalog.load(from: URL(filePath: source.path))
        case .gitRepository:
            let resolved = tag ?? source.defaultTag ?? ""
            let checkout = URL(filePath: source.path).appending(path: resolved)
            guard FileManager.default.fileExists(atPath: checkout.path) else {
                throw GitCatalogManager.CatalogError.checkoutMissing(resolved)
            }
            return try LoadedCatalog.load(from: checkout)
        }
    }

    /// Downloads the checkout for a git source's tag when it isn't cached
    /// yet. No-op for local folders and already-cached tags.
    func ensureCheckout(source: CustomSource, tag: String?) async throws {
        guard source.kind == .gitRepository, let gitURL = source.gitURL else { return }
        let resolved = tag ?? source.defaultTag ?? ""
        let checkout = URL(filePath: source.path).appending(path: resolved)
        guard !FileManager.default.fileExists(atPath: checkout.path) else { return }
        try await GitCatalogManager.fetchTag(remote: gitURL, tag: resolved, into: checkout)
    }

    /// Registers a Git catalog source pinned to a starting tag.
    @discardableResult
    func addGitSource(name: String, url: String, tag: String) async throws -> CustomSource {
        let id = UUID()
        let cacheRoot = URL.applicationSupportDirectory
            .appending(path: "Jamf Deployer/catalog-cache/\(id.uuidString)")
        try await GitCatalogManager.fetchTag(remote: url, tag: tag, into: cacheRoot.appending(path: tag))
        let source = CustomSource(
            id: id,
            name: name,
            path: cacheRoot.path,
            kind: .gitRepository,
            gitURL: url,
            defaultTag: tag
        )
        customSources.append(source)
        save()
        return source
    }

    private func save() {
        try? JSONFile.save(customSources, to: fileURL)
    }
}
