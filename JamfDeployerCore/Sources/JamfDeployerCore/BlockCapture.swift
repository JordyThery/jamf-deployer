import Foundation

/// Turns a jamformer export into a reusable building block:
/// names become `${var.name_prefix}…`, hard-coded group IDs become a scope
/// setting, support files move into `files/`, and block.json is written with
/// the permissions the export recorded. Captured blocks are marked
/// "Review before use" until a curator marks them reviewed.
public nonisolated enum BlockCapture {
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

        public init(
            blockID: String,
            name: String,
            summary: String,
            namePrefix: String,
            sourceDirectory: URL,
            catalogRootDirectory: URL,
            secretFindings: [String] = [],
            originTenantScopeID: String? = nil
        ) {
            self.blockID = blockID
            self.name = name
            self.summary = summary
            self.namePrefix = namePrefix
            self.sourceDirectory = sourceDirectory
            self.catalogRootDirectory = catalogRootDirectory
            self.secretFindings = secretFindings
            self.originTenantScopeID = originTenantScopeID
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

        // 1. Configuration files, transformed. provider/variables/tfvars and
        //    import blocks stay behind — a block is reusable configuration.
        let skipped: Set<String> = ["provider.tf", "variables.tf", "versions.tf", "terraform.tfvars"]
        let contents = try fileManager.contentsOfDirectory(at: request.sourceDirectory, includingPropertiesForKeys: nil)
        for file in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = file.lastPathComponent
            guard name.hasSuffix(".tf"), !skipped.contains(name), !name.hasSuffix("_import.tf") else { continue }

            var text = try String(contentsOf: file, encoding: .utf8)

            // Count objects and record their types.
            for match in text.matches(of: /resource\s+"([a-z0-9_]+)"\s+"/) {
                objectCount += 1
                terraformTypes.insert(String(match.1))
            }

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

            // Support files move into files/.
            text = text.replacingOccurrences(of: "support_files/", with: "files/")

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

            try Data(text.utf8).write(to: blockURL.appending(path: name))
            capturedText += text + "\n"
        }

        guard objectCount > 0 else {
            try? fileManager.removeItem(at: blockURL)
            throw CaptureError.nothingToCapture
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
        let generated: Set<String> = [
            "name_prefix", "managed_by_tag", "scope_jamf_pro_group_id",
            "scope_platform_group_uuid", "category_id",
        ]
        var referenced: Set<String> = []
        for match in capturedText.matches(of: /var\.([a-zA-Z0-9_]+)/) {
            referenced.insert(String(match.1))
        }
        let exportedDeclarations = parseVariableDeclarations(
            at: request.sourceDirectory.appending(path: "variables.tf")
        )
        // The exporter puts the variables' actual values in terraform.tfvars
        // (file paths for icons and similar); a reusable block needs them as
        // defaults, or the generated module call fails with "missing
        // required argument".
        let exportedValues = parseTfvars(
            at: request.sourceDirectory.appending(path: "terraform.tfvars")
        )
        for name in referenced.subtracting(generated).sorted() {
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

        try Data(variables.utf8).write(to: blockURL.appending(path: "variables.tf"))

        // Support files → files/, filtered to the ones this block references
        // (in resources or in carried variable defaults).
        let supportURL = request.sourceDirectory.appending(path: "support_files")
        if fileManager.fileExists(atPath: supportURL.path) {
            let haystack = capturedText + variables
            let enumerator = fileManager.enumerator(at: supportURL, includingPropertiesForKeys: [.isRegularFileKey])
            while let item = enumerator?.nextObject() as? URL {
                guard (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                let relative = item.path.replacingOccurrences(of: supportURL.path + "/", with: "")
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
