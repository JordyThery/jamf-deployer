import Foundation

/// Turns a jamformer export into a reusable building block:
/// names become `${var.name_prefix}…`, hard-coded group IDs become a scope
/// setting, support files move into `files/`, and block.json is written with
/// the permissions the export recorded. Captured blocks are marked
/// "Review before use" until a curator marks them reviewed.
public nonisolated enum BlockCapture {
    /// How captured references to other objects are handled.
    public enum RebindMode: String, Sendable {
        /// Associations survive: references become name-keyed lookups wired
        /// to the blocks that create the referenced objects. The default —
        /// a captured baseline deploys exactly as it was.
        case fidelity
        /// Scope and category collapse to Foundation-wired settings: right
        /// for publishing small portable blocks.
        case foundation
    }

    public struct Request: Sendable {
        public var blockID: String
        public var name: String
        public var summary: String
        /// The exporting tenant's name prefix, stripped and parameterized.
        public var namePrefix: String
        /// The jamformer output folder.
        public var sourceDirectory: URL
        /// The catalog source root the block is saved into.
        public var catalogRootDirectory: URL
        public var secretFindings: [String]
        /// Scope ID of the tenant the objects were exported from; used to
        /// warn when the block is enabled in its own origin tenant.
        public var originTenantScopeID: String?
        public var rebind: RebindMode
        /// Prefixes every object name, not only names that already carried
        /// the source tenant's prefix.
        public var prefixAllNames: Bool
        /// The full export the ID→name reference table is built from — pass
        /// the unpruned export when capturing a slice of it.
        public var resolutionDirectory: URL?

        public init(
            blockID: String,
            name: String,
            summary: String,
            namePrefix: String,
            sourceDirectory: URL,
            catalogRootDirectory: URL,
            secretFindings: [String] = [],
            originTenantScopeID: String? = nil,
            rebind: RebindMode = .fidelity,
            prefixAllNames: Bool = false,
            resolutionDirectory: URL? = nil
        ) {
            self.blockID = blockID
            self.name = name
            self.summary = summary
            self.namePrefix = namePrefix
            self.sourceDirectory = sourceDirectory
            self.catalogRootDirectory = catalogRootDirectory
            self.secretFindings = secretFindings
            self.originTenantScopeID = originTenantScopeID
            self.rebind = rebind
            self.prefixAllNames = prefixAllNames
            self.resolutionDirectory = resolutionDirectory
        }
    }

    /// Terraform types whose instances other objects reference, and the
    /// dependency key used for the name→ID wiring between blocks.
    static let dependencyTypes: [String: String] = [
        "jamfplatform_pro_category": "category",
        "jamfplatform_pro_script": "script",
        "jamfplatform_pro_package": "package",
        "jamfplatform_device_group": "device_group",
    ]

    /// ID→name knowledge from a full export: import files carry the Jamf
    /// IDs, resource definitions carry the names.
    struct ReferenceTable {
        /// "jamfplatform_pro_script#143" → object name.
        var nameByTypeAndID: [String: String] = [:]
        /// "jamfplatform_pro_script.foo" → object name.
        var nameByAddress: [String: String] = [:]

        func name(type: String, id: String) -> String? {
            nameByTypeAndID["\(type)#\(id)"]
        }
    }

    public struct Result: Sendable {
        public var blockFolderURL: URL
        public var objectCount: Int
        public var usesJamfProScope: Bool
        public var usesPlatformScope: Bool
        public var warnings: [String]
    }

    public enum CaptureError: LocalizedError {
        case nothingToCapture
        case invalidBlockID

        public var errorDescription: String? {
            switch self {
            case .nothingToCapture:
                "The export contains no objects to capture."
            case .invalidBlockID:
                "Block IDs use lowercase letters, digits and dashes only."
            }
        }
    }

    public static func capture(_ request: Request) throws -> Result {
        guard request.blockID.range(of: "^[a-z0-9][a-z0-9-]*$", options: .regularExpression) != nil else {
            throw CaptureError.invalidBlockID
        }

        let fileManager = FileManager.default
        let blockURL = request.catalogRootDirectory
            .appending(path: "blocks/\(request.blockID)")
        try? fileManager.removeItem(at: blockURL)
        try fileManager.createDirectory(at: blockURL, withIntermediateDirectories: true)

        var warnings: [String] = []
        var objectCount = 0
        var usesJamfProScope = false
        var usesPlatformScope = false
        var usesCategory = false
        var terraformTypes: Set<String> = []
        var capturedText = ""
        var fileTexts: [(name: String, text: String)] = []
        var needs: [String: Set<String>] = [:]
        let table = buildReferenceTable(
            exportDirectory: request.resolutionDirectory ?? request.sourceDirectory
        )
        // Resource addresses present in this capture's own slice.
        var localAddresses: Set<String> = []
        if let sourceFiles = try? fileManager.contentsOfDirectory(at: request.sourceDirectory, includingPropertiesForKeys: nil) {
            for file in sourceFiles where file.lastPathComponent.hasSuffix(".tf")
                && !file.lastPathComponent.hasSuffix("_import.tf") {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                for match in text.matches(of: /resource\s+"([a-z0-9_]+)"\s+"([A-Za-z0-9_-]+)"/) {
                    localAddresses.insert("\(match.1).\(match.2)")
                }
            }
        }

        // 1. Configuration files, transformed. provider/variables/tfvars and
        //    import blocks stay behind — a block is reusable configuration.
        let skipped: Set<String> = ["provider.tf", "variables.tf", "versions.tf", "terraform.tfvars"]
        let contents = try fileManager.contentsOfDirectory(at: request.sourceDirectory, includingPropertiesForKeys: nil)
        for file in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = file.lastPathComponent
            guard name.hasSuffix(".tf"), !skipped.contains(name), !name.hasSuffix("_import.tf") else { continue }

            var text = try String(contentsOf: file, encoding: .utf8)

            // The block never pins a provider alias of its own.
            text = text.replacingOccurrences(of: "  provider = jamfplatform\n\n", with: "")
            text = text.replacingOccurrences(of: "  provider = jamfplatform\n", with: "")

            // Name prefix: every quoted string that starts with the tenant's
            // prefix becomes "${var.name_prefix}…".
            if !request.namePrefix.isEmpty {
                text = text.replacingOccurrences(
                    of: "\"\(request.namePrefix)",
                    with: "\"${var.name_prefix}"
                )
            }

            if request.prefixAllNames {
                // Prefix every top-level object name that is not already
                // parameterized.
                text = text.replacingOccurrences(
                    of: #"(\n  name\s+= ")(?!\$\{var\.name_prefix\})"#,
                    with: "$1${var.name_prefix}",
                    options: .regularExpression
                )
            }

            // Support files move into files/.
            text = text.replacingOccurrences(of: "support_files/", with: "files/")

            // jamfplatform 1.5.0: macOS configuration profiles error with
            // "provider returned invalid result object after apply" when the
            // computed self_service.display_notifications is left unset.
            // Setting Jamf's default explicitly sidesteps the provider bug.
            if text.contains("jamfplatform_pro_macos_configuration_profile") {
                text = text.replacingOccurrences(
                    of: #"(  self_service = \{\n)(?![^}]*display_notifications)"#,
                    with: "$1    display_notifications     = true\n",
                    options: .regularExpression
                )
            }

            if request.rebind == .fidelity {
                // Associations survive: IDs become name-keyed lookups wired
                // to the blocks that create the referenced objects.
                for (key, names) in resolveAssociations(in: &text, table: table, localAddresses: localAddresses, warnings: &warnings) {
                    needs[key, default: []].formUnion(names)
                }
                fileTexts.append((name, text))
                continue
            }

            // Hard-coded scope group IDs become the block's scope setting.
            // jamformer writes multi-line lists with trailing commas and
            // "# TODO: unresolved reference" comments; match any non-empty
            // numeric list, leave empty lists (exclusions) alone.
            let groupListPattern = #"computer_group_ids\s*=\s*\[[^\]]*"\d+"[^\]]*\]"#
            if text.range(of: groupListPattern, options: .regularExpression) != nil {
                text = text.replacingOccurrences(
                    of: groupListPattern,
                    with: "computer_group_ids = [var.scope_jamf_pro_group_id]",
                    options: .regularExpression
                )
                usesJamfProScope = true
            }
            if text.range(of: #"smart_group_id\s*=\s*"\d+""#, options: .regularExpression) != nil {
                text = text.replacingOccurrences(
                    of: #"smart_group_id\s*=\s*"\d+""#,
                    with: "smart_group_id = var.scope_jamf_pro_group_id",
                    options: .regularExpression
                )
                usesJamfProScope = true
            }
            // Category IDs are tenant-specific numeric IDs too: swap them
            // for the block's category variable (wired to a foundation
            // category by the generator, "-1" = none otherwise).
            if text.range(of: #"category_id\s*=\s*"\d+""#, options: .regularExpression) != nil {
                text = text.replacingOccurrences(
                    of: #"category_id\s*=\s*"\d+""#,
                    with: "category_id = var.category_id",
                    options: .regularExpression
                )
                usesCategory = true
            }

            let platformListPattern = #"target_device_groups\s*=\s*\[[^\]]*"[0-9a-f-]{36}"[^\]]*\]"#
            if text.range(of: platformListPattern, options: .regularExpression) != nil {
                text = text.replacingOccurrences(
                    of: platformListPattern,
                    with: "target_device_groups = [var.scope_platform_group_uuid]",
                    options: .regularExpression
                )
                usesPlatformScope = true
            }
            let deviceGroupsPattern = #"(^|\n)(\s*)device_groups\s*=\s*\[[^\]]*"[0-9a-f-]{36}"[^\]]*\]"#
            if text.range(of: deviceGroupsPattern, options: .regularExpression) != nil {
                text = text.replacingOccurrences(
                    of: deviceGroupsPattern,
                    with: "$1$2device_groups = [var.scope_platform_group_uuid]",
                    options: .regularExpression
                )
                usesPlatformScope = true
            }

            fileTexts.append((name, text))
        }

        // 1b. Drop resources that depend on values the export cannot supply.
        // Jamf never returns icon files: their variables have no default and
        // no tfvars value, so the resources (and references to them) are
        // removed rather than captured broken.
        let exportedDeclarations = parseVariableDeclarations(
            at: request.sourceDirectory.appending(path: "variables.tf")
        )
        let exportedValues = parseTfvars(
            at: request.sourceDirectory.appending(path: "terraform.tfvars")
        )
        let generatedVariables: Set<String> = [
            "name_prefix", "managed_by_tag", "scope_jamf_pro_group_id",
            "scope_platform_group_uuid", "category_id",
        ]
        var unfillable: Set<String> = []
        for (_, text) in fileTexts {
            for match in text.matches(of: /var\.([a-zA-Z0-9_]+)/) {
                let name = String(match.1)
                guard !generatedVariables.contains(name), !name.hasPrefix("dep_") else { continue }
                let hasDefault = exportedDeclarations[name]?.contains("default") ?? false
                if !hasDefault && exportedValues[name] == nil {
                    unfillable.insert(name)
                }
            }
        }
        var droppedAddresses: [String] = []
        if !unfillable.isEmpty {
            // Pass 1: drop whole resources that use an unfillable variable.
            fileTexts = fileTexts.map { entry in
                let blocks = ExportedObjectInventory.topLevelBlocks(in: entry.text).filter { block in
                    let uses = unfillable.contains { block.contains("var.\($0)") }
                    if uses, let header = block.firstMatch(of: /resource\s+"([a-z0-9_]+)"\s+"([A-Za-z0-9_-]+)"/) {
                        droppedAddresses.append("\(header.1).\(header.2)")
                    }
                    return !uses
                }
                return (entry.name, blocks.joined(separator: "\n\n") + "\n")
            }
            // Pass 2: strip attribute objects and lines that referenced the
            // dropped resources.
            fileTexts = fileTexts.map { entry in
                (entry.name, Self.strippingReferences(to: droppedAddresses, in: entry.text))
            }
            if !droppedAddresses.isEmpty {
                warnings.append("Left out \(droppedAddresses.count) object\(droppedAddresses.count == 1 ? "" : "s") that need files Jamf does not export (Self Service icons): \(droppedAddresses.joined(separator: ", ")). Set them by hand after deploying.")
            }
        }

        // 1c. Write the files and count what survived.
        for (name, text) in fileTexts {
            guard text.contains("resource ") || text.contains("data ") else { continue }
            for match in text.matches(of: /resource\s+"([a-z0-9_]+)"\s+"/) {
                objectCount += 1
                terraformTypes.insert(String(match.1))
            }
            try Data(text.utf8).write(to: blockURL.appending(path: name))
            capturedText += text + "\n"
        }

        guard objectCount > 0 else {
            try? fileManager.removeItem(at: blockURL)
            throw CaptureError.nothingToCapture
        }

        // What this block provides to others: name→resource maps per type.
        // (address, objectName) pairs per dependency key.
        var provides: [String: [(address: String, name: String)]] = [:]
        for block in ExportedObjectInventory.topLevelBlocks(in: capturedText) {
            guard let header = block.firstMatch(of: /resource\s+"([a-z0-9_]+)"\s+"([A-Za-z0-9_-]+)"/),
                  let depKey = Self.dependencyTypes[String(header.1)]
            else { continue }
            let address = "\(header.1).\(header.2)"
            guard let objectName = table.nameByAddress[address]
                ?? block.firstMatch(of: /\n\s+name\s+= "([^"]*)"/).map({ String($0.1) })
            else { continue }
            provides[depKey, default: []].append((address, objectName))
        }

        // 2. Support files move after variables are known — see below: only
        // files the block actually references are copied, so a block carved
        // out of a larger export does not drag everything along.

        // 3. variables.tf for the block.
        var variables = """
        variable "name_prefix" {
          description = "Prefix applied to every object name."
          type        = string
        }

        variable "managed_by_tag" {
          description = "Provenance tag written into descriptions and notes."
          type        = string
        }
        """
        if usesJamfProScope {
            variables += """


            variable "scope_jamf_pro_group_id" {
              description = "Numeric Jamf Pro ID of the computer group this block targets."
              type        = string
            }
            """
        }
        if usesPlatformScope {
            variables += """


            variable "scope_platform_group_uuid" {
              description = "Platform UUID of the device group this block targets."
              type        = string
            }
            """
        }
        if usesCategory {
            variables += """


            variable "category_id" {
              description = "Jamf Pro category for this block's objects."
              type        = string
              default     = "-1"
            }
            """
        }
        // Variables the exported configuration references beyond the ones
        // generated above (icon file sources and similar) keep their original
        // declarations — dropping them breaks the module with "reference to
        // undeclared input variable".
        var referenced: Set<String> = []
        for match in capturedText.matches(of: /var\.([a-zA-Z0-9_]+)/) {
            referenced.insert(String(match.1))
        }
        for name in referenced.subtracting(generatedVariables).sorted() {
            if var declaration = exportedDeclarations[name] {
                if !declaration.contains("default"), let value = exportedValues[name],
                   let brace = declaration.range(of: "}", options: .backwards) {
                    declaration.replaceSubrange(
                        brace.lowerBound..<brace.lowerBound,
                        with: "  default = \(hclStringLiteral(value))\n"
                    )
                }
                variables += "\n\n" + declaration.replacingOccurrences(of: "support_files/", with: "files/")
            } else {
                variables += """


                variable "\(name)" {
                  type    = string
                  default = ""
                }
                """
                warnings.append("The variable \(name) is referenced but was not declared in the export; it was added with an empty default — review it.")
            }
        }

        for depKey in needs.keys.sorted() {
            variables += """


            variable "dep_\(depKey)_ids" {
              description = "IDs of \(depKey.replacingOccurrences(of: "_", with: " "))s this block references, keyed by object name."
              type        = map(string)
              default     = {}
            }
            """
            if depKey == "device_group" {
                variables += """


                variable "dep_device_group_jamf_pro_ids" {
                  description = "Numeric Jamf Pro IDs of referenced device groups, keyed by object name."
                  type        = map(string)
                  default     = {}
                }
                """
            }
        }

        try Data(variables.utf8).write(to: blockURL.appending(path: "variables.tf"))

        // Name→ID output maps, so other blocks can wire to this one.
        if !provides.isEmpty {
            var outputs = ""
            for (depKey, entries) in provides.sorted(by: { $0.key < $1.key }) {
                let pairs = entries
                    .sorted { $0.name < $1.name }
                    .map { "    \(hclStringLiteral($0.name)) = \($0.address).id" }
                    .joined(separator: "\n")
                outputs += """
                output "\(depKey)_ids" {
                  value = {
                \(pairs)
                  }
                }


                """
                if depKey == "device_group" {
                    let proPairs = entries
                        .sorted { $0.name < $1.name }
                        .map { "    \(hclStringLiteral($0.name)) = \($0.address).jamf_pro_id" }
                        .joined(separator: "\n")
                    outputs += """
                    output "device_group_jamf_pro_ids" {
                      value = {
                    \(proPairs)
                      }
                    }


                    """
                }
            }
            try Data(outputs.utf8).write(to: blockURL.appending(path: "dependency_outputs.tf"))
        }

        // Support files → files/, filtered to the ones this block references
        // (in resources or in carried variable defaults).
        let supportURL = request.sourceDirectory.appending(path: "support_files")
        if fileManager.fileExists(atPath: supportURL.path) {
            let haystack = capturedText + variables
            // Resolve symlinks on both sides: the enumerator returns
            // /private/var paths for exports under /var/folders, which would
            // never prefix-match and silently copy nothing.
            let base = supportURL.resolvingSymlinksInPath().path
            let enumerator = fileManager.enumerator(at: supportURL, includingPropertiesForKeys: [.isRegularFileKey])
            while let item = enumerator?.nextObject() as? URL {
                guard (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                let resolved = item.resolvingSymlinksInPath().path
                guard resolved.hasPrefix(base + "/") else { continue }
                let relative = String(resolved.dropFirst(base.count + 1))
                guard haystack.contains("files/\(relative)") else { continue }
                let destination = blockURL.appending(path: "files/\(relative)")
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.copyItem(at: item, to: destination)
            }
        }

        try Data("""
        terraform {
          required_providers {
            jamfplatform = {
              source = "jamf/jamfplatform"
            }
          }
        }
        """.utf8).write(to: blockURL.appending(path: "versions.tf"))

        // 4. block.json, including the permissions the export recorded.
        let permissions = parsePermissions(
            at: request.sourceDirectory.appending(path: "PERMISSIONS.md")
        )
        if permissions.isEmpty {
            warnings.append("No PERMISSIONS.md found in the export — the block lists no permissions.")
        }

        let scope: [String: Any]
        if usesJamfProScope {
            scope = ["kind": "jamfProGroup", "variable": "scope_jamf_pro_group_id", "default": "pilot"]
        } else if usesPlatformScope {
            scope = ["kind": "platformGroup", "variable": "scope_platform_group_uuid", "default": "pilot"]
        } else {
            scope = ["kind": "none"]
        }

        var metadata: [String: Any] = [
            "id": request.blockID,
            "name": request.name,
            "summary": request.summary,
            "category": "Captured",
            "version": "0.1.0",
            "rebind": request.rebind.rawValue,
            "needs": needs.mapValues { Array($0).sorted() },
            "provides": provides.mapValues { $0.map(\.name).sorted() },
            "requires": (usesJamfProScope || usesPlatformScope) ? ["foundation"] : [],
            "conflicts": [],
            "products": ["jamf-pro", "jamf-platform"],
            "permissions": permissions,
            "risk": "medium",
            "alwaysOn": false,
            "acceptsCategory": usesCategory,
            "reviewStatus": "needsReview",
            "scope": scope,
            "settings": [],
            "objectsCreated": terraformTypes.sorted().map { "1+ \($0)" },
        ]
        if let origin = request.originTenantScopeID {
            metadata["capturedFromTenant"] = origin
        }

        let json = try JSONSerialization.data(
            withJSONObject: metadata,
            options: [.prettyPrinted, .sortedKeys]
        )
        try json.write(to: blockURL.appending(path: "block.json"))

        // 5. README seeded with provenance and the secret-scan outcome.
        var readme = """
        # \(request.name)

        \(request.summary)

        Captured from a tenant export on \(Date.now.formatted(date: .abbreviated, time: .shortened)).
        **Review before use**: check names, scope and settings before deploying
        this block to other tenants.
        """
        if !request.secretFindings.isEmpty {
            readme += "\n\n## Secret scan findings\n\n"
            readme += request.secretFindings.map { "- \($0)" }.joined(separator: "\n")
            readme += "\n\nMove these values into sensitive settings before using the block."
            warnings.append("The secret scan reported findings — they are listed in the block's README and must be reviewed.")
        }
        try Data(readme.utf8).write(to: blockURL.appending(path: "README.md"))

        return Result(
            blockFolderURL: blockURL,
            objectCount: objectCount,
            usesJamfProScope: usesJamfProScope,
            usesPlatformScope: usesPlatformScope,
            warnings: warnings
        )
    }

    /// Reads the capability set out of jamformer's PERMISSIONS.md.
    /// Removes attribute objects (`foo = { … }`) and single lines that
    /// reference any of the given resource addresses.
    static func strippingReferences(to addresses: [String], in text: String) -> String {
        guard !addresses.isEmpty else { return text }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var kept: [String] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.range(of: #"^\s*[a-zA-Z0-9_]+\s*=\s*\{\s*$"#, options: .regularExpression) != nil {
                // Collect the balanced attribute object.
                var depth = 1
                var chunk = [line]
                var cursor = index
                while depth > 0, cursor + 1 < lines.count {
                    cursor += 1
                    let next = lines[cursor]
                    chunk.append(next)
                    depth += next.filter { $0 == "{" }.count - next.filter { $0 == "}" }.count
                }
                let body = chunk.joined(separator: "\n")
                if addresses.contains(where: { body.contains($0) }) {
                    index = cursor + 1
                    continue
                }
                kept.append(contentsOf: chunk)
                index = cursor + 1
                continue
            }
            if addresses.contains(where: { line.contains($0) }) {
                index += 1
                continue
            }
            kept.append(line)
            index += 1
        }
        return kept.joined(separator: "\n")
    }

    /// Builds the ID→name table from a full export directory.
    static func buildReferenceTable(exportDirectory: URL) -> ReferenceTable {
        var table = ReferenceTable()
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: exportDirectory, includingPropertiesForKeys: nil) else {
            return table
        }
        var idByAddress: [String: String] = [:]
        for file in files where file.lastPathComponent.hasSuffix("_import.tf") {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for block in ExportedObjectInventory.topLevelBlocks(in: text) {
                guard let to = block.firstMatch(of: /to = ([a-z0-9_]+\.[A-Za-z0-9_-]+)/),
                      let id = block.firstMatch(of: /id = "([^"]+)"/)
                else { continue }
                idByAddress[String(to.1)] = String(id.1)
            }
        }
        for file in files where file.lastPathComponent.hasSuffix(".tf")
            && !file.lastPathComponent.hasSuffix("_import.tf") {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for block in ExportedObjectInventory.topLevelBlocks(in: text) {
                guard let header = block.firstMatch(of: /resource\s+"([a-z0-9_]+)"\s+"([A-Za-z0-9_-]+)"/),
                      let name = block.firstMatch(of: /\n\s+name\s+= "([^"]*)"/)
                else { continue }
                let address = "\(header.1).\(header.2)"
                table.nameByAddress[address] = String(name.1)
                if let id = idByAddress[address] {
                    table.nameByTypeAndID["\(header.1)#\(id)"] = String(name.1)
                }
            }
        }
        return table
    }

    /// Rewrites hard-coded cross-object IDs into name-keyed dependency-map
    /// lookups. Returns the dependency names used, keyed by dependency type.
    static func resolveAssociations(
        in text: inout String,
        table: ReferenceTable,
        localAddresses: Set<String>,
        warnings: inout [String]
    ) -> [String: Set<String>] {
        var needs: [String: Set<String>] = [:]

        func record(_ depKey: String, _ name: String) -> String {
            // Objects captured into this same block are referenced directly.
            if let type = dependencyTypes.first(where: { $0.value == depKey })?.key,
               let address = table.nameByAddress.first(where: { $0.value == name && $0.key.hasPrefix(type + ".") })?.key,
               localAddresses.contains(address) {
                return "\(address).id"
            }
            needs[depKey, default: []].insert(name)
            return "var.dep_\(depKey)_ids[\(hclStringLiteral(name))]"
        }

        // category_id = "7" (with or without the exporter's TODO note).
        text = replacing(in: text, pattern: #"category_id\s*= "(\d+)"( # TODO: unresolved reference)?"#) { match in
            guard let name = table.name(type: "jamfplatform_pro_category", id: match[1]) else { return nil }
            return "category_id = \(record("category", name))"
        }

        // id = "12" # TODO: … inside scripts/packages containers.
        var container: [String] = []
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for index in lines.indices {
            let line = lines[index]
            if let open = line.firstMatch(of: /^\s*([a-zA-Z0-9_]+)\s*= [\[{]+\s*$/) {
                container.append(String(open.1))
            } else if line.range(of: #"^\s*[\[{]+\s*$"#, options: .regularExpression) != nil {
                container.append("")
            }
            let closers = line.filter { $0 == "}" || $0 == "]" }.count
            let openers = line.filter { $0 == "{" || $0 == "[" }.count
            if closers > openers {
                for _ in 0..<(closers - openers) where !container.isEmpty { container.removeLast() }
            }
            guard let match = line.firstMatch(of: /^(\s*)id\s+= "(\d+)" # TODO: unresolved reference/) else { continue }
            let depKey: String? = container.contains("scripts") ? "script"
                : container.contains("packages") ? "package" : nil
            guard let key = depKey,
                  let type = dependencyTypes.first(where: { $0.value == key })?.key,
                  let name = table.name(type: type, id: String(match.2))
            else {
                warnings.append("A reference to \(container.last ?? "an object") with ID \(match.2) could not be resolved to a name — review it before deploying.")
                continue
            }
            lines[index] = "\(match.1)id = \(record(key, name))"
        }
        text = lines.joined(separator: "\n")

        // Resource references to objects outside this block (the exporter
        // resolves same-run references) become name-keyed lookups too.
        for (type, depKey) in dependencyTypes {
            let pattern = "\\b(" + type + #"\.[A-Za-z0-9_-]+)\.id\b"#
            text = replacing(in: text, pattern: pattern) { match in
                let address = match[1]
                guard !localAddresses.contains(address),
                      let name = table.nameByAddress[address]
                else { return nil }
                return record(depKey, name)
            }
        }

        // Platform device-group UUID lists keep their groups by name.
        for attribute in ["target_device_groups", "device_groups"] {
            let pattern = attribute + #"\s*= \[([^\]]*)\]"#
            text = replacing(in: text, pattern: pattern) { match in
                let body = match[1]
                guard body.contains("\"") else { return nil }
                var elements: [String] = []
                var resolvedAll = true
                for element in body.matches(of: /"([0-9a-fA-F-]{36})"/) {
                    if let name = table.name(type: "jamfplatform_device_group", id: String(element.1)) {
                        elements.append(record("device_group", name))
                    } else {
                        resolvedAll = false
                    }
                }
                guard resolvedAll, !elements.isEmpty else { return nil }
                return "\(attribute) = [\(elements.joined(separator: ", "))]"
            }
        }

        return needs
    }

    /// Regex replacement with a closure; returning nil keeps the original.
    static func replacing(in text: String, pattern: String, transform: ([String]) -> String?) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed()
        for match in matches {
            var groups: [String] = []
            for group in 0..<match.numberOfRanges {
                if let range = Range(match.range(at: group), in: text) {
                    groups.append(String(text[range]))
                } else {
                    groups.append("")
                }
            }
            if let replacement = transform(groups), let full = Range(match.range, in: result) {
                result.replaceSubrange(full, with: replacement)
            }
        }
        return result
    }

    /// Simple `name = "value"` assignments from a tfvars file.
    static func parseTfvars(at url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            if let match = line.firstMatch(of: /^\s*([a-zA-Z0-9_]+)\s*=\s*"(.*)"\s*$/) {
                values[String(match.1)] = String(match.2)
            }
        }
        return values
    }

    static func hclStringLiteral(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Returns each `variable "name" { … }` declaration in a variables file,
    /// keyed by name. Missing file → empty.
    static func parseVariableDeclarations(at url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var declarations: [String: String] = [:]
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var index = 0
        while index < lines.count {
            let line = String(lines[index])
            if let match = line.firstMatch(of: /^\s*variable\s+"([a-zA-Z0-9_]+)"\s*\{/) {
                var depth = line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
                var block = [line]
                while depth > 0, index + 1 < lines.count {
                    index += 1
                    let next = String(lines[index])
                    block.append(next)
                    depth += next.filter { $0 == "{" }.count - next.filter { $0 == "}" }.count
                }
                declarations[String(match.1)] = block.joined(separator: "\n")
            }
            index += 1
        }
        return declarations
    }

    static func parsePermissions(at url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var inCodeBlock = false
        var permissions: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("```") {
                if inCodeBlock { break }
                inCodeBlock = true
                continue
            }
            if inCodeBlock {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.contains(":") { permissions.append(trimmed) }
            }
        }
        return permissions
    }
}
