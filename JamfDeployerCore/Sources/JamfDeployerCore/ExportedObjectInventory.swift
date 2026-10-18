import Foundation

/// The objects inside a jamformer export, so the user can pick specific
/// objects (not just types) for capture, adopt and clone.
public nonisolated struct ExportedObject: Sendable, Identifiable, Hashable {
    /// "jamfplatform_pro_policy.jd_install_rosetta_2"
    public var address: String
    public var resourceType: String
    public var terraformName: String
    /// Human name pulled from name/display_name/title where present.
    public var displayName: String
    public var fileName: String
    /// True when the object carries a "Managed by Jamf Deployer" tag —
    /// it was created by a building block, not hand-configured.
    public var hasProvenanceTag: Bool

    public var id: String { address }
}

/// Scans and prunes exported configuration by whole resource blocks.
/// This is file surgery for the picker, not configuration parsing — the
/// engine itself never consumes these results.
public nonisolated enum ExportedObjectInventory {
    public static func scan(directory: URL) throws -> [ExportedObject] {
        var objects: [ExportedObject] = []
        for file in try configurationFiles(in: directory) {
            let text = try String(contentsOf: file, encoding: .utf8)
            for block in resourceBlocks(in: text) {
                guard let header = block.split(separator: "\n").first,
                      let match = header.firstMatch(of: /^resource\s+"([a-z0-9_]+)"\s+"([A-Za-z0-9_-]+)"/)
                else { continue }
                let type = String(match.1)
                let name = String(match.2)
                objects.append(ExportedObject(
                    address: "\(type).\(name)",
                    resourceType: type,
                    terraformName: name,
                    displayName: displayName(in: block) ?? name,
                    fileName: file.lastPathComponent,
                    hasProvenanceTag: block.contains("Managed by Jamf Deployer")
                ))
            }
        }
        return objects.sorted { $0.displayName < $1.displayName }
    }

    /// Whether a folder's configuration declares any resource — `removed`
    /// and `import` blocks alone manage nothing.
    public static func containsResources(directory: URL) -> Bool {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.contains { file in
            guard file.pathExtension == "tf",
                  let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
            return text.contains(/(?m)^resource\s+"/)
        }
    }

    /// Objects in an export the app cannot manage, with the reason: those
    /// referencing values Jamf never exports (tokens, passwords — variables
    /// with neither a default nor a tfvars value) and types the provider
    /// cannot express as exported. Adopting them would break the preview.
    public static func unmanageable(directory: URL) -> [String: String] {
        let declarations = BlockCapture.parseVariableDeclarations(at: directory.appending(path: "variables.tf"))
        let values = BlockCapture.parseTfvars(at: directory.appending(path: "terraform.tfvars"))
        func hasValue(_ name: String) -> Bool {
            if values[name] != nil { return true }
            return declarations[name]?.range(of: #"(?m)^\s*default\s*="#, options: .regularExpression) != nil
        }
        var result: [String: String] = [:]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "tf" && !file.lastPathComponent.hasSuffix("_import.tf") {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for block in topLevelBlocks(in: text) {
                guard let header = block.firstMatch(of: /resource\s+"([a-z0-9_]+)"\s+"([A-Za-z0-9_-]+)"/) else { continue }
                let address = "\(header.1).\(header.2)"
                if header.1 == "jamfplatform_pro_computer_invitation" || header.1 == "jamfplatform_pro_mobile_device_invitation" {
                    result[address] = "enrollment invitations cannot be managed as exported"
                    continue
                }
                let missing = block.matches(of: /var\.([a-zA-Z0-9_]+)/).map { String($0.1) }.filter { !hasValue($0) }
                if !missing.isEmpty {
                    result[address] = "Jamf does not export its secret values (tokens, passwords)"
                }
            }
        }
        return result
    }

    /// Replaces `var.NAME` references whose value the export supplies
    /// (terraform.tfvars, or a declared default) with that value, so adopted
    /// configuration stands alone once the export's variables.tf is dropped.
    public static func inlineVariables(directory: URL) throws {
        let declarations = BlockCapture.parseVariableDeclarations(at: directory.appending(path: "variables.tf"))
        let values = BlockCapture.parseTfvars(at: directory.appending(path: "terraform.tfvars"))
        var literal: [String: String] = [:]
        for (name, declaration) in declarations {
            if let value = values[name] {
                literal[name] = "\"\(value)\""
            } else if let match = declaration.firstMatch(of: /(?m)^\s*default\s*=\s*(.+?)\s*$/) {
                // Only single-line defaults inline; `[`, `{` or a heredoc
                // opening a multi-line value stays a variable.
                let value = String(match.1)
                let opensBlock = ["[", "{"].contains(value) || value.hasPrefix("<<")
                if !opensBlock { literal[name] = value }
            }
        }
        for (name, value) in values where literal[name] == nil { literal[name] = "\"\(value)\"" }
        guard !literal.isEmpty else { return }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "tf" && !file.lastPathComponent.hasSuffix("_import.tf")
            && !["variables.tf", "provider.tf"].contains(file.lastPathComponent) {
            let text = try String(contentsOf: file, encoding: .utf8)
            let updated = BlockCapture.replacing(in: text, pattern: #"\bvar\.([a-zA-Z0-9_]+)\b"#) { match in
                literal[match[1]]
            }
            if updated != text { try Data(updated.utf8).write(to: file) }
        }
    }

    /// Points `.id` references to objects that will not be adopted at the
    /// object's existing Jamf ID (from its import block), so adopted
    /// objects keep working when what they reference stays unmanaged. Run
    /// before `prune`, which removes those import blocks.
    public static func pinReferences(directory: URL, keeping kept: Set<String>) throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var ids: [String: String] = [:]
        for file in files where file.lastPathComponent.hasSuffix("_import.tf") {
            let text = try String(contentsOf: file, encoding: .utf8)
            for block in topLevelBlocks(in: text) {
                guard let to = block.firstMatch(of: /\bto\s*=\s*([a-z0-9_]+\.[A-Za-z0-9_-]+)/),
                      let id = block.firstMatch(of: /\bid\s*=\s*"([^"]+)"/) else { continue }
                ids[String(to.1)] = String(id.1)
            }
        }
        let leftOut = ids.filter { !kept.contains($0.key) }
        guard !leftOut.isEmpty else { return }
        for file in files where file.pathExtension == "tf" && !file.lastPathComponent.hasSuffix("_import.tf") {
            let text = try String(contentsOf: file, encoding: .utf8)
            let updated = BlockCapture.replacing(in: text, pattern: #"\b(jamfplatform_[a-z0-9_]+\.[A-Za-z0-9_-]+)\.id\b"#) { match in
                leftOut[match[1]].map { "\"\($0)\"" }
            }
            if updated != text { try Data(updated.utf8).write(to: file) }
        }
    }

    /// The objects to adopt for a selection: `kept` plus every object a kept
    /// object references by an attribute other than `.id` (a Jamf Pro ID or
    /// a name) — only `.id` can be pinned from import blocks, so those must
    /// be managed too. Objects already managed are referenced as they are.
    /// A selected object that needs one of `unavailable` (unmanageable, or
    /// managed by a block) cannot be adopted and is returned as left out.
    public static func adoptableSelection(
        directory: URL, kept: Set<String>, alreadyManaged: Set<String> = [], unavailable: Set<String> = []
    ) -> (kept: Set<String>, leftOut: Set<String>) {
        var blocks: [String: String] = [:]
        let files = (try? configurationFiles(in: directory, includeImports: false)) ?? []
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for block in topLevelBlocks(in: text) {
                guard let header = block.firstMatch(of: /^resource\s+"([a-z0-9_]+)"\s+"([A-Za-z0-9_-]+)"/) else { continue }
                blocks["\(header.1).\(header.2)"] = block
            }
        }
        func requiredReferences(of address: String) -> Set<String> {
            guard let block = blocks[address] else { return [] }
            return Set(block.matches(of: /\b(jamfplatform_[a-z0-9_]+\.[A-Za-z0-9_-]+)\.([a-z_]+)\b/)
                .filter { $0.2 != "id" }
                .map { String($0.1) }
                .filter { blocks[$0] != nil && !alreadyManaged.contains($0) })
        }
        // Everything a selected object needs, following required references
        // through objects that will be adopted with it.
        func needs(of selected: String) -> (objects: Set<String>, blocked: Bool) {
            var seen: Set<String> = [selected]
            var stack = [selected]
            while let address = stack.popLast() {
                for referenced in requiredReferences(of: address) {
                    if unavailable.contains(referenced) { return ([], true) }
                    if seen.insert(referenced).inserted { stack.append(referenced) }
                }
            }
            return (seen, false)
        }
        var result: Set<String> = []
        var leftOut: Set<String> = []
        for selected in kept {
            let (objects, blocked) = needs(of: selected)
            if blocked { leftOut.insert(selected) } else { result.formUnion(objects) }
        }
        return (result, leftOut)
    }

    /// Rewrites the export so only `keptAddresses` remain; matching import
    /// blocks follow their resources automatically.
    public static func prune(directory: URL, keeping keptAddresses: Set<String>) throws {
        for file in try configurationFiles(in: directory, includeImports: true) {
            let text = try String(contentsOf: file, encoding: .utf8)
            var kept: [String] = []
            for block in topLevelBlocks(in: text) {
                guard let header = block.split(separator: "\n").first else { continue }
                if let match = header.firstMatch(of: /^resource\s+"([a-z0-9_]+)"\s+"([A-Za-z0-9_-]+)"/) {
                    if keptAddresses.contains("\(match.1).\(match.2)") { kept.append(block) }
                } else if header.starts(with: /import\s/) {
                    // Keep the import only when its target resource stays.
                    if let target = block.firstMatch(of: /to\s*=\s*([a-z0-9_]+\.[A-Za-z0-9_-]+)/),
                       keptAddresses.contains(String(target.1)) {
                        kept.append(block)
                    }
                } else {
                    kept.append(block)
                }
            }
            if kept.isEmpty {
                try FileManager.default.removeItem(at: file)
            } else {
                try Data((kept.joined(separator: "\n\n") + "\n").utf8).write(to: file)
            }
        }
    }

    /// jamformer emits Terraform-style identity imports
    /// (`identity = { id = "13" }`); the provider's identity-import path
    /// returns no state under OpenTofu, so they are rewritten to the
    /// documented string-ID form (`id = "13"`).
    public static func normalizeImportBlocks(directory: URL) throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix("_import.tf") }
        for file in files {
            var text = try String(contentsOf: file, encoding: .utf8)
            text = text.replacingOccurrences(
                of: #"identity\s*=\s*\{\s*id\s*=\s*"([^"]+)"\s*\}"#,
                with: "id = \"$1\"",
                options: .regularExpression
            )
            // The workspace defines the provider itself.
            text = text.replacingOccurrences(of: "  provider = jamfplatform\n\n", with: "")
            text = text.replacingOccurrences(of: "  provider = jamfplatform\n", with: "")
            try Data(text.utf8).write(to: file)
        }
    }

    /// PreStage sections the exporter can leave out (device naming,
    /// purchasing, location, account settings, Setup Assistant skips) would
    /// be cleared by the first deploy after adoption. They are ignored
    /// instead, so the values in Jamf stay as they are.
    static let omittablePreStageSections: [String: [String]] = [
        "jamfplatform_pro_computer_prestage_enrollment": ["account_settings", "location_information", "purchasing_information", "skip_setup_items"],
        "jamfplatform_pro_mobile_device_prestage_enrollment": ["location_information", "names", "purchasing_information", "skip_setup_items"],
    ]

    public static func protectOmittedSections(directory: URL) throws {
        for file in try configurationFiles(in: directory) {
            let text = try String(contentsOf: file, encoding: .utf8)
            guard omittablePreStageSections.keys.contains(where: { text.contains("resource \"\($0)\"") }) else { continue }
            let blocks = topLevelBlocks(in: text).map { block -> String in
                guard let header = block.firstMatch(of: /^resource\s+"([a-z0-9_]+)"/),
                      let sections = omittablePreStageSections[String(header.1)],
                      !block.contains("\n  lifecycle {")
                else { return block }
                let missing = sections.filter {
                    block.range(of: "\\n  \($0)\\s+=", options: .regularExpression) == nil
                }
                guard !missing.isEmpty, let close = block.range(of: "}", options: .backwards) else { return block }
                return block[..<close.lowerBound]
                    + "\n  lifecycle {\n    ignore_changes = [\(missing.joined(separator: ", "))]\n  }\n}"
            }
            try Data((blocks.joined(separator: "\n\n") + "\n").utf8).write(to: file)
        }
    }

    // MARK: Scanning helpers

    static func configurationFiles(in directory: URL, includeImports: Bool = false) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "tf" }
            .filter { !["provider.tf", "variables.tf", "versions.tf"].contains($0.lastPathComponent) }
            .filter { includeImports || !$0.lastPathComponent.hasSuffix("_import.tf") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func resourceBlocks(in text: String) -> [String] {
        topLevelBlocks(in: text).filter { $0.hasPrefix("resource") }
    }

    /// Splits a file into top-level `xxx { … }` blocks by brace counting.
    public static func topLevelBlocks(in text: String) -> [String] {
        var blocks: [String] = []
        var current: [Substring] = []
        var depth = 0
        var inBlock = false

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if !inBlock {
                guard line.first?.isLetter == true else { continue }
                inBlock = true
                current = [line]
                depth = braceDelta(line)
                if depth <= 0 && line.contains("{") {
                    blocks.append(current.joined(separator: "\n"))
                    inBlock = false
                }
                continue
            }
            current.append(line)
            depth += braceDelta(line)
            if depth <= 0 {
                blocks.append(current.joined(separator: "\n"))
                current = []
                inBlock = false
            }
        }
        if inBlock && !current.isEmpty {
            blocks.append(current.joined(separator: "\n"))
        }
        return blocks
    }

    static func braceDelta(_ line: Substring) -> Int {
        // Quoted braces are rare in exports and harmless for this purpose.
        line.reduce(0) { count, character in
            count + (character == "{" ? 1 : character == "}" ? -1 : 0)
        }
    }

    static func displayName(in block: String) -> String? {
        for key in ["display_name", "name", "title"] {
            for line in block.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix(key) else { continue }
                let rest = trimmed.dropFirst(key.count)
                guard let first = rest.first, first == " " || first == "=" else { continue }
                guard let range = rest.range(of: #"=\s*"([^"]*)""#, options: .regularExpression) else { continue }
                let value = rest[range].drop { $0 != "\"" }.dropFirst().dropLast()
                return String(value)
            }
        }
        return nil
    }
}
