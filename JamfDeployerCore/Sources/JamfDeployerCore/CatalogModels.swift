import Foundation

/// catalog.json at the root of a catalog source.
public nonisolated struct CatalogManifest: Codable, Sendable {
    public var id: String
    public var name: String
    public var schemaVersion: Int
}

/// One setting a block exposes (block.json `settings`). This is the source
/// of truth for the settings form; variables.tf mirrors it for the engine
/// (a catalog linter keeps them in sync in CI).
public nonisolated struct BlockSetting: Codable, Sendable, Identifiable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case string
        case bool
        case number
        case enumeration = "enum"
        case stringList = "list"
        case secret
        /// Rendered by the App Catalog picker; stored as a JSON string.
        case appPicker
    }

    public var key: String
    public var title: String
    public var type: Kind
    /// Default encoded as a string ("" means none).
    public var `default`: String
    public var required: Bool
    public var description: String
    public var section: String
    public var enumValues: [String]?
    public var enumLabels: [String]?

    public var id: String { key }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? key
        type = try container.decodeIfPresent(Kind.self, forKey: .type) ?? .string
        `default` = try container.decodeIfPresent(String.self, forKey: .default) ?? ""
        required = try container.decodeIfPresent(Bool.self, forKey: .required) ?? false
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        section = try container.decodeIfPresent(String.self, forKey: .section) ?? "General"
        enumValues = try container.decodeIfPresent([String].self, forKey: .enumValues)
        enumLabels = try container.decodeIfPresent([String].self, forKey: .enumLabels)
    }
}

/// Maps a drifted resource field to the block setting that controls it, so
/// "Keep this change" can adopt the console value into the baseline
/// (block.json `driftBindings`).
public nonisolated struct DriftBinding: Codable, Sendable, Equatable {
    public var resourceType: String
    public var fieldPath: String
    public var settingKey: String
}

/// How a block is scoped (block.json `scope`).
public nonisolated struct BlockScope: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// The block has no device scope (e.g. foundation, enrollment).
        case none
        /// Scoped via a numeric Jamf Pro group ID (policies, profiles).
        case jamfProGroup
        /// Scoped via a Platform group UUID (Blueprints, benchmarks).
        case platformGroup
    }

    public var kind: Kind
    /// The module variable receiving the group reference.
    public var variable: String?
    /// Default scope choice: a foundation group key (pilot, all_macs, …).
    public var `default`: String?
    /// Some Jamf objects (App Installers) only accept smart groups — the
    /// static Pilot group is not offered for these blocks.
    public var smartOnly: Bool

    public init(kind: Kind, variable: String?, default defaultScope: String?, smartOnly: Bool = false) {
        self.kind = kind
        self.variable = variable
        self.default = defaultScope
        self.smartOnly = smartOnly
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .none
        variable = try container.decodeIfPresent(String.self, forKey: .variable)
        `default` = try container.decodeIfPresent(String.self, forKey: .default)
        smartOnly = try container.decodeIfPresent(Bool.self, forKey: .smartOnly) ?? false
    }
}

/// block.json — everything the app needs to present and wire a block.
public nonisolated struct BlockMetadata: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var summary: String
    public var category: String
    public var version: String
    public var requires: [String]
    public var conflicts: [String]
    public var products: [String]
    public var minJamfProVersion: String?
    public var permissions: [String]
    public var risk: String
    public var alwaysOn: Bool
    public var scope: BlockScope
    public var settings: [BlockSetting]
    public var objectsCreated: [String]
    public var docsURL: String?
    /// Whether the block takes a category_id wired from the foundation
    /// category matching its catalog category.
    public var acceptsCategory: Bool
    /// Captured blocks start as "needsReview" until a curator marks them
    /// reviewed; nil for authored blocks.
    public var reviewStatus: String?
    /// Field-to-setting mappings for "Keep this change".
    public var driftBindings: [DriftBinding]
    /// Scope ID of the tenant a captured block was exported from; nil for
    /// authored blocks.
    public var capturedFromTenant: String?
    /// Object names this block references per dependency type ("script",
    /// "category", "package", "device_group") — satisfied by blocks whose
    /// `provides` covers them.
    public var needs: [String: [String]]
    /// Object names this block creates per dependency type.
    public var provides: [String: [String]]
    /// Category used when the block providing it is selected, as
    /// "<blockID>/<category name>".
    public var defaultCategory: String?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        category = try container.decodeIfPresent(String.self, forKey: .category) ?? "Other"
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? "0.0.0"
        requires = try container.decodeIfPresent([String].self, forKey: .requires) ?? []
        conflicts = try container.decodeIfPresent([String].self, forKey: .conflicts) ?? []
        products = try container.decodeIfPresent([String].self, forKey: .products) ?? []
        minJamfProVersion = try container.decodeIfPresent(String.self, forKey: .minJamfProVersion)
        permissions = try container.decodeIfPresent([String].self, forKey: .permissions) ?? []
        risk = try container.decodeIfPresent(String.self, forKey: .risk) ?? "medium"
        alwaysOn = try container.decodeIfPresent(Bool.self, forKey: .alwaysOn) ?? false
        scope = try container.decodeIfPresent(BlockScope.self, forKey: .scope)
            ?? BlockScope(kind: .none, variable: nil, default: nil)
        settings = try container.decodeIfPresent([BlockSetting].self, forKey: .settings) ?? []
        objectsCreated = try container.decodeIfPresent([String].self, forKey: .objectsCreated) ?? []
        docsURL = try container.decodeIfPresent(String.self, forKey: .docsURL)
        acceptsCategory = try container.decodeIfPresent(Bool.self, forKey: .acceptsCategory) ?? false
        reviewStatus = try container.decodeIfPresent(String.self, forKey: .reviewStatus)
        driftBindings = try container.decodeIfPresent([DriftBinding].self, forKey: .driftBindings) ?? []
        capturedFromTenant = try container.decodeIfPresent(String.self, forKey: .capturedFromTenant)
        needs = try container.decodeIfPresent([String: [String]].self, forKey: .needs) ?? [:]
        provides = try container.decodeIfPresent([String: [String]].self, forKey: .provides) ?? [:]
        defaultCategory = try container.decodeIfPresent(String.self, forKey: .defaultCategory)
    }

    /// The setting controlling a drifted field, when one is bound.
    public func settingKey(forResourceType resourceType: String, fieldPath: String) -> String? {
        driftBindings.first {
            $0.resourceType == resourceType && $0.fieldPath == fieldPath
        }?.settingKey
    }

    public var needsReview: Bool {
        reviewStatus == "needsReview"
    }

    /// The provenance tag written into every object description.
    public var managedByTag: String {
        "Managed by Jamf Deployer · \(id)@\(version)"
    }
}

/// A group or category another selected block creates, by that block's
/// ID and the object's name in its `provides`.
public nonisolated struct ProvidedObject: Codable, Sendable, Hashable {
    public var blockID: String
    public var name: String

    public init(blockID: String, name: String) {
        self.blockID = blockID
        self.name = name
    }

    /// "<blockID>/<name>", as written in block defaults and presets.
    public var reference: String { "\(blockID)/\(name)" }

    /// Parses "<blockID>/<name>"; nil for anything else (legacy Foundation
    /// keys have no slash).
    public init?(reference: String) {
        guard let slash = reference.firstIndex(of: "/") else { return nil }
        let blockID = String(reference[..<slash])
        let name = String(reference[reference.index(after: slash)...])
        guard !blockID.isEmpty, !name.isEmpty else { return nil }
        self.init(blockID: blockID, name: name)
    }
}

public nonisolated extension BlockMetadata {
    /// Whether a selection of this block takes anything from Foundation.
    /// Scope and category come from Foundation unless the selection points
    /// at existing objects; a "foundation" requirement on a block with
    /// neither is a dependency in its own right.
    func wiresThroughFoundation(usesExistingScope: Bool, usesExistingCategory: Bool) -> Bool {
        let scopeViaFoundation = scope.kind != .none && !usesExistingScope
        let categoryViaFoundation = acceptsCategory && !usesExistingCategory
        let explicitRequirement = requires.contains("foundation")
            && scope.kind == .none && !acceptsCategory
        return scopeViaFoundation || categoryViaFoundation || explicitRequirement
    }
}

/// presets/<id>.json — a named list of blocks plus default settings.
public nonisolated struct Preset: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var summary: String
    public var blocks: [String]
    public var defaults: [String: [String: String]]
    /// Scope per block, where it differs from the block's own default: a
    /// group another preset block creates ("<blockID>/<name>"), or a
    /// legacy Foundation group key.
    public var scopes: [String: String]
    /// Category per block, as "<blockID>/<category name>".
    public var categories: [String: String]

    public init(
        id: String, name: String, summary: String, blocks: [String],
        defaults: [String: [String: String]] = [:], scopes: [String: String] = [:],
        categories: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.blocks = blocks
        self.defaults = defaults
        self.scopes = scopes
        self.categories = categories
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        blocks = try container.decodeIfPresent([String].self, forKey: .blocks) ?? []
        defaults = try container.decodeIfPresent([String: [String: String]].self, forKey: .defaults) ?? [:]
        scopes = try container.decodeIfPresent([String: String].self, forKey: .scopes) ?? [:]
        categories = try container.decodeIfPresent([String: String].self, forKey: .categories) ?? [:]
    }

    /// A preset capturing a baseline: its blocks in order, the non-secret
    /// settings that differ from each block's defaults, and scopes that
    /// differ from each block's default scope. Secret values never leave
    /// the Keychain.
    public static func capturing(
        name: String,
        summary: String,
        selections: [PresetSelection],
        blocks: [BlockMetadata]
    ) -> Preset {
        let byID = Dictionary(blocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let presetBlocks = Set(selections.map(\.blockID))
        var defaults: [String: [String: String]] = [:]
        var scopes: [String: String] = [:]
        var categories: [String: String] = [:]
        for selection in selections {
            guard let block = byID[selection.blockID] else { continue }
            var changed: [String: String] = [:]
            for setting in block.settings where setting.type != .secret {
                if let value = selection.settings[setting.key], value != setting.default {
                    changed[setting.key] = value
                }
            }
            if !changed.isEmpty { defaults[block.id] = changed }
            // Only references that travel: groups and categories created by
            // blocks in the preset, or Foundation keys. Existing objects are
            // tenant-specific.
            if block.scope.kind != .none {
                if let provided = selection.providedScope, presetBlocks.contains(provided.blockID) {
                    if provided.reference != block.scope.default { scopes[block.id] = provided.reference }
                } else if WorkspaceGenerator.foundationGroups.contains(selection.scope),
                          selection.scope != (block.scope.default ?? "pilot") {
                    scopes[block.id] = selection.scope
                }
            }
            if block.acceptsCategory, let provided = selection.providedCategory,
               presetBlocks.contains(provided.blockID), provided.reference != block.defaultCategory {
                categories[block.id] = provided.reference
            }
        }
        return Preset(
            id: identifier(for: name), name: name, summary: summary,
            blocks: selections.map(\.blockID), defaults: defaults, scopes: scopes, categories: categories)
    }

    public struct PresetSelection: Sendable {
        public var blockID: String
        public var settings: [String: String]
        public var scope: String
        public var providedScope: ProvidedObject?
        public var providedCategory: ProvidedObject?

        public init(
            blockID: String, settings: [String: String], scope: String,
            providedScope: ProvidedObject? = nil, providedCategory: ProvidedObject? = nil
        ) {
            self.blockID = blockID
            self.settings = settings
            self.scope = scope
            self.providedScope = providedScope
            self.providedCategory = providedCategory
        }
    }

    /// File-safe preset ID derived from its name.
    public static func identifier(for name: String) -> String {
        let lowered = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        let collapsed = lowered.split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "preset" : collapsed
    }
}

/// A fully loaded catalog source: manifest, blocks and presets, plus the
/// on-disk location the block folders are copied from at generation time.
public nonisolated struct LoadedCatalog: Sendable {
    public var manifest: CatalogManifest
    public var blocks: [BlockMetadata]
    public var presets: [Preset]
    public var rootURL: URL
    /// Per-block folder locations and source names; populated on load and
    /// preserved when catalogs from several sources merge.
    public var blockRoots: [String: URL] = [:]
    public var sourceNameByBlockID: [String: String] = [:]

    public func block(id: String) -> BlockMetadata? {
        blocks.first { $0.id == id }
    }

    public func blockFolderURL(id: String) -> URL {
        blockRoots[id] ?? rootURL.appending(path: "blocks/\(id)")
    }

    public func sourceName(for blockID: String) -> String {
        sourceNameByBlockID[blockID] ?? manifest.name
    }

    /// Merges several loaded sources; the first source wins on conflicting
    /// block IDs (the official catalog is listed first).
    public static func merge(_ catalogs: [LoadedCatalog]) -> LoadedCatalog {
        guard var merged = catalogs.first else {
            return LoadedCatalog(
                manifest: CatalogManifest(id: "empty", name: "Empty", schemaVersion: 1),
                blocks: [], presets: [], rootURL: URL(filePath: "/")
            )
        }
        for catalog in catalogs.dropFirst() {
            for block in catalog.blocks where merged.block(id: block.id) == nil {
                merged.blocks.append(block)
                merged.blockRoots[block.id] = catalog.blockFolderURL(id: block.id)
                merged.sourceNameByBlockID[block.id] = catalog.manifest.name
            }
            merged.presets.append(contentsOf: catalog.presets.filter { preset in
                !merged.presets.contains { $0.id == preset.id }
            })
        }
        merged.blocks.sort { $0.name < $1.name }
        return merged
    }

    /// Reads a catalog source from a folder (a checkout of a Git source or a
    /// local folder source).
    public static func load(from rootURL: URL) throws -> LoadedCatalog {
        let decoder = JSONDecoder()
        let manifest = try decoder.decode(
            CatalogManifest.self,
            from: Data(contentsOf: rootURL.appending(path: "catalog.json"))
        )

        let fileManager = FileManager.default
        var blocks: [BlockMetadata] = []
        let blocksURL = rootURL.appending(path: "blocks")
        for folder in (try? fileManager.contentsOfDirectory(at: blocksURL, includingPropertiesForKeys: nil)) ?? [] {
            let metadataURL = folder.appending(path: "block.json")
            guard fileManager.fileExists(atPath: metadataURL.path) else { continue }
            blocks.append(try decoder.decode(BlockMetadata.self, from: Data(contentsOf: metadataURL)))
        }

        var presets: [Preset] = []
        let presetsURL = rootURL.appending(path: "presets")
        for file in (try? fileManager.contentsOfDirectory(at: presetsURL, includingPropertiesForKeys: nil)) ?? []
        where file.pathExtension == "json" {
            presets.append(try decoder.decode(Preset.self, from: Data(contentsOf: file)))
        }

        var catalog = LoadedCatalog(
            manifest: manifest,
            blocks: blocks.sorted { $0.name < $1.name },
            presets: presets.sorted { $0.name < $1.name },
            rootURL: rootURL
        )
        for block in catalog.blocks {
            catalog.blockRoots[block.id] = rootURL.appending(path: "blocks/\(block.id)")
            catalog.sourceNameByBlockID[block.id] = manifest.name
        }
        return catalog
    }
}
