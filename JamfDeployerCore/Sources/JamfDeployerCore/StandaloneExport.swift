import Foundation

/// Turns tenant workspaces into a plain Terraform repository:
///
///     modules/<block>/          each block whole, as the catalog ships it
///     tenants/<tenant>/         main.tf, variables.tf, tenant.auto.tfvars,
///                               terraform.tf, providers.tf, adopted-*.tf
///
/// Module names match the app's workspace, so a tenant's state carries over
/// unchanged. Setting values move to tenant.auto.tfvars; wiring between
/// blocks stays in main.tf; secret settings become sensitive variables the
/// pipeline supplies as TF_VAR_*.
public nonisolated enum StandaloneExport {
    /// One tenant to export.
    public struct Tenant: Sendable {
        /// Directory name under tenants/.
        public var slug: String
        public var input: WorkspaceInput
        /// Where each selection's block folder comes from, keyed by block ID.
        public var blockFolders: [String: URL]
        /// Adopted configuration files, copied into the tenant directory.
        public var adoptedFiles: [URL]

        public init(slug: String, input: WorkspaceInput, blockFolders: [String: URL], adoptedFiles: [URL] = []) {
            self.slug = slug
            self.input = input
            self.blockFolders = blockFolders
            self.adoptedFiles = adoptedFiles
        }
    }

    public enum ExportError: LocalizedError {
        case pendingRemovals(tenant: String)
        case destinationNotEmpty

        public var errorDescription: String? {
            switch self {
            case .pendingRemovals(let tenant):
                "\(tenant) has blocks waiting to be removed or a hand-over in progress. Deploy or cancel those changes first, so the export matches what is in Jamf."
            case .destinationNotEmpty:
                "Choose an empty folder for the exported repository."
            }
        }
    }

    // MARK: Names

    /// A directory name for a tenant: lowercase letters, digits and dashes,
    /// unique among `taken`.
    public static func slug(for name: String, taken: Set<String>) -> String {
        var base = ""
        for scalar in name.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII {
                base.unicodeScalars.append(scalar)
            } else if !base.hasSuffix("-") {
                base += "-"
            }
        }
        base = base.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if base.isEmpty || base == "_template" { base = "tenant" }
        var candidate = base
        var number = 2
        while taken.contains(candidate) {
            candidate = "\(base)-\(number)"
            number += 1
        }
        return candidate
    }

    /// The modules/ folder name for each block in the fleet, keyed by
    /// `folderKey`: the block ID, or ID plus version when tenants use
    /// different copies of a block (other versions, or other sources).
    public static func moduleFolders(for tenants: [Tenant]) -> [String: String] {
        var copies: [String: Set<String>] = [:]          // block ID → folder keys
        var versions: [String: String] = [:]             // folder key → version
        for tenant in tenants {
            for selection in tenant.input.selections {
                let key = folderKey(selection.block, source: tenant.blockFolders[selection.block.id])
                copies[selection.block.id, default: []].insert(key)
                versions[key] = selection.block.version
            }
        }
        var folders: [String: String] = [:]
        for (id, keys) in copies {
            guard keys.count > 1 else {
                folders[keys.first!] = id
                continue
            }
            var taken: Set<String> = []
            for key in keys.sorted() {
                var name = "\(id)-v\(versions[key] ?? "")"
                var number = 2
                while taken.contains(name) {
                    name = "\(id)-v\(versions[key] ?? "")-\(number)"
                    number += 1
                }
                taken.insert(name)
                folders[key] = name
            }
        }
        return folders
    }

    /// One copy of a block: its ID, version and the folder it comes from.
    static func folderKey(_ block: BlockMetadata, source: URL?) -> String {
        "\(block.id)@\(block.version)@\(source?.standardizedFileURL.path ?? "")"
    }

    // MARK: Tenant files

    /// The files of one tenant directory, keyed by file name.
    public static func tenantFiles(_ tenant: Tenant, moduleFolders: [String: String]) throws -> [String: String] {
        let input = tenant.input
        guard input.removals.isEmpty else { throw ExportError.pendingRemovals(tenant: tenant.slug) }
        let (calls, generatorSecrets) = try WorkspaceGenerator.moduleCalls(input)
        let blocks = Dictionary(input.selections.map { ($0.block.id, $0.block) }, uniquingKeysWith: { first, _ in first })
        let names = blocks.mapValues(\.name)
        // GitHub stores secret names in upper case and the pipeline lowers
        // them back, so secret variables are lower case here.
        let secrets = generatorSecrets.map { secret in
            var lowered = secret
            lowered.name = secret.name.lowercased()
            return lowered
        }

        // main.tf: the module calls and the wiring between them.
        let modules = calls.map { call in
            let folder = blocks[call.blockID]
                .flatMap { moduleFolders[folderKey($0, source: tenant.blockFolders[call.blockID])] } ?? call.blockID
            var pairs: [(String, String)] = [
                ("source", WorkspaceGenerator.hclString("../../modules/\(folder)" + (call.modulePath.isEmpty ? "" : "/\(call.modulePath)"))),
                ("name_prefix", "var.name_prefix"),
            ]
            for argument in call.arguments {
                switch argument.value {
                case .setting: pairs.append((argument.key, "var.\(call.name).\(argument.key)"))
                case .reference(let expression): pairs.append((argument.key, expression))
                case .secret(let variable): pairs.append((argument.key, "var.\(variable.lowercased())"))
                }
            }
            var comment = "# \(names[call.blockID] ?? call.blockID)"
            let used = Set(call.arguments.compactMap { argument -> String? in
                guard case .reference(let expression) = argument.value,
                      let match = expression.firstMatch(of: /module\.([A-Za-z0-9_]+)\./) else { return nil }
                return String(match.1)
            }).sorted()
            if !used.isEmpty {
                comment += "\n# Uses \(used.map { "module.\($0)" }.joined(separator: " and "))'s outputs, so Terraform creates that block first."
            }
            return "\(comment)\nmodule \"\(call.name)\" {\n\(WorkspaceGenerator.aligned(pairs))\n}\n"
        }
        let mainTF = """
        # This tenant's baseline. Each module block calls one building block from
        # ../../modules: `source` says which, the other arguments are its inputs.
        # `var.<block>.<setting>` values come from tenant.auto.tfvars, and
        # `module.<block>.<output>` connects one block to another. Every tenant
        # calls the same modules, so a change to a module reaches them all.


        """ + modules.joined(separator: "\n")

        // variables.tf: typed inputs, one object per block.
        var variables = [
            """
            variable "name_prefix" {
              description = "Prefix applied to every object name."
              type        = string
            }

            """,
        ]
        var values = ["name_prefix = \(WorkspaceGenerator.hclString(input.namePrefix))\n"]
        for call in calls {
            let settings = call.arguments.compactMap { argument -> (String, String, String)? in
                guard case .setting(let literal, let type) = argument.value else { return nil }
                return (argument.key, type, literal)
            }
            guard !settings.isEmpty else { continue }
            let description = WorkspaceGenerator.hclString("Settings for the \(names[call.blockID] ?? call.blockID) block.")
            variables.append("""
            variable "\(call.name)" {
              description = \(description)
              type = object({
            \(WorkspaceGenerator.aligned(settings.map { ($0.0, $0.1) }, indent: "    "))
              })
            }

            """)
            values.append("\(call.name) = {\n\(WorkspaceGenerator.aligned(settings.map { ($0.0, $0.2) }))\n}\n")
        }
        for secret in secrets {
            variables.append("""
            variable "\(secret.name)" {
              description = \(WorkspaceGenerator.hclString(secret.description))
              type        = string
              sensitive   = true
            }

            """)
        }
        let secretNote = secrets.isEmpty ? "" : """
        #
        # Secret settings are not here: they arrive as TF_VAR_<name> secrets
        # in the tenant's GitHub Environment (\(secrets.map(\.name).joined(separator: ", "))).
        """
        let variablesTF = "# The inputs main.tf uses, with their types: Terraform checks every value in\n# tenant.auto.tfvars against them before planning.\(secretNote)\n\n"
            + variables.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
        let tfvars = """
        # This tenant's settings: the file that differs between tenants. To change
        # one, edit it on a branch and open a pull request; the plan on the pull
        # request shows exactly what would change in Jamf. No secrets here:
        # credentials arrive as environment variables at run time.


        """ + values.joined(separator: "\n")

        return [
            "main.tf": mainTF,
            "variables.tf": variablesTF,
            "tenant.auto.tfvars": tfvars,
            "terraform.tf": terraformTF(input),
            "providers.tf": providersTF(input),
        ]
    }

    static func terraformTF(_ input: WorkspaceInput) -> String {
        let main = input.connection == .jamfPro
            ? ("jamfpro", "deploymenttheory/jamfpro", input.jamfProProviderVersion)
            : ("jamfplatform", "jamf/jamfplatform", input.providerVersion)
        var providers = [main]
        if needsProtect(input) {
            providers.append(("jamfprotect", "Jamf-Concepts/jamfprotect", input.protectProviderVersion))
        }
        let requirements = providers.map { name, source, version in
            """
                \(name) = {
                  source  = "\(source)"
                  version = "\(version)"
                }
            """
        }.joined(separator: "\n")
        return """
        terraform {
          required_version = ">= 1.11.0"

          required_providers {
        \(requirements)
          }

          # State lives on this repository's terraform-state branch, written by the
          # state backend the workflows start (.github/actions/state-backend). The
          # address and credentials arrive as TF_HTTP_* environment variables.
          # To use another backend, see the README.
          backend "http" {}
        }

        """
    }

    static func providersTF(_ input: WorkspaceInput) -> String {
        var text = input.connection == .jamfPro
            ? """
            # The instance URL and credentials come from JAMFPRO_* environment
            # variables at run time.
            provider "jamfpro" {
            }

            """
            : """
            # Credentials come from JAMFPLATFORM_* environment variables at run time.
            provider "jamfplatform" {
              impact_alerts = true
            }

            """
        if needsProtect(input) {
            text += """

            # Jamf Protect credentials come from JAMFPROTECT_* environment variables.
            provider "jamfprotect" {
            }

            """
        }
        return text
    }

    static func needsProtect(_ input: WorkspaceInput) -> Bool {
        input.selections.contains { $0.block.products.contains("jamf-protect") }
    }

    // MARK: Writing

    /// Writes the repository: modules/, tenants/ and the pipeline templates
    /// (the contents of `templatesURL`, copied as they are).
    public static func write(_ tenants: [Tenant], templatesURL: URL?, to destination: URL, repository: String? = nil) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path),
           !((try? fileManager.contentsOfDirectory(atPath: destination.path)) ?? []).filter({ $0 != ".DS_Store" }).isEmpty {
            throw ExportError.destinationNotEmpty
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let folders = moduleFolders(for: tenants)

        // Render everything first, so a tenant that cannot export leaves no
        // half-written repository behind.
        let rendered = try tenants.map { ($0, try tenantFiles($0, moduleFolders: folders)) }

        if let templatesURL {
            for item in try fileManager.contentsOfDirectory(atPath: templatesURL.path) where item != ".DS_Store" {
                try fileManager.copyItem(at: templatesURL.appending(path: item), to: destination.appending(path: item))
            }
        }

        try fillStatusBadges(in: destination.appending(path: "README.md"), repository: repository)

        let modulesURL = destination.appending(path: "modules")
        try fileManager.createDirectory(at: modulesURL, withIntermediateDirectories: true)
        var written: Set<String> = []
        for tenant in tenants {
            for selection in tenant.input.selections {
                let folder = folders[folderKey(selection.block, source: tenant.blockFolders[selection.block.id])] ?? selection.block.id
                guard !written.contains(folder), let source = tenant.blockFolders[selection.block.id] else { continue }
                written.insert(folder)
                let target = modulesURL.appending(path: folder)
                try fileManager.copyItem(at: source, to: target)
                try? fileManager.removeItem(at: target.appending(path: "block.json"))
            }
        }

        for (tenant, files) in rendered {
            let directory = destination.appending(path: "tenants/\(tenant.slug)")
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            for (name, contents) in files {
                try Data(contents.utf8).write(to: directory.appending(path: name), options: .atomic)
            }
            for file in tenant.adoptedFiles {
                try fileManager.copyItem(at: file, to: directory.appending(path: file.lastPathComponent))
            }
        }

        // A starting point for the next tenant (scripts/new-tenant.sh copies
        // it): the first tenant's blocks and values, without its adopted
        // objects. The workflows skip it.
        if let (first, files) = rendered.first {
            let directory = destination.appending(path: "tenants/\(templateDirectory)")
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            for (name, contents) in files {
                let text = name == "tenant.auto.tfvars"
                    ? "# A starting point for a new tenant: scripts/new-tenant.sh copies this directory.\n"
                        + "# The values are \(first.slug)'s; set the new tenant's own before opening the pull request.\n"
                        + contents
                    : contents
                try Data(text.utf8).write(to: directory.appending(path: name), options: .atomic)
            }
        }
        // Git keeps the executable bit, so the scripts run straight after cloning.
        let scripts = destination.appending(path: "scripts")
        for script in (try? fileManager.contentsOfDirectory(atPath: scripts.path)) ?? [] where script.hasSuffix(".sh") {
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scripts.appending(path: script).path)
        }
    }

    /// The README line the workflow status badges go on.
    static let badgeMarker = "<!-- status badges -->"

    /// The workflows' status badges, on the README's marker line, when the
    /// repository is on GitHub; without one (an export to review), the line
    /// goes.
    static func fillStatusBadges(in readme: URL, repository: String?) throws {
        guard let text = try? String(contentsOf: readme, encoding: .utf8), text.contains(badgeMarker) else { return }
        let badges = repository.flatMap(GitHubRepository.init(remote:)).map { github in
            [
                github.badge(title: "Apply", workflow: "apply.yml"),
                github.badge(title: "Check for changes", workflow: "drift.yml"),
                github.badge(title: "Not in code", workflow: "reconcile.yml"),
            ].joined(separator: " ") + "\n"
        } ?? ""
        let filled = badges.isEmpty
            ? text.replacingOccurrences(of: badgeMarker + "\n\n", with: "")
            : text.replacingOccurrences(of: badgeMarker + "\n", with: badges)
        try Data(filled.utf8).write(to: readme, options: .atomic)
    }

    /// The scaffold directory under tenants/ that workflows skip.
    public static let templateDirectory = "_template"

    /// State as the engine wrote it, ready for plain Terraform: each
    /// resource's provider address moves from OpenTofu's registry to
    /// Terraform's, the same as `terraform state replace-provider`. Nothing
    /// else in the state is touched.
    public static func stateForTerraform(_ state: Data) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: state) as? [String: Any] else { return state }
        if let resources = root["resources"] as? [[String: Any]] {
            root["resources"] = resources.map { resource in
                var moved = resource
                if let provider = resource["provider"] as? String {
                    moved["provider"] = provider.replacingOccurrences(
                        of: "registry.opentofu.org/", with: "registry.terraform.io/")
                }
                return moved
            }
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }
}
