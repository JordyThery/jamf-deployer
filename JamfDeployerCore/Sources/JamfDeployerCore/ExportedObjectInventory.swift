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
    static func topLevelBlocks(in text: String) -> [String] {
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
