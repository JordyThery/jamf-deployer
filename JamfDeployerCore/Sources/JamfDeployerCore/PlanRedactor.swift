import Foundation

/// Removes sensitive values from `tofu show -json` output before it is kept
/// as deploy history. The engine prints sensitive input variables and
/// sensitive resource attributes in clear text; its own sensitivity markers
/// (`configuration…variables.<name>.sensitive`, `sensitive_values`,
/// `before_sensitive`, `after_sensitive`) say which ones to mask.
public nonisolated enum PlanRedactor {
    public static let placeholder = "(sensitive)"

    public static func redact(_ data: Data) -> Data? {
        guard var plan = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }

        // Input variables marked sensitive in the root module.
        let configuredVariables = ((plan["configuration"] as? [String: Any])?["root_module"] as? [String: Any])?["variables"] as? [String: Any] ?? [:]
        if var variables = plan["variables"] as? [String: Any] {
            for (name, value) in variables {
                let declaredSensitive = (configuredVariables[name] as? [String: Any])?["sensitive"] as? Bool ?? false
                if declaredSensitive, var entry = value as? [String: Any] {
                    entry["value"] = placeholder
                    variables[name] = entry
                }
            }
            plan["variables"] = variables
        }

        // Resource changes carry before/after values with parallel masks.
        if let changes = plan["resource_changes"] as? [[String: Any]] {
            plan["resource_changes"] = changes.map { change in
                var change = change
                guard var detail = change["change"] as? [String: Any] else { return change }
                for (valueKey, maskKey) in [("before", "before_sensitive"), ("after", "after_sensitive")] {
                    if let value = detail[valueKey], let mask = detail[maskKey] {
                        detail[valueKey] = masked(value, mask)
                    }
                }
                change["change"] = detail
                return change
            }
        }

        // Planned values and prior state: modules of resources with
        // `values` + `sensitive_values`.
        if let planned = plan["planned_values"] as? [String: Any] {
            plan["planned_values"] = redactModuleTree(planned)
        }
        if var prior = plan["prior_state"] as? [String: Any],
           let values = prior["values"] as? [String: Any] {
            prior["values"] = redactModuleTree(values)
            plan["prior_state"] = prior
        }

        // Output changes mark whole outputs sensitive.
        if var outputs = plan["output_changes"] as? [String: Any] {
            for (name, value) in outputs {
                guard var detail = (value as? [String: Any])?["change"] as? [String: Any] ?? (value as? [String: Any]) else { continue }
                for (valueKey, maskKey) in [("before", "before_sensitive"), ("after", "after_sensitive")] {
                    if let v = detail[valueKey], let mask = detail[maskKey] {
                        detail[valueKey] = masked(v, mask)
                    }
                }
                outputs[name] = detail
            }
            plan["output_changes"] = outputs
        }

        return try? JSONSerialization.data(withJSONObject: plan, options: [.sortedKeys])
    }

    private static func redactModuleTree(_ tree: [String: Any]) -> [String: Any] {
        var tree = tree
        if var root = tree["root_module"] as? [String: Any] {
            root = redactModule(root)
            tree["root_module"] = root
        }
        if var outputs = tree["outputs"] as? [String: Any] {
            for (name, value) in outputs {
                if var output = value as? [String: Any], output["sensitive"] as? Bool == true {
                    output["value"] = placeholder
                    outputs[name] = output
                }
            }
            tree["outputs"] = outputs
        }
        return tree
    }

    private static func redactModule(_ module: [String: Any]) -> [String: Any] {
        var module = module
        if let resources = module["resources"] as? [[String: Any]] {
            module["resources"] = resources.map { resource in
                var resource = resource
                if let values = resource["values"], let mask = resource["sensitive_values"] {
                    resource["values"] = masked(values, mask)
                }
                return resource
            }
        }
        if let children = module["child_modules"] as? [[String: Any]] {
            module["child_modules"] = children.map(redactModule)
        }
        return module
    }

    /// Applies an engine sensitivity mask: `true` hides the value; objects
    /// and arrays recurse in parallel.
    static func masked(_ value: Any, _ mask: Any) -> Any {
        if let flag = mask as? Bool {
            return flag && !(value is NSNull) ? placeholder : value
        }
        if let maskObject = mask as? [String: Any], var object = value as? [String: Any] {
            for (key, submask) in maskObject {
                if let subvalue = object[key] {
                    object[key] = masked(subvalue, submask)
                }
            }
            return object
        }
        if let maskArray = mask as? [Any], var array = value as? [Any] {
            for index in array.indices where index < maskArray.count {
                array[index] = masked(array[index], maskArray[index])
            }
            return array
        }
        return value
    }
}
