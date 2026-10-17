import Foundation

/// One selected block with its resolved settings, ready for generation.
public nonisolated struct GeneratedSelection: Sendable {
    public var block: BlockMetadata
    /// Non-secret setting values keyed by setting key.
    public var settings: [String: String]
    /// Foundation group key this block is scoped to (pilot, all_macs, …).
    public var scope: String
    /// Overrides the catalog's folder for this block — used when a selection
    /// is pinned to a different catalog tag than the tenant default.
    public var folderURL: URL?

    public init(block: BlockMetadata, settings: [String: String], scope: String, folderURL: URL? = nil) {
        self.block = block
        self.settings = settings
        self.scope = scope
        self.folderURL = folderURL
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
    case missingRequiredSetting(block: String, setting: String)

    public var errorDescription: String? {
        switch self {
        case .missingFoundation:
            "The Foundation block must be part of every baseline."
        case .unknownScope(let block, let scope):
            "The block \"\(block)\" is scoped to \"\(scope)\", which the Foundation block does not provide."
        case .missingRequiredSetting(let block, let setting):
            "The block \"\(block)\" needs a value for its \"\(setting)\" setting."
        }
    }
}

/// Generates the tenant workspace's HCL from the app model. Secrets never
/// appear in generated files: secret settings become sensitive root
/// variables fed through TF_VAR_* environment variables.
public nonisolated enum WorkspaceGenerator {
    /// Foundation group keys → output name stems.
    static let foundationGroups = ["pilot", "all_macs", "laptops", "desktops", "apple_silicon"]

    public struct Output: Sendable {
        public var providersTF: String
        public var mainTF: String
        /// Root variable names (TF_VAR_…) for secret settings, keyed by
        /// "<blockID>/<settingKey>".
        public var secretVariableNames: [String: String]
    }

    public static func generate(_ input: WorkspaceInput) throws -> Output {
        // Hand over empties the baseline entirely; otherwise foundation is
        // mandatory because every other block scopes through it.
        if !input.selections.isEmpty {
            guard input.selections.contains(where: { $0.block.id == "foundation" }) else {
                throw WorkspaceGeneratorError.missingFoundation
            }
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
                guard Self.foundationGroups.contains(selection.scope) else {
                    throw WorkspaceGeneratorError.unknownScope(block: block.id, scope: selection.scope)
                }
                let suffix = block.scope.kind == .jamfProGroup ? "jamf_pro_id" : "platform_uuid"
                arguments.append((variable, "module.foundation.\(selection.scope)_\(suffix)"))
            }

            // Category wiring: blocks that accept a category get the one
            // matching their catalog category, when foundation provides it.
            if block.acceptsCategory {
                let key = foundationCategoryKey(for: block.category)
                arguments.append(("category_id", "module.foundation.category_\(key)_id"))
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

    /// Writes the generated configuration and copies the pinned block
    /// folders into `<workspace>/modules/`, replacing previous contents.
    public static func materialize(
        _ output: Output,
        selections: [GeneratedSelection],
        catalog: LoadedCatalog,
        workspaceURL: URL
    ) throws {
        let fileManager = FileManager.default
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
