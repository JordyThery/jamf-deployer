import Foundation

/// One selected block with its resolved settings, ready for generation.
public nonisolated struct GeneratedSelection: Sendable {
    public var block: BlockMetadata
    /// Non-secret setting values keyed by setting key.
    public var settings: [String: String]
    /// Overrides the catalog's folder for this block — used when a selection
    /// is pinned to a different catalog tag than the tenant default.
    public var folderURL: URL?
    /// An existing group in the tenant the block is scoped to, by the ID
    /// kind the block's scope variable takes.
    public var existingScopeID: String?
    /// An existing category in the tenant ("-1" for none).
    public var existingCategoryID: String?
    /// A group another selected block creates.
    public var providedScope: ProvidedObject?
    /// A category another selected block creates.
    public var providedCategory: ProvidedObject?
    /// The module's path inside the block folder for the tenant's
    /// connection ("" for the folder itself); see `BlockModule`.
    public var modulePath: String

    public init(
        block: BlockMetadata,
        settings: [String: String],
        folderURL: URL? = nil,
        existingScopeID: String? = nil,
        existingCategoryID: String? = nil,
        providedScope: ProvidedObject? = nil,
        providedCategory: ProvidedObject? = nil,
        modulePath: String = ""
    ) {
        self.block = block
        self.settings = settings
        self.folderURL = folderURL
        self.existingScopeID = existingScopeID
        self.existingCategoryID = existingCategoryID
        self.providedScope = providedScope
        self.providedCategory = providedCategory
        self.modulePath = modulePath
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
    /// The API the tenant is reached through: it picks the engine plugin
    /// and each block's module.
    public var connection: ConnectionKind
    public var jamfProProviderVersion: String
    /// Where the engine keeps the tenant's state.
    public var stateBackend: StateBackend
    /// Blocks leaving the baseline. `keepInJamf` removals become
    /// "Stop managing": the objects leave the tenant record untouched.
    public var removals: [BlockRemoval]

    public init(
        namePrefix: String,
        selections: [GeneratedSelection],
        providerVersion: String,
        protectProviderVersion: String = "0.12.0",
        removals: [BlockRemoval] = [],
        connection: ConnectionKind = .platform,
        jamfProProviderVersion: String = "0.42.0",
        stateBackend: StateBackend = .local
    ) {
        self.namePrefix = namePrefix
        self.selections = selections
        self.providerVersion = providerVersion
        self.protectProviderVersion = protectProviderVersion
        self.removals = removals
        self.connection = connection
        self.jamfProProviderVersion = jamfProProviderVersion
        self.stateBackend = stateBackend
    }
}

/// Solo tenants keep state in their workspace; Team Mode tenants use the
/// engine's HTTP backend, configured entirely through TF_HTTP_* variables.
public nonisolated enum StateBackend: Sendable {
    case local
    case http
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
    case scopeNotChosen(block: String)
    case missingRequiredSetting(block: String, setting: String)
    case invalidNumber(block: String, setting: String, value: String)
    case unmetDependencies(block: String, type: String, names: [String])
    /// Two selected blocks manage the same tenant-wide setting.
    case conflictingSettings(type: String, blocks: [String])
    /// The block has no module for the tenant's connection.
    case unsupportedConnection(block: String, connection: ConnectionKind)

    public var errorDescription: String? {
        switch self {
        case .scopeNotChosen(let block):
            "The block \"\(block)\" has no scope yet. Open its settings and choose a group."
        case .missingRequiredSetting(let block, let setting):
            "The block \"\(block)\" needs a value for its \"\(setting)\" setting."
        case .invalidNumber(let block, let setting, let value):
            "The block \"\(block)\" needs a number for its \"\(setting)\" setting, not \"\(value)\"."
        case .unmetDependencies(let block, let type, let names):
            "The block \"\(block)\" references \(type.replacingOccurrences(of: "_", with: " "))s no selected block creates: \(names.joined(separator: ", ")). Select the block that creates them, or remove this block."
        case .unsupportedConnection(let block, let connection):
            "The block \"\(block)\" has no \(connection == .jamfPro ? "Jamf Pro API" : "Jamf Platform API") version in the catalog release this tenant uses. Update the block with Baseline Updates…, or remove it from the baseline."
        case .conflictingSettings(let type, let blocks):
            "The blocks \(blocks.map { "\"\($0)\"" }.joined(separator: " and ")) both manage the tenant's \(type.replacingOccurrences(of: "jamfplatform_pro_", with: "").replacingOccurrences(of: "jamfpro_", with: "").replacingOccurrences(of: "_", with: " ")). A setting can belong to one block only — deselect one of them."
        }
    }
}

/// Generates the tenant workspace's HCL from the app model. Secrets never
/// appear in generated files: secret settings become sensitive root
/// variables fed through TF_VAR_* environment variables.
public nonisolated enum WorkspaceGenerator {
    public struct Output: Sendable {
        public var providersTF: String
        public var mainTF: String
        /// Root variable names (TF_VAR_…) for secret settings, keyed by
        /// "<blockID>/<settingKey>".
        public var secretVariableNames: [String: String]
    }

    /// Sets each selection's module path for `connection`, or names the
    /// first block that cannot deploy through it.
    public static func resolveModules(
        _ selections: [GeneratedSelection],
        catalog: LoadedCatalog,
        connection: ConnectionKind
    ) throws -> [GeneratedSelection] {
        try selections.map { selection in
            let folder = selection.folderURL ?? catalog.blockFolderURL(id: selection.block.id)
            guard let path = BlockModule.modulePath(ofBlockAt: folder, for: connection) else {
                throw WorkspaceGeneratorError.unsupportedConnection(block: selection.block.name, connection: connection)
            }
            var resolved = selection
            resolved.modulePath = path
            return resolved
        }
    }

    /// One block's module call, before rendering: the app's workspace and
    /// the standalone export render the same calls differently.
    public struct ModuleCall: Sendable {
        public enum Value: Sendable, Equatable {
            /// A setting value as an HCL literal, with its HCL type.
            case setting(String, type: String)
            /// An expression wiring this block to another one.
            case reference(String)
            /// A secret setting, supplied through a sensitive root variable.
            case secret(variable: String)
        }

        public struct Argument: Sendable {
            public var key: String
            public var value: Value
        }

        /// The module's name: the block ID with dashes as underscores.
        public var name: String
        public var blockID: String
        /// The module's path inside the block folder ("" or "jamfpro").
        public var modulePath: String
        /// Every argument after source and name_prefix, in rendering order.
        public var arguments: [Argument]
    }

    /// A sensitive root variable carrying one secret setting.
    public struct SecretVariable: Sendable {
        public var key: String          // "<blockID>/<settingKey>"
        public var name: String
        public var description: String
    }

    /// The module calls for `input`, in rendering order, with the secret
    /// variables they use.
    public static func moduleCalls(_ input: WorkspaceInput) throws -> (calls: [ModuleCall], secrets: [SecretVariable]) {
        var calls: [ModuleCall] = []
        var secrets: [SecretVariable] = []

        for selection in sortedSelections(input.selections) {
            let block = selection.block
            var arguments: [ModuleCall.Argument] = [
                .init(key: "managed_by_tag", value: .setting(hclString(block.managedByTag), type: "string")),
            ]

            // Scope wiring: one device group supplies both ID kinds.
            switch block.scope.kind {
            case .none:
                break
            case .jamfProGroup, .platformGroup, .jamfProMobileGroup:
                guard let variable = block.scope.variable else { break }
                if let existing = selection.existingScopeID {
                    arguments.append(.init(key: variable, value: .setting(hclString(existing), type: "string")))
                    break
                }
                if let provided = selection.providedScope {
                    let provider = try Self.provider(of: provided, kind: "device_group", for: block.name, in: input)
                    // Jamf Pro API modules only know Jamf Pro IDs.
                    let map = block.scope.kind == .platformGroup && input.connection == .platform
                        ? "device_group_ids" : "device_group_jamf_pro_ids"
                    arguments.append(.init(key: variable, value: .reference(
                        "module.\(sanitized(provider.id)).\(map)[\(hclString(provided.name))]")))
                    break
                }
                throw WorkspaceGeneratorError.scopeNotChosen(block: block.name)
            }

            // Category wiring: one another block creates, an existing
            // category, or none ("-1").
            if block.acceptsCategory, let provided = selection.providedCategory {
                let provider = try Self.provider(of: provided, kind: "category", for: block.name, in: input)
                arguments.append(.init(key: "category_id", value: .reference(
                    "module.\(sanitized(provider.id)).category_ids[\(hclString(provided.name))]")))
            } else if block.acceptsCategory {
                arguments.append(.init(key: "category_id", value: .setting(hclString(selection.existingCategoryID ?? "-1"), type: "string")))
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
                        block: block.name, type: depKey, names: missing)
                }
                func merged(_ suffix: String) -> String {
                    let maps = providers.map { "module.\(sanitized($0.id)).\(suffix)" }.joined(separator: ", ")
                    return providers.count == 1 ? maps : "merge(\(maps))"
                }
                arguments.append(.init(key: "dep_\(depKey)_ids", value: .reference(merged("\(depKey)_ids"))))
                arguments.append(.init(key: "dep_\(depKey)_names", value: .reference(merged("\(depKey)_names"))))
                if depKey == "device_group" {
                    arguments.append(.init(key: "dep_device_group_jamf_pro_ids", value: .reference(merged("device_group_jamf_pro_ids"))))
                }
            }

            // Settings.
            for setting in block.settings {
                let raw = selection.settings[setting.key] ?? setting.default
                // Secret values are supplied at launch time (TF_VAR_* from the
                // Keychain), so an empty stored value is expected here.
                if setting.required && raw.isEmpty && setting.type != .bool && setting.type != .secret {
                    throw WorkspaceGeneratorError.missingRequiredSetting(block: block.name, setting: setting.title)
                }
                switch setting.type {
                case .secret:
                    let variableName = "\(sanitized(block.id))_\(setting.key)"
                    secrets.append(SecretVariable(
                        key: "\(block.id)/\(setting.key)", name: variableName,
                        description: "\(block.name): \(setting.title)"))
                    arguments.append(.init(key: setting.key, value: .secret(variable: variableName)))
                case .bool:
                    arguments.append(.init(key: setting.key, value: .setting(raw == "true" ? "true" : "false", type: "bool")))
                case .number:
                    // Written unquoted, so only a plain number is accepted.
                    let trimmed = raw.trimmingCharacters(in: .whitespaces)
                    guard trimmed.isEmpty || (Double(trimmed) != nil && trimmed.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" })) else {
                        throw WorkspaceGeneratorError.invalidNumber(block: block.name, setting: setting.title, value: raw)
                    }
                    arguments.append(.init(key: setting.key, value: .setting(trimmed.isEmpty ? "null" : trimmed, type: "number")))
                case .string, .enumeration, .appPicker, .macAppStorePicker, .mobileAppStorePicker:
                    arguments.append(.init(key: setting.key, value: .setting(hclString(raw), type: "string")))
                case .stringList:
                    // "\r\n" is one Character, so splitting on "\n" alone
                    // would leave pasted CRLF text as a single item.
                    let items = raw.split(whereSeparator: \.isNewline).map { hclString(String($0)) }
                    arguments.append(.init(key: setting.key, value: .setting("[\(items.joined(separator: ", "))]", type: "list(string)")))
                }
            }

            calls.append(ModuleCall(
                name: sanitized(block.id), blockID: block.id,
                modulePath: selection.modulePath, arguments: arguments))
        }
        return (calls, secrets)
    }

    /// Lines of `key = value` aligned the way `terraform fmt` aligns them.
    static func aligned(_ pairs: [(String, String)], indent: String = "  ") -> String {
        let width = pairs.map(\.0.count).max() ?? 0
        return pairs
            .map { "\(indent)\($0.0.padding(toLength: width, withPad: " ", startingAt: 0)) = \($0.1)" }
            .joined(separator: "\n")
    }

    public static func generate(_ input: WorkspaceInput) throws -> Output {
        let (calls, secrets) = try moduleCalls(input)

        // Root variables: name_prefix plus one sensitive variable per secret
        // setting.
        var rootVariables = """
        variable "name_prefix" {
          description = "Prefix applied to every object name."
          type        = string
          default     = \(hclString(input.namePrefix))
        }
        """
        for secret in secrets {
            rootVariables += """


            variable "\(secret.name)" {
              description = \(hclString(secret.description))
              type        = string
              sensitive   = true
            }
            """
        }

        var sections: [String] = calls.map { call in
            var pairs: [(String, String)] = [
                ("source", hclString("./modules/\(call.blockID)" + (call.modulePath.isEmpty ? "" : "/\(call.modulePath)"))),
                ("name_prefix", "var.name_prefix"),
            ]
            for argument in call.arguments {
                switch argument.value {
                case .setting(let literal, _): pairs.append((argument.key, literal))
                case .reference(let expression): pairs.append((argument.key, expression))
                case .secret(let variable): pairs.append((argument.key, "var.\(variable)"))
                }
            }
            return "module \"\(call.name)\" {\n\(aligned(pairs))\n}"
        }
        let secretVariables = Dictionary(secrets.map { ($0.key, $0.name) }, uniquingKeysWith: { _, last in last })

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

        let providersTF = input.connection == .jamfPro
            ? jamfProProviders(input, protectRequirement: protectRequirement, protectProvider: protectProvider)
            : platformProviders(input, protectRequirement: protectRequirement, protectProvider: protectProvider)

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

    static func platformProviders(_ input: WorkspaceInput, protectRequirement: String, protectProvider: String) -> String {
        """
        # Generated by Jamf Deployer — do not edit. Regenerated on every run.
        terraform {
          required_providers {
            jamfplatform = {
              source  = "jamf/jamfplatform"
              version = "\(input.providerVersion)"
            }\(protectRequirement)
          }

        \(backendBlock(input))
        }

        # Credentials come from JAMFPLATFORM_* environment variables at run
        # time. Nothing secret is ever written to this folder.
        provider "jamfplatform" {
          impact_alerts = true
        }\(protectProvider)
        """
    }

    static func jamfProProviders(_ input: WorkspaceInput, protectRequirement: String, protectProvider: String) -> String {
        """
        # Generated by Jamf Deployer — do not edit. Regenerated on every run.
        terraform {
          required_providers {
            jamfpro = {
              source  = "deploymenttheory/jamfpro"
              version = "\(input.jamfProProviderVersion)"
            }\(protectRequirement)
          }

        \(backendBlock(input))
        }

        # The instance URL and credentials come from JAMFPRO_* environment
        # variables at run time. Nothing secret is ever written to this folder.
        provider "jamfpro" {
        }\(protectProvider)
        """
    }

    /// Tenant-wide settings exist once per tenant; two blocks managing the
    /// same one would overwrite each other on every deploy.
    static func checkSettingOwnership(selections: [GeneratedSelection], catalog: LoadedCatalog) throws {
        var owners: [String: [String]] = [:]
        for selection in selections {
            let folder = (selection.folderURL ?? catalog.blockFolderURL(id: selection.block.id))
                .appending(path: selection.modulePath)
            guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            var types: Set<String> = []
            for file in files where file.pathExtension == "tf" {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                for match in text.matches(of: /resource\s+"([a-z0-9_]+)"\s+"singleton"/) {
                    types.insert(String(match.1))
                }
            }
            for type in types { owners[type, default: []].append(selection.block.name) }
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

    /// The state backend block, placed inside the terraform block of
    /// providers.tf. The interpolation there sits at column 0 once Swift
    /// strips the literal's indentation, so every line gets the block's
    /// two-space body indentation here.
    static func backendBlock(_ input: WorkspaceInput) -> String {
        let lines: [String] = switch input.stateBackend {
        case .local: [
            "# The tenant record lives next to the generated configuration,",
            "# encrypted via TF_ENCRYPTION, with automatic backups.",
            "backend \"local\" {",
            "  path = \"../state/terraform.tfstate\"",
            "}",
        ]
        case .http: [
            "# Team Mode: the state backend on this Mac stores the encrypted",
            "# record in the team repository and locks it while in use.",
            "# Its address and password come from TF_HTTP_* variables.",
            "backend \"http\" {",
            "}",
        ]
        }
        return lines
            .map { "  " + $0 }
            .joined(separator: "\n")
    }

    // MARK: Helpers

    static func sortedSelections(_ selections: [GeneratedSelection]) -> [GeneratedSelection] {
        selections.sorted { $0.block.id < $1.block.id }
    }

    /// The selected block that creates a referenced group or category.
    static func provider(of object: ProvidedObject, kind: String, for blockName: String, in input: WorkspaceInput) throws -> BlockMetadata {
        guard let provider = input.selections.map(\.block).first(where: { $0.id == object.blockID }),
              (provider.provides[kind] ?? []).contains(object.name)
        else {
            throw WorkspaceGeneratorError.unmetDependencies(block: blockName, type: kind, names: [object.name])
        }
        return provider
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
        escaped = escaped.replacingOccurrences(of: "\r", with: "\\r")
        escaped = escaped.replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }
}
