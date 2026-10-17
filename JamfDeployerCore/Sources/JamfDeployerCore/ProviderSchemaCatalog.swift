import Foundation

/// A parsed view of `tofu providers schema -json`, powering the override
/// editor: resource types, their writable attributes, types and docs.
public nonisolated struct ProviderSchemaCatalog: Sendable {
    public struct Attribute: Sendable, Identifiable {
        public enum Kind: Sendable, Equatable {
            case string
            case bool
            case number
            case stringList
            case complex(String)
        }

        public var name: String
        public var kind: Kind
        public var required: Bool
        public var optional: Bool
        public var computed: Bool
        public var sensitive: Bool
        public var description: String

        public var id: String { name }

        /// Attributes a user can set (computed-only ones are read-only).
        public var isWritable: Bool { required || optional }

        public var isEditablePrimitive: Bool {
            if case .complex = kind { return false }
            // Sensitive values would end up as plaintext in synced HCL;
            // they stay out of the form by design.
            return isWritable && !sensitive
        }
    }

    public struct ResourceType: Sendable, Identifiable {
        public var name: String
        public var providerAddress: String
        public var attributes: [Attribute]

        public var id: String { name }

        public var requiredPrimitives: [Attribute] {
            attributes.filter { $0.required && $0.isEditablePrimitive }
        }

        public var optionalPrimitives: [Attribute] {
            attributes.filter { $0.optional && !$0.required && $0.isEditablePrimitive }
        }

        public var complexWritables: [Attribute] {
            attributes.filter { $0.isWritable && !$0.isEditablePrimitive }
        }

        /// A resource is editor-friendly when every required attribute is a
        /// primitive the form can render.
        public var isFormEditable: Bool {
            attributes.filter(\.required).allSatisfy(\.isEditablePrimitive)
        }
    }

    public var resourceTypes: [ResourceType]

    public func resourceType(named name: String) -> ResourceType? {
        resourceTypes.first { $0.name == name }
    }

    public static func parse(schemaJSON: Data) throws -> ProviderSchemaCatalog {
        guard let root = try JSONSerialization.jsonObject(with: schemaJSON) as? [String: Any],
              let schemas = root["provider_schemas"] as? [String: Any]
        else {
            throw CocoaError(.coderReadCorrupt)
        }

        var types: [ResourceType] = []
        for (providerAddress, value) in schemas {
            guard let provider = value as? [String: Any],
                  let resources = provider["resource_schemas"] as? [String: Any] else { continue }
            for (resourceName, resourceValue) in resources {
                guard let resource = resourceValue as? [String: Any],
                      let block = resource["block"] as? [String: Any] else { continue }
                var attributes: [Attribute] = []
                for (attributeName, attributeValue) in (block["attributes"] as? [String: Any]) ?? [:] {
                    guard let attribute = attributeValue as? [String: Any] else { continue }
                    attributes.append(Attribute(
                        name: attributeName,
                        kind: kind(of: attribute),
                        required: attribute["required"] as? Bool ?? false,
                        optional: attribute["optional"] as? Bool ?? false,
                        computed: attribute["computed"] as? Bool ?? false,
                        sensitive: attribute["sensitive"] as? Bool ?? false,
                        description: attribute["description"] as? String ?? ""
                    ))
                }
                // Nested block types count as complex writables.
                for (blockName, _) in (block["block_types"] as? [String: Any]) ?? [:] {
                    attributes.append(Attribute(
                        name: blockName,
                        kind: .complex("block"),
                        required: false,
                        optional: true,
                        computed: false,
                        sensitive: false,
                        description: ""
                    ))
                }
                types.append(ResourceType(
                    name: resourceName,
                    providerAddress: providerAddress,
                    attributes: attributes.sorted {
                        ($0.required ? 0 : 1, $0.name) < ($1.required ? 0 : 1, $1.name)
                    }
                ))
            }
        }
        return ProviderSchemaCatalog(resourceTypes: types.sorted { $0.name < $1.name })
    }

    static func kind(of attribute: [String: Any]) -> Attribute.Kind {
        if attribute["nested_type"] != nil { return .complex("object") }
        switch attribute["type"] {
        case let simple as String:
            switch simple {
            case "string": return .string
            case "bool": return .bool
            case "number": return .number
            default: return .complex(simple)
            }
        case let compound as [Any]:
            if compound.count == 2,
               let container = compound[0] as? String,
               ["list", "set"].contains(container),
               let element = compound[1] as? String, element == "string" {
                return .stringList
            }
            return .complex((compound.first as? String) ?? "compound")
        default:
            return .complex("unknown")
        }
    }
}

/// Renders a single-resource override file from editor values.
public nonisolated enum OverrideGenerator {
    public static func hcl(
        resourceType: String,
        terraformName: String,
        values: [(attribute: ProviderSchemaCatalog.Attribute, rawValue: String)]
    ) -> String {
        var lines = ["resource \"\(resourceType)\" \"\(terraformName)\" {"]
        for (attribute, raw) in values where !raw.isEmpty || attribute.required {
            switch attribute.kind {
            case .string:
                lines.append("  \(attribute.name) = \(WorkspaceGenerator.hclString(raw))")
            case .bool:
                lines.append("  \(attribute.name) = \(raw == "true" ? "true" : "false")")
            case .number:
                lines.append("  \(attribute.name) = \(raw.isEmpty ? "0" : raw)")
            case .stringList:
                let items = raw.split(separator: ",").map {
                    WorkspaceGenerator.hclString($0.trimmingCharacters(in: .whitespaces))
                }
                lines.append("  \(attribute.name) = [\(items.joined(separator: ", "))]")
            case .complex:
                continue
            }
        }
        lines.append("}")
        return lines.joined(separator: "\n") + "\n"
    }
}
