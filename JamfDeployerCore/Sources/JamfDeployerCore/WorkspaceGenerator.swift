import Foundation

/// One selected block with its resolved settings, ready for generation.
public nonisolated struct GeneratedSelection: Sendable {
    public var block: BlockMetadata
    /// Non-secret setting values keyed by setting key.
    public var settings: [String: String]
    /// Legacy Foundation group key this block is scoped to (pilot,
    /// all_macs, …); empty when another scope source is set.
    public var scope: String
    /// Overrides the catalog's folder for this block — used when a selection
    /// is pinned to a different catalog tag than the tenant default.
    public var folderURL: URL?
    /// An existing group in the tenant the block is scoped to, by the ID
    /// kind the block's scope variable takes. Replaces the Foundation group.
    public var existingScopeID: String?
    /// An existing category in the tenant ("-1" for none). Replaces the
    /// Foundation category.
    public var existingCategoryID: String?
    /// A group another selected block creates.
    public var providedScope: ProvidedObject?
    /// A category another selected block creates.
    public var providedCategory: ProvidedObject?

    public init(
        block: BlockMetadata,
        settings: [String: String],
        scope: String,
        folderURL: URL? = nil,
        existingScopeID: String? = nil,
        existingCategoryID: String? = nil,
        providedScope: ProvidedObject? = nil,
        providedCategory: ProvidedObject? = nil
    ) {
        self.block = block
        self.settings = settings
        self.scope = scope
        self.folderURL = folderURL
        self.existingScopeID = existingScopeID
        self.existingCategoryID = existingCategoryID
        self.providedScope = providedScope
        self.providedCategory = providedCategory
    }

    /// Whether this selection takes anything from the Foundation block.
    public var wiresThroughFoundation: Bool {
        block.wiresThroughFoundation(
            usesExistingScope: existingScopeID != nil || providedScope != nil,
            usesExistingCategory: existingCategoryID != nil || providedCategory != nil)
    }
}

/// Everything needed to regenerate a tenant workspace's configuration.
/// Regenerated from tenant.json plus the catalog on every run — the
/// generated files are never hand-edited.
public nonisolated struct WorkspaceInput: Sendable {
    public var namePrefix: String
    public var selections: [GeneratedSelection]
    public var providerVersion: String
    public var protectProviderVersion: String
    /// Blocks leaving the baseline. `keepInJamf` removals become
    /// "Stop managing": the objects leave the tenant record untouched.
    public var removals: [BlockRemoval]

    public init(
        namePrefix: String,
        selections: [GeneratedSelection],
        providerVersion: String,
        protectProviderVersion: String = "0.12.0",
        removals: [BlockRemoval] = []
    ) {
        self.namePrefix = namePrefix
        self.selections = selections
        self.providerVersion = providerVersion
        self.protectProviderVersion = protectProviderVersion
        self.removals = removals
    }
}

/// A block being removed from the baseline.
public nonisolated struct BlockRemoval: Codable, Sendable, Equatable {
    public var blockID: String
    /// true = "Stop managing" (objects stay in Jamf); false = "Remove from
    /// tenant" (objects are deleted on deploy).
    public var keepInJamf: Bool

    public init(blockID: String, keepInJamf: Bool) {
        self.blockID = blockID
        self.keepInJamf = keepInJamf
    }
}

public nonisolated enum WorkspaceGeneratorError: LocalizedError {
    case missingFoundation
    case unknownScope(block: String, scope: String)
    case scopeNotChosen(block: String)
    case missingRequiredSetting(block: String, setting: String)
    case unmetDependencies(block: String, type: String, names: [String])
    /// Two selected blocks manage the same tenant-wide setting.
    case conflictingSettings(type: String, blocks: [String])

    public var errorDescription: String? {
        switch self {
        case .missingFoundation:
            "A selected block scopes or categorizes through Foundation, so the Foundation block must be selected too. Foundation comes with the demo catalog — or pick existing groups and categories in the block's settings."
        case .unknownScope(let block, let scope):
            "The block \"\(block)\" is scoped to \"\(scope)\", which the Foundation block does not provide."
        case .scopeNotChosen(let block):
            "The block \"\(block)\" has no scope yet. Open its settings and choose a group."
        case .missingRequiredSetting(let block, let setting):
            "The block \"\(block)\" needs a value for its \"\(setting)\" setting."
        case .unmetDependencies(let block, let type, let names):
            "The block \"\(block)\" references \(type.replacingOccurrences(of: "_", with: " "))s no selected block creates: \(names.joined(separator: ", ")). Select the block that creates them, or remove this block."
        case .conflictingSettings(let type, let blocks):
            "The blocks \(blocks.map { "\"\($0)\"" }.joined(separator: " and ")) both manage the tenant's \(type.replacingOccurrences(of: "jamfplatform_pro_", with: "").replacingOccurrences(of: "_", with: " ")). A setting can belong to one block only — deselect one of them."
        }
    }
}

/// Generates the tenant workspace's HCL from the app model. Secrets never
/// appear in generated files: secret settings become sensitive root
/// variables fed through TF_VAR_* environment variables.
public nonisolated enum WorkspaceGenerator {
    /// Foundation group keys → output name stems.
    public static let foundationGroups = ["pilot", "all_macs", "laptops", "desktops", "apple_silicon"]

    public struct Output: Sendable {
        public var providersTF: String
        public var mainTF: String
        /// Root variable names (TF_VAR_…) for secret settings, keyed by
        /// "<blockID>/<settingKey>".
        public var secretVariableNames: [String: String]
    }

    public static func generate(_ input: WorkspaceInput) throws -> Output {
        // Foundation is needed only when a selected block wires to it:
        // Foundation-scoped blocks, Foundation categories, or an explicit
        // requirement. Fidelity-captured baselines bring their own groups
        // and categories, and blocks can point at existing ones instead.
        let needsFoundation = input.selections.contains(where: \.wiresThroughFoundation)
        if needsFoundation,
           !input.selections.contains(where: { $0.block.id == "foundation" }) {
            throw WorkspaceGeneratorError.missingFoundation
        }

        var secretVariables: [String: String] = [:]
        var sections: [String] = []

        // Root variables: name_prefix plus one sensitive variable per secret
        // setting.
        var rootVariables = """
        variable "name_prefix" {
          description = "Prefix applied to every object name."
          type        = string
          default     = \(hclString(input.namePrefix))
        }
        """

        for selection in sortedSelections(input.selections) {
            let block = selection.block
            var arguments: [(String, String)] = [
                ("source", hclString("./modules/\(block.id)")),
                ("name_prefix", "var.name_prefix"),
                ("managed_by_tag", hclString(block.managedByTag)),
            ]

            // Scope wiring: one device group supplies both ID kinds.
            switch block.scope.kind {
            case .none:
                break
            case .jamfProGroup, .platformGroup:
                guard let variable = block.scope.variable else { break }
                if let existing = selection.existingScopeID {
                    arguments.append((variable, hclString(existing)))
                    break
                }
                if let provided = selection.providedScope {
                    let provider = try Self.provider(of: provided, kind: "device_group", for: block.id, in: input)
                    let map = block.scope.kind == .jamfProGroup ? "device_group_jamf_pro_ids" : "device_group_ids"
                    arguments.append((variable, "module.\(sanitized(provider.id)).\(map)[\(hclString(provided.name))]"))
                    break
                }
                if selection.scope.isEmpty {
                    throw WorkspaceGeneratorError.scopeNotChosen(block: block.id)
                }
                guard Self.foundationGroups.contains(selection.scope) else {
                    throw WorkspaceGeneratorError.unknownScope(block: block.id, scope: selection.scope)
                }
                let suffix = block.scope.kind == .jamfProGroup ? "jamf_pro_id" : "platform_uuid"
                arguments.append((variable, "module.foundation.\(selection.scope)_\(suffix)"))
            }

            // Category wiring: an existing category, one another block
            // creates, or (legacy) Foundation's category for the block's
            // catalog category.
            if block.acceptsCategory, let existing = selection.existingCategoryID {
                arguments.append(("category_id", hclString(existing)))
            } else if block.acceptsCategory, let provided = selection.providedCategory {
                let provider = try Self.provider(of: provided, kind: "category", for: block.id, in: input)
                arguments.append(("category_id", "module.\(sanitized(provider.id)).category_ids[\(hclString(provided.name))]"))
            } else if block.acceptsCategory {
                let key = foundationCategoryKey(for: block.category)
                arguments.append(("category_id", "module.foundation.category_\(key)_id"))
            }

            // Dependency wiring: name-keyed maps from every selected block
            // that provides the needed type. Fidelity-captured blocks carry
            // their associations this way.
            for (depKey, names) in block.needs.sorted(by: { $0.key < $1.key }) {
                let providers = input.selections
                    .map(\.block)
                    .filter { $0.id != block.id && !($0.provides[depKey] ?? []).isEmpty }
                let covered = Set(providers.flatMap { $0.provides[depKey] ?? [] })
                let missing = names.filter { !covered.contains($0) }
                guard missing.isEmpty else {
                    throw WorkspaceGeneratorError.unmetDependencies(
                        block: block.id, type: depKey, names: missing)
                }
                let maps = providers
                    .map { "module.\(sanitized($0.id)).\(depKey)_ids" }
                    .joined(separator: ", ")
                arguments.append(("dep_\(depKey)_ids", providers.count == 1 ? maps : "merge(\(maps))"))
                let nameMaps = providers
                    .map { "module.\(sanitized($0.id)).\(depKey)_names" }
                    .joined(separator: ", ")
                arguments.append(("dep_\(depKey)_names", providers.count == 1 ? nameMaps : "merge(\(nameMaps))"))
                if depKey == "device_group" {
                    let proMaps = providers
                        .map { "module.\(sanitized($0.id)).device_group_jamf_pro_ids" }
                        .joined(separator: ", ")
                    arguments.append(("dep_device_group_jamf_pro_ids", providers.count == 1 ? proMaps : "merge(\(proMaps))"))
                }
            }

            // Settings.
            for setting in block.settings {
                let raw = selection.settings[setting.key] ?? setting.default
                // Secret values are supplied at launch time (TF_VAR_* from the
                // Keychain), so an empty stored value is expected here.
                if setting.required && raw.isEmpty && setting.type != .bool && setting.type != .secret {
                    throw WorkspaceGeneratorError.missingRequiredSetting(block: block.id, setting: setting.key)
                }
                switch setting.type {
                case .secret:
                    let variableName = "\(sanitized(block.id))_\(setting.key)"
                    secretVariables["\(block.id)/\(setting.key)"] = variableName
                    rootVariables += """


                    variable "\(variableName)" {
                      description = \(hclString("\(block.name): \(setting.title)"))
                      type        = string
                      sensitive   = true
                    }
                    """
                    arguments.append((setting.key, "var.\(variableName)"))
                case .bool:
                    arguments.append((setting.key, raw == "true" ? "true" : "false"))
                case .number:
                    arguments.append((setting.key, raw.isEmpty ? "null" : raw))
                case .string, .enumeration, .appPicker:
                    arguments.append((setting.key, hclString(raw)))
                case .stringList:
                    let items = raw.split(separator: "\n").map { hclString(String($0)) }
                    arguments.append((setting.key, "[\(items.joined(separator: ", "))]"))
                }
            }

            let width = arguments.map(\.0.count).max() ?? 0
            let body = arguments
                .map { "  \($0.0.padding(toLength: width, withPad: " ", startingAt: 0)) = \($0.1)" }
                .joined(separator: "\n")
            sections.append("module \"\(sanitized(block.id))\" {\n\(body)\n}")
        }

        // Blocks for Jamf Protect bring in the second provider; its
        // credentials come from JAMFPROTECT_* environment variables.
        let needsProtect = input.selections.contains { $0.block.products.contains("jamf-protect") }
        let protectRequirement = needsProtect ? """

            jamfprotect = {
              source  = "Jamf-Concepts/jamfprotect"
              version = "\(input.protectProviderVersion)"
            }
        """ : ""
        let protectProvider = needsProtect ? """


        provider "jamfprotect" {
        }
        """ : ""

        let providersTF = """
        # Generated by Jamf Deployer — do not edit. Regenerated on every run.
        terraform {
          required_providers {
            jamfplatform = {
              source  = "jamf/jamfplatform"
              version = "\(input.providerVersion)"
            }\(protectRequirement)
          }

          # The tenant record lives next to the generated configuration,
          # encrypted via TF_ENCRYPTION, with automatic backups.
          backend "local" {
            path = "../state/terraform.tfstate"
          }
        }

        # Credentials come from JAMFPLATFORM_* environment variables at run
        # time. Nothing secret is ever written to this folder.
        provider "jamfplatform" {
          impact_alerts = true
        }\(protectProvider)
        """

        // "Stop managing": the module call disappears and a removed block
        // tells the engine to forget the objects instead of deleting them.
        for removal in input.removals where removal.keepInJamf {
            sections.append("""
            removed {
              from = module.\(sanitized(removal.blockID))

              lifecycle {
                destroy = false
              }
            }
            """)
        }

        let mainTF = """
        # Generated by Jamf Deployer — do not edit. Regenerated on every run.
        \(rootVariables)

        \(sections.joined(separator: "\n\n"))
        """

        return Output(
            providersTF: providersTF,
            mainTF: mainTF,
            secretVariableNames: secretVariables
        )
    }

    /// Tenant-wide settings exist once per tenant; two blocks managing the
    /// same one would overwrite each other on every deploy.
    static func checkSettingOwnership(selections: [GeneratedSelection], catalog: LoadedCatalog) throws {
        var owners: [String: [String]] = [:]
        for selection in selections {
            let folder = selection.folderURL ?? catalog.blockFolderURL(id: selection.block.id)
            guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            var types: Set<String> = []
            for file in files where file.pathExtension == "tf" {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                for match in text.matches(of: /resource\s+"([a-z0-9_]+)"\s+"singleton"/) {
                    types.insert(String(match.1))
                }
            }
            for type in types { owners[type, default: []].append(selection.block.id) }
        }
        if let (type, blocks) = owners.sorted(by: { $0.key < $1.key }).first(where: { $0.value.count > 1 }) {
            throw WorkspaceGeneratorError.conflictingSettings(type: type, blocks: blocks)
        }
    }

    /// Writes the generated configuration and copies the pinned block
    /// folders into `<workspace>/modules/`, replacing previous contents.
    public static func materialize(
        _ output: Output,
        selections: [GeneratedSelection],
        catalog: LoadedCatalog,
        workspaceURL: URL
    ) throws {
        let fileManager = FileManager.default
        try checkSettingOwnership(selections: selections, catalog: catalog)
        try fileManager.createDirectory(at: workspaceURL, withIntermediateDirectories: true)

        try Data(output.providersTF.utf8).write(
            to: workspaceURL.appending(path: "providers.tf"), options: .atomic)
        try Data(output.mainTF.utf8).write(
            to: workspaceURL.appending(path: "main.tf"), options: .atomic)

        let modulesURL = workspaceURL.appending(path: "modules")
        try? fileManager.removeItem(at: modulesURL)
        try fileManager.createDirectory(at: modulesURL, withIntermediateDirectories: true)
        for selection in selections {
            let source = selection.folderURL ?? catalog.blockFolderURL(id: selection.block.id)
            let destination = modulesURL.appending(path: selection.block.id)
            try fileManager.copyItem(at: source, to: destination)
        }
    }

    // MARK: Helpers

    static func sortedSelections(_ selections: [GeneratedSelection]) -> [GeneratedSelection] {
        selections.sorted {
            if $0.block.id == "foundation" { return true }
            if $1.block.id == "foundation" { return false }
            return $0.block.id < $1.block.id
        }
    }

    /// The selected block that creates a referenced group or category.
    static func provider(of object: ProvidedObject, kind: String, for blockID: String, in input: WorkspaceInput) throws -> BlockMetadata {
        guard let provider = input.selections.map(\.block).first(where: { $0.id == object.blockID }),
              (provider.provides[kind] ?? []).contains(object.name)
        else {
            throw WorkspaceGeneratorError.unmetDependencies(block: blockID, type: kind, names: [object.name])
        }
        return provider
    }

    static func foundationCategoryKey(for category: String) -> String {
        switch category {
        case "Security": "security"
        case "Applications": "applications"
        case "Maintenance": "maintenance"
        case "Enrollment": "enrollment"
        default: "maintenance"
        }
    }

    public static func sanitized(_ id: String) -> String {
        id.replacingOccurrences(of: "-", with: "_")
    }

    static func hclString(_ value: String) -> String {
        var escaped = value
        escaped = escaped.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"")
        escaped = escaped.replacingOccurrences(of: "${", with: "$${")
        escaped = escaped.replacingOccurrences(of: "%{", with: "%%{")
        escaped = escaped.replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}
