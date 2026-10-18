import Foundation

/// As-built documentation generated from an export: every object, grouped
/// by area, in Markdown (HTML-ready via the same structure).
///
/// This reads the exported configuration *as documentation* — a light scan
/// for resource headers and display names, not a configuration parser (the
/// engine never consumes this).
public nonisolated enum AsBuiltReport {
    public struct Input: Sendable {
        public var tenantName: String
        public var exportDirectory: URL
        public var date: Date
        public var appVersion: String

        public init(tenantName: String, exportDirectory: URL, date: Date = .now, appVersion: String) {
            self.tenantName = tenantName
            self.exportDirectory = exportDirectory
            self.date = date
            self.appVersion = appVersion
        }
    }

    struct DocumentedObject {
        var resourceType: String
        var name: String
        var details: [String]
    }

    public static func markdown(_ input: Input) throws -> String {
        let fileManager = FileManager.default
        let files = (try fileManager.contentsOfDirectory(at: input.exportDirectory, includingPropertiesForKeys: nil))
            .filter { $0.pathExtension == "tf" && !$0.lastPathComponent.hasSuffix("_import.tf") }
            .filter { !["provider.tf", "variables.tf", "versions.tf"].contains($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var sections: [String: [DocumentedObject]] = [:]
        for file in files {
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            for object in scan(text) {
                sections[area(for: object.resourceType), default: []].append(object)
            }
        }

        var lines: [String] = []
        lines.append("# As-built — \(input.tenantName)")
        lines.append("")
        lines.append("Generated \(input.date.formatted(date: .long, time: .shortened)) by Jamf Deployer \(input.appVersion).")
        let total = sections.values.map(\.count).reduce(0, +)
        lines.append("")
        lines.append("**\(total) object\(total == 1 ? "" : "s")** across \(sections.count) area\(sections.count == 1 ? "" : "s").")

        for areaName in sections.keys.sorted() {
            lines.append("")
            lines.append("## \(areaName)")
            for object in sections[areaName]!.sorted(by: { $0.name < $1.name }) {
                lines.append("")
                lines.append("### \(object.name)")
                lines.append("")
                lines.append("- Type: `\(object.resourceType)`")
                for detail in object.details {
                    lines.append("- \(detail)")
                }
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// One pass over a file: resource headers, then the human-relevant
    /// single-line attributes inside each.
    static func scan(_ text: String) -> [DocumentedObject] {
        var objects: [DocumentedObject] = []
        var current: DocumentedObject?

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let match = line.firstMatch(of: /^resource\s+"([a-z0-9_]+)"\s+"[^"]+"/) {
                if let finished = current { objects.append(finished) }
                current = DocumentedObject(resourceType: String(match.1), name: "(unnamed)", details: [])
                continue
            }
            guard current != nil else { continue }

            func quoted(_ key: String) -> String? {
                guard line.hasPrefix(key) else { return nil }
                let rest = line.dropFirst(key.count)
                guard let first = rest.first, first == " " || first == "=" else { return nil }
                let afterEquals = rest.drop { $0 == " " }
                guard afterEquals.hasPrefix("=") else { return nil }
                let value = afterEquals.dropFirst().trimmingCharacters(in: .whitespaces)
                guard value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 else { return nil }
                return String(value.dropFirst().dropLast())
            }
            if let name = quoted("name") ?? quoted("display_name") ?? quoted("title") {
                if current?.name == "(unnamed)" { current?.name = name }
            }
            for key in ["frequency", "enforcement_mode", "deployment_type", "update_behavior", "key_type", "priority"] {
                if let value = quoted(key) {
                    current?.details.append("\(key.replacingOccurrences(of: "_", with: " ").capitalized): \(value)")
                }
            }
            if line.contains("computer_group_ids") || line.contains("smart_group_id")
                || line.contains("target_device_groups") || line.contains("device_groups") {
                current?.details.append("Scoped: `\(line)`")
            }
        }
        if let finished = current { objects.append(finished) }
        return objects
    }

    static func area(for resourceType: String) -> String {
        switch true {
        case resourceType.contains("policy"), resourceType.contains("script"):
            "Policies and scripts"
        case resourceType.contains("group"):
            "Device groups"
        case resourceType.contains("category"), resourceType.contains("extension_attribute"), resourceType.contains("site"):
            "Organization"
        case resourceType.contains("prestage"), resourceType.contains("enrollment"):
            "Enrollment"
        case resourceType.contains("configuration_profile"), resourceType.contains("disk_encryption"):
            "Configuration and security"
        case resourceType.contains("blueprint"), resourceType.contains("cbengine"):
            "Declarative management and compliance"
        case resourceType.contains("app_installer"), resourceType.contains("app"):
            "Applications"
        default:
            "Other"
        }
    }
}
