import Foundation

/// Jamf sometimes answers a create with a server error (500, 502, 503 or
/// 504) after creating the object, so the engine records nothing and a
/// retry collides on the name. This finds those creates and turns each
/// object Jamf did create into an import block, so the next preview adopts
/// it instead of duplicating it.
public nonisolated enum CreateFailureRecovery {
    public struct Candidate: Sendable, Equatable {
        public var address: String
        public var resourceType: String
        public var name: String
    }

    /// Resource types a server error on create can leave behind, and the API
    /// call that finds one by name. A lookup that finds nothing is harmless:
    /// the next preview simply creates the object again.
    public enum Lookup: Sendable, Equatable {
        /// GET `<path><url-encoded name>` → `<root>.general.id`.
        case byName(path: String, root: String)
        /// GET `<path>` → list under `<root>`; match `name`, take `id`.
        case list(path: String, root: String, pageSize: Int? = nil)
    }

    public static let lookups: [String: Lookup] = [
        "jamfplatform_pro_policy": .byName(path: "/proclassic/policies/name/", root: "policy"),
        "jamfplatform_pro_macos_configuration_profile": .byName(
            path: "/proclassic/osxconfigurationprofiles/name/", root: "os_x_configuration_profile"),
        "jamfplatform_pro_patch_software_title": .list(
            path: "/proclassic/patchsoftwaretitles", root: "patch_software_titles"),
        "jamfplatform_pro_app_installer": .list(
            path: "/pro/v1/app-installers/deployments", root: "results", pageSize: 2000),
    ]

    /// Failed creates worth checking: a 500, 502, 503 or 504 on a recoverable type,
    /// with the planned object name taken from the approved plan.
    public static func candidates(diagnostics: [EngineStreamEvent.Diagnostic], plan: PlanFile) -> [Candidate] {
        let changes = Dictionary(
            (plan.resourceChanges ?? []).map { ($0.address, $0) },
            uniquingKeysWith: { first, _ in first })
        var result: [Candidate] = []
        for diagnostic in diagnostics where diagnostic.severity == "error" {
            guard let address = diagnostic.address,
                  diagnostic.summary.hasPrefix("Error creating"),
                  (diagnostic.detail ?? "").contains(/status 50[0234]\b/),
                  let change = changes[address],
                  change.change.actions == ["create"],
                  lookups[change.type] != nil,
                  let name = plannedName(change.change.after)
            else { continue }
            if !result.contains(where: { $0.address == address }) {
                result.append(Candidate(address: address, resourceType: change.type, name: name))
            }
        }
        return result
    }

    /// The object name in planned values: top-level `name` or `general.name`.
    static func plannedName(_ after: JSONValue?) -> String? {
        guard case .object(let values) = after else { return nil }
        if let name = values["name"]?.stringValue, !name.isEmpty { return name }
        if case .object(let general) = values["general"],
           let name = general["name"]?.stringValue, !name.isEmpty {
            return name
        }
        return nil
    }

    /// Unencoded request path for a candidate's lookup (the API client
    /// encodes it). Names containing "/" cannot be expressed as a path
    /// segment and are not looked up.
    public static func lookupPath(for candidate: Candidate) -> String? {
        switch lookups[candidate.resourceType] {
        case .byName(let path, _):
            return candidate.name.contains("/") ? nil : path + candidate.name
        case .list(let path, _, _):
            return path
        case nil:
            return nil
        }
    }

    /// Query items for a candidate's lookup (list lookups page in one go).
    public static func lookupQuery(for candidate: Candidate) -> [URLQueryItem] {
        if case .list(_, _, let pageSize?) = lookups[candidate.resourceType] {
            return [URLQueryItem(name: "page-size", value: String(pageSize))]
        }
        return []
    }

    /// IDs already tracked in the engine state, per resource type, from
    /// `tofu show -json` of the state.
    public static func managedIDs(stateJSON data: Data) -> [String: Set<String>] {
        guard let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let root = (state["values"] as? [String: Any])?["root_module"] as? [String: Any]
        else { return [:] }
        var ids: [String: Set<String>] = [:]
        func walk(_ module: [String: Any]) {
            for resource in module["resources"] as? [[String: Any]] ?? [] {
                guard let type = resource["type"] as? String,
                      let values = resource["values"] as? [String: Any] else { continue }
                if let id = values["id"] as? String { ids[type, default: []].insert(id) }
                else if let id = values["id"] as? NSNumber { ids[type, default: []].insert(id.stringValue) }
            }
            for child in module["child_modules"] as? [[String: Any]] ?? [] { walk(child) }
        }
        walk(root)
        return ids
    }

    /// The Jamf ID from a lookup response, when exactly one object with the
    /// planned name exists that the state does not already track. Duplicate
    /// names (several App Installer deployments of one title) would otherwise
    /// bind two resources to the same object.
    public static func objectID(in data: Data, for candidate: Candidate, excluding managed: Set<String> = []) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func text(_ value: Any?) -> String? {
            if let string = value as? String { return string }
            if let number = value as? NSNumber { return number.stringValue }
            return nil
        }
        switch lookups[candidate.resourceType] {
        case .byName(_, let root):
            let general = (object[root] as? [String: Any])?["general"] as? [String: Any]
            guard text(general?["name"]) == candidate.name,
                  let id = text(general?["id"]), !managed.contains(id) else { return nil }
            return id
        case .list(_, let root, _):
            let items = object[root] as? [[String: Any]] ?? []
            let matches = items
                .filter { text($0["name"]) == candidate.name }
                .compactMap { text($0["id"]) }
                .filter { !managed.contains($0) }
            return matches.count == 1 ? matches[0] : nil
        case nil:
            return nil
        }
    }

    /// Import blocks for recovered objects, as a root-level workspace file.
    public static func importFile(_ recovered: [(address: String, id: String)]) -> String {
        var text = "# Objects Jamf created even though it reported an error. The next\n# preview adopts them instead of creating duplicates.\n"
        for item in recovered.sorted(by: { $0.address < $1.address }) {
            text += """

            import {
              to = \(item.address)
              id = "\(item.id)"
            }

            """
        }
        return text
    }
}
