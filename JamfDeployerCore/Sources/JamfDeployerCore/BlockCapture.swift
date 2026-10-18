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
        /// Scope and category become settings chosen on each tenant: right
        /// for publishing small portable blocks.
        case perTenant
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
        "jamfplatform_pro_computer_extension_attribute": "extension_attribute",
        "jamfplatform_pro_enrollment_customization": "enrollment_customization",
    ]

    /// Exported types that can never deploy into another tenant; captured
    /// blocks leave them out with a warning.
    /// Device groups Jamf creates itself: the All Managed groups in every
    /// tenant, and the Device Compliance group when that integration is on.
    /// They are looked up by name instead of captured.
    static func isBuiltinGroupName(_ name: String) -> Bool {
        name.hasPrefix("All Managed ") || name == "Jamf Device Compliance Group"
    }

    static let unportableTypes: [String: String] = [
        "jamfplatform_pro_computer_invitation":
            "enrollment invitations are tenant-specific and expire",
        "jamfplatform_pro_mobile_device_invitation":
            "enrollment invitations are tenant-specific and expire",
        "jamfplatform_pro_allowed_file_extension":
            "Jamf creates the default allowed file extensions in every tenant",
        "jamfplatform_pro_cloud_distribution_point":
            "every Jamf cloud tenant already has its cloud distribution point configured",
        "jamfplatform_cbengine_benchmark":
            "compliance benchmarks build on a source baseline Jamf does not export — recreate them from the benchmark catalog",
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
        /// The block takes a mobile device group chosen per tenant.
        public var usesJamfProMobileScope: Bool = false
        /// The block takes a category chosen per tenant.
        public var usesCategory: Bool = false
        public var warnings: [String]
    }

    public enum CaptureError: LocalizedError {
        /// Carries the reasons objects were left out, when there were any.
        case nothingToCapture(reasons: [String] = [])
        case invalidBlockID

        public var errorDescription: String? {
            switch self {
            case .nothingToCapture(let reasons) where !reasons.isEmpty:
                "Nothing in this export can be captured. " + reasons.joined(separator: " ")
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
        var usesJamfProMobileScope = false
        var usesCategory = false
        var terraformTypes: Set<String> = []
        var typeCounts: [String: Int] = [:]
        var singletonTypes: Set<String> = []
        var capturedText = ""
        var fileTexts: [(name: String, text: String)] = []
        var needs: [String: Set<String>] = [:]
        var builtinGroupNames: Set<String> = []
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
        // Resources the transforms below leave out must not count as local,
        // or references in files processed earlier would miss their rewrite.
        localAddresses = localAddresses.filter { address in
            let type = String(address.split(separator: ".").first ?? "")
            if Self.unportableTypes.keys.contains(type) { return false }
            if type == "jamfplatform_device_group",
               table.nameByAddress[address].map(Self.isBuiltinGroupName) == true { return false }
            if type == "jamfplatform_pro_computer_extension_attribute",
               let name = table.nameByAddress[address]?.lowercased(),
               name.hasPrefix("jamf patch ") || name.hasPrefix("jamf-patch-") { return false }
            return true
        }

        // PreStages attach to the tenant's Automated Device Enrollment
        // instance; the origin's instance never exists elsewhere, so the
        // reference becomes a name-based lookup of the deploying tenant's
        // instance (name captured as an editable block setting).
        var adeReferenced = false
        var adeAddresses: Set<String> = []
        // App Store apps license through the tenant's Apps and Books
        // location; like the ADE instance, it is found by name.
        var vppReferenced = false
        var vppLocationName: String?
        var adeInstanceName: String?

        // Whether any object scopes computer groups; decides which scope a
        // per-tenant capture collapses when both kinds are present.
        let exportScopesComputers = ((try? fileManager.contentsOfDirectory(
            at: request.sourceDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "tf" && !$0.lastPathComponent.hasSuffix("_import.tf") }
            .contains { file in
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
                return text.range(of: #"(computer_group_ids\s*=\s*\[[^\]]*("\d+"|jamfplatform_device_group\.)|smart_group_id\s*=\s*("\d+"|jamfplatform_device_group\.))"#,
                                  options: .regularExpression) != nil
            }
        var mobileScopeKept = false

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

            // Objects that cannot deploy into another tenant are left out.
            for (type, reason) in Self.unportableTypes where text.contains("resource \"\(type)\"") {
                let blocks = ExportedObjectInventory.topLevelBlocks(in: text)
                let kept = blocks.filter { !$0.hasPrefix("resource \"\(type)\"") }
                let dropped = blocks.count - kept.count
                guard dropped > 0 else { continue }
                text = kept.isEmpty ? "" : kept.joined(separator: "\n\n") + "\n"
                warnings.append("Left out \(dropped) object\(dropped == 1 ? "" : "s") from \(name): \(reason).")
            }

            // Objects Jamf derives from other objects are left out too:
            // built-in device groups exist in every tenant (references
            // resolve by lookup), patch titles create their own "Jamf Patch"
            // reporting attributes, and a login page without the disclaimer
            // fields Jamf leaves out of exports cannot apply.
            if text.contains("resource \"jamfplatform_device_group\"")
                || text.contains("resource \"jamfplatform_pro_computer_extension_attribute\"")
                || text.contains("resource \"jamfplatform_pro_login_page_settings\"") {
                let blocks = ExportedObjectInventory.topLevelBlocks(in: text)
                var builtinDropped = 0
                var patchDropped = 0
                var kept: [String] = []
                for block in blocks {
                    func dropAddress() {
                        if let header = block.firstMatch(of: /resource\s+"([a-z0-9_]+)"\s+"([A-Za-z0-9_-]+)"/) {
                            localAddresses.remove("\(header.1).\(header.2)")
                        }
                    }
                    if block.hasPrefix("resource \"jamfplatform_device_group\""),
                       let groupName = block.firstMatch(of: /\n\s+name\s+= "([^"]*)"/).map({ String($0.1) }),
                       Self.isBuiltinGroupName(groupName) {
                        builtinDropped += 1
                        dropAddress()
                        continue
                    }
                    if block.hasPrefix("resource \"jamfplatform_pro_computer_extension_attribute\""),
                       block.range(of: #"\n\s+name\s+= "jamf[- ]patch[- ]"#, options: [.regularExpression, .caseInsensitive]) != nil {
                        patchDropped += 1
                        dropAddress()
                        continue
                    }
                    if block.hasPrefix("resource \"jamfplatform_pro_login_page_settings\""),
                       !block.contains("disclaimer_heading") {
                        warnings.append("Left out the login page settings: Jamf does not export the required disclaimer text. Configure the login page by hand after deploying.")
                        dropAddress()
                        continue
                    }
                    kept.append(block)
                }
                if kept.count != blocks.count {
                    text = kept.isEmpty ? "" : kept.joined(separator: "\n\n") + "\n"
                }
                if builtinDropped > 0 {
                    warnings.append("Left out \(builtinDropped) built-in device group\(builtinDropped == 1 ? "" : "s"): Jamf creates these groups itself (the All Managed groups in every tenant, the Device Compliance group when that integration is on), so references find them by name.")
                }
                if patchDropped > 0 {
                    warnings.append("Left out \(patchDropped) Jamf Patch extension attribute\(patchDropped == 1 ? "" : "s"): patch software titles recreate their own reporting attributes.")
                }
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            text = replacing(in: text, pattern: #"\bjamfplatform_pro_automated_device_enrollment\.([A-Za-z0-9_-]+)\.id\b"#) { match in
                adeReferenced = true
                adeAddresses.insert(match[1])
                if adeInstanceName == nil {
                    adeInstanceName = table.nameByAddress["jamfplatform_pro_automated_device_enrollment.\(match[1])"]
                }
                return "data.jamfplatform_pro_automated_device_enrollment.instance.id"
            }

            text = replacing(in: text, pattern: #"\bvpp_admin_account_id(\s*)= (?:"(\d+)"|jamfplatform_pro_volume_purchasing_location\.([A-Za-z0-9_-]+)\.id)"#) { match in
                if !match[2].isEmpty, match[2] == "-1" || match[2] == "0" { return nil }
                vppReferenced = true
                if vppLocationName == nil {
                    vppLocationName = !match[3].isEmpty
                        ? table.nameByAddress["jamfplatform_pro_volume_purchasing_location.\(match[3])"]
                        : table.name(type: "jamfplatform_pro_volume_purchasing_location", id: match[2])
                }
                return "vpp_admin_account_id\(match[1])= data.jamfplatform_pro_volume_purchasing_location.apps_and_books.id"
            }

            // Jamf never exports Recovery Lock passwords; a PreStage that
            // enables Recovery Lock without a non-empty one cannot be created.
            if text.contains("prestage_enrollment") {
                var turnedOff = 0
                let blocks = ExportedObjectInventory.topLevelBlocks(in: text).map { block -> String in
                    guard block.range(of: #"enable_recovery_lock\s*=\s*true"#, options: .regularExpression) != nil,
                          block.range(of: #"\brecovery_lock_password\s*=\s*"[^"]+""#, options: .regularExpression) == nil
                    else { return block }
                    turnedOff += 1
                    return block.replacingOccurrences(
                        of: #"(enable_recovery_lock\s*=\s*)true"#, with: "$1false", options: .regularExpression)
                }
                if turnedOff > 0 {
                    text = blocks.joined(separator: "\n\n") + "\n"
                    warnings.append("Recovery Lock was turned off in \(name): Jamf does not export Recovery Lock passwords. Re-enable it with a password after deploying.")
                }
            }

            // Name prefix: every quoted string that starts with the tenant's
            // prefix becomes "${var.name_prefix}…".
            if !request.namePrefix.isEmpty {
                text = text.replacingOccurrences(
                    of: "\"\(request.namePrefix)",
                    with: "\"${var.name_prefix}"
                )
            }

            if request.prefixAllNames {
                // Prefix every object name that is not already parameterized.
                // Names can sit at any nesting depth (policies name inside
                // general, packages use display_name).
                text = text.replacingOccurrences(
                    of: #"(\n\s+(?:display_)?name\s+= ")(?!\$\{var\.name_prefix\})"#,
                    with: "$1${var.name_prefix}",
                    options: .regularExpression
                )
            }

            // Icon IDs never match across tenants and the icon files are not
            // exportable; the server would silently drop the reference and the
            // provider would report an inconsistent result on every apply.
            if text.range(of: #"\n\s*self_service_icon\s*= \{[^{}]*\}"#, options: .regularExpression) != nil {
                text = text.replacingOccurrences(
                    of: #"\n\s*self_service_icon\s*= \{[^{}]*\}"#,
                    with: "",
                    options: .regularExpression
                )
                warnings.append("Left out Self Service icon references in \(name): icons do not transfer between tenants. Set icons by hand after deploying.")
            }

            // Jamf trims trailing whitespace on descriptions; keeping it makes
            // the provider report an inconsistent result after apply.
            text = replacing(in: text, pattern: #"(description\s+= ")([^"]*[^ "\t])?[ \t]+(")"#) { match in
                "\(match[1])\(match[2])\(match[3])"
            }

            // Support files move into files/.
            text = text.replacingOccurrences(of: "support_files/", with: "files/")

            // jamfplatform 1.5.0: profiles installed automatically carry a
            // vestigial self_service block whose computed attributes the
            // provider returns as unknown after apply — drop the block.
            if text.contains("jamfplatform_pro_macos_configuration_profile") {
                let resourceBlocks = ExportedObjectInventory.topLevelBlocks(in: text)
                var rebuilt: [String] = []
                for var block in resourceBlocks {
                    if block.contains(#"distribution_method = "Install Automatically""#),
                       block.contains("self_service = {") {
                        block = strippingAttributeObject(named: "self_service", from: block)
                    }
                    rebuilt.append(block)
                }
                text = rebuilt.joined(separator: "\n\n") + "\n"
            }

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

            if request.rebind == .perTenant {
                // Scope group IDs collapse to the block's scope setting and
                // categories to its category variable (chosen per tenant;
                // "-1" = none). Both the
                // numeric form jamformer writes for unresolved references and
                // the resource-reference form it writes for same-run objects
                // are covered; everything else keeps its wiring below.
                enum Rebind { case jamfPro, platform, category, jamfProMobile }
                var scopeRewrites: [(pattern: String, replacement: String, kind: Rebind)] = [
                    (#"mobile_device_group_ids\s*=\s*\[[^\]]*"\d+"[^\]]*\]"#,
                     "mobile_device_group_ids = [var.scope_jamf_pro_mobile_group_id]", .jamfProMobile),
                    (#"mobile_device_group_ids\s*=\s*\[[^\]]*jamfplatform_device_group\.[^\]]*\]"#,
                     "mobile_device_group_ids = [var.scope_jamf_pro_mobile_group_id]", .jamfProMobile),
                    (#"computer_group_ids\s*=\s*\[[^\]]*"\d+"[^\]]*\]"#,
                     "computer_group_ids = [var.scope_jamf_pro_group_id]", .jamfPro),
                    (#"computer_group_ids\s*=\s*\[[^\]]*jamfplatform_device_group\.[^\]]*\]"#,
                     "computer_group_ids = [var.scope_jamf_pro_group_id]", .jamfPro),
                    (#"smart_group_id\s*=\s*"\d+""#,
                     "smart_group_id = var.scope_jamf_pro_group_id", .jamfPro),
                    (#"smart_group_id\s*=\s*jamfplatform_device_group\.[A-Za-z0-9_-]+\.jamf_pro_id"#,
                     "smart_group_id = var.scope_jamf_pro_group_id", .jamfPro),
                    (#"category_id\s*=\s*"\d+"( # TODO: unresolved reference)?"#,
                     "category_id = var.category_id", .category),
                    (#"category_id\s*=\s*jamfplatform_pro_category\.[A-Za-z0-9_-]+\.id"#,
                     "category_id = var.category_id", .category),
                    (#"target_device_groups\s*=\s*\[[^\]]*"[0-9a-f-]{36}"[^\]]*\]"#,
                     "target_device_groups = [var.scope_platform_group_uuid]", .platform),
                    (#"target_device_groups\s*=\s*\[[^\]]*jamfplatform_device_group\.[^\]]*\]"#,
                     "target_device_groups = [var.scope_platform_group_uuid]", .platform),
                ]
                // A block has one per-tenant scope: with computer objects in
                // the export, mobile scopes keep their captured wiring.
                if exportScopesComputers {
                    scopeRewrites.removeAll { $0.kind == .jamfProMobile }
                    if text.range(of: #"mobile_device_group_ids\s*=\s*\[[^\]]*("\d+"|jamfplatform_device_group\.)"#,
                                  options: .regularExpression) != nil {
                        mobileScopeKept = true
                    }
                }
                for rewrite in scopeRewrites where text.range(of: rewrite.pattern, options: .regularExpression) != nil {
                    text = text.replacingOccurrences(
                        of: rewrite.pattern, with: rewrite.replacement, options: .regularExpression)
                    switch rewrite.kind {
                    case .jamfPro: usesJamfProScope = true
                    case .platform: usesPlatformScope = true
                    case .category: usesCategory = true
                    case .jamfProMobile: usesJamfProMobileScope = true
                    }
                }
                let deviceGroupsPattern = #"(^|\n)(\s*)device_groups\s*=\s*\[[^\]]*("[0-9a-f-]{36}"|jamfplatform_device_group\.)[^\]]*\]"#
                if text.range(of: deviceGroupsPattern, options: .regularExpression) != nil {
                    text = text.replacingOccurrences(
                        of: deviceGroupsPattern,
                        with: "$1$2device_groups = [var.scope_platform_group_uuid]",
                        options: .regularExpression
                    )
                    usesPlatformScope = true
                }
            }

            // Both modes: remaining associations survive as name-keyed
            // lookups wired to the blocks that create the referenced objects
            // (scripts, packages, extension attributes, groups outside the
            // collapsed scope).
            for (key, names) in resolveAssociations(
                in: &text, table: table, localAddresses: localAddresses,
                namePrefix: request.namePrefix,
                builtinGroupNames: &builtinGroupNames, warnings: &warnings
            ) {
                needs[key, default: []].formUnion(names)
            }
            let unresolved = text.components(separatedBy: "# TODO: unresolved reference").count - 1
            if unresolved > 0 {
                warnings.append("\(name) keeps \(unresolved) numeric ID\(unresolved == 1 ? "" : "s") that could not be resolved to names — they point at objects in the origin tenant and need review before deploying elsewhere.")
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
            "scope_platform_group_uuid", "scope_jamf_pro_mobile_group_id", "category_id",
        ]
        var unfillable: Set<String> = []
        for (_, text) in fileTexts {
            for match in text.matches(of: /var\.([a-zA-Z0-9_]+)/) {
                let name = String(match.1)
                guard !generatedVariables.contains(name), !name.hasPrefix("dep_") else { continue }
                let hasDefault = exportedDeclarations[name]?.range(
                    of: #"(?m)^\s*default\s*="#, options: .regularExpression) != nil
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
                warnings.append("Left out \(droppedAddresses.count) object\(droppedAddresses.count == 1 ? "" : "s") whose values Jamf does not export (icons, tokens, and similar): \(droppedAddresses.joined(separator: ", ")). Set them by hand after deploying.")
            }
        }

        // 1b2. References to objects that are neither in this block nor
        // resolvable (Self Service icons and similar) are stripped with a
        // warning rather than left dangling.
        var danglingAddresses: Set<String> = []
        for (_, text) in fileTexts {
            // `data.` lookups resolve against the deploying tenant and are
            // never dangling.
            for match in text.matches(of: /(data\.)?\b(jamfplatform_[a-z0-9_]+\.[A-Za-z0-9_-]+)\.[a-z_]+\b/) {
                guard match.1 == nil else { continue }
                let address = String(match.2)
                if !localAddresses.contains(address) || droppedAddresses.contains(address) {
                    // localAddresses reflects the capture selection, not the
                    // resources dropped above — confirm against the texts.
                    let definedHere = fileTexts.contains { $0.text.contains("resource \"\(address.split(separator: ".").first ?? "")\" \"\(address.split(separator: ".").last ?? "")\"") }
                    if !definedHere { danglingAddresses.insert(address) }
                }
            }
        }
        if !danglingAddresses.isEmpty {
            fileTexts = fileTexts.map { entry in
                (entry.name, Self.strippingReferences(to: Array(danglingAddresses), in: entry.text))
            }
            warnings.append("Left out references to objects that are not part of this capture: \(danglingAddresses.sorted().joined(separator: ", ")). Review the block before deploying.")
        }

        // 1c. Write the files and count what survived.
        for (name, text) in fileTexts {
            guard text.contains("resource ") || text.contains("data ") else { continue }
            for match in text.matches(of: /resource\s+"([a-z0-9_]+)"\s+"([A-Za-z0-9_-]+)"/) {
                objectCount += 1
                terraformTypes.insert(String(match.1))
                typeCounts[String(match.1), default: 0] += 1
                if match.2 == "singleton" { singletonTypes.insert(String(match.1)) }
            }
            try Data(text.utf8).write(to: blockURL.appending(path: name))
            capturedText += text + "\n"
        }

        guard objectCount > 0 else {
            try? fileManager.removeItem(at: blockURL)
            throw CaptureError.nothingToCapture(reasons: warnings)
        }

        // What this block provides to others: name→resource maps per type.
        // (address, objectName) pairs per dependency key.
        var provides: [String: [(address: String, name: String)]] = [:]
        var mobileGroupNames: Set<String> = []
        for block in ExportedObjectInventory.topLevelBlocks(in: capturedText) {
            guard let header = block.firstMatch(of: /resource\s+"([a-z0-9_]+)"\s+"([A-Za-z0-9_-]+)"/),
                  let depKey = Self.dependencyTypes[String(header.1)]
            else { continue }
            let address = "\(header.1).\(header.2)"
            guard let objectName = table.nameByAddress[address]
                ?? block.firstMatch(of: /\n\s+name\s+= "([^"]*)"/).map({ String($0.1) })
            else { continue }
            provides[depKey, default: []].append((address, objectName))
            if depKey == "device_group", block.range(of: #"\n\s*device_type\s*=\s*"mobile""#, options: .regularExpression) != nil {
                mobileGroupNames.insert(objectName)
            }
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
        if mobileScopeKept {
            warnings.append("Mobile device objects keep their captured groups: a block chooses one scope per tenant, and this export also scopes computers. Capture mobile and computer objects as separate blocks to choose both.")
        }
        if usesJamfProMobileScope {
            variables += """


            variable "scope_jamf_pro_mobile_group_id" {
              description = "Numeric Jamf Pro ID of the mobile device group this block targets."
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
        for name in referenced.subtracting(generatedVariables).sorted() where !name.hasPrefix("dep_") {
            if var declaration = exportedDeclarations[name] {
                let hasDefault = declaration.range(
                    of: #"(?m)^\s*default\s*="#, options: .regularExpression) != nil
                // exportedValues holds the raw escaped text between the
                // tfvars quotes — valid HCL as-is, so no re-escaping.
                if !hasDefault, let value = exportedValues[name],
                   let brace = declaration.range(of: "}", options: .backwards) {
                    declaration.replaceSubrange(
                        brace.lowerBound..<brace.lowerBound,
                        with: "  default = \"\(value)\"\n"
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
            let plural = depKey.replacingOccurrences(of: "_", with: " ") + "s"
            variables += """


            variable "dep_\(depKey)_ids" {
              description = "IDs of \(plural) this block references, keyed by original object name."
              type        = map(string)
              default     = {}
            }


            variable "dep_\(depKey)_names" {
              description = "Deployed names of \(plural) this block references, keyed by original object name."
              type        = map(string)
              default     = {}
            }
            """
            if depKey == "device_group" {
                variables += """


                variable "dep_device_group_jamf_pro_ids" {
                  description = "Numeric Jamf Pro IDs of referenced device groups, keyed by original object name."
                  type        = map(string)
                  default     = {}
                }
                """
            }
        }

        try Data(variables.utf8).write(to: blockURL.appending(path: "variables.tf"))

        if !builtinGroupNames.isEmpty {
            // Jamf's built-in device groups exist in every tenant; look them
            // up by name. The list data source carries no numeric Jamf Pro
            // ID, so each group gets a follow-up single lookup.
            var lookup = """
            data "jamfplatform_device_groups" "builtin" {}

            locals {
              builtin_group_uuid_by_name = {
                for group in data.jamfplatform_device_groups.builtin.device_groups :
                group.name => group.id
              }
            }
            """
            var uuidPairs: [String] = []
            var proPairs: [String] = []
            for name in builtinGroupNames.sorted() {
                let label = "builtin_" + name.lowercased()
                    .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "_", options: .regularExpression)
                lookup += """


                data "jamfplatform_device_group" "\(label)" {
                  id = local.builtin_group_uuid_by_name[\(hclStringLiteral(name))]
                }
                """
                uuidPairs.append("    \(hclStringLiteral(name)) = data.jamfplatform_device_group.\(label).id")
                proPairs.append("    \(hclStringLiteral(name)) = data.jamfplatform_device_group.\(label).jamf_pro_id")
            }
            lookup += """


            locals {
              builtin_group_uuids = {
            \(uuidPairs.joined(separator: "\n"))
              }
              builtin_group_jamf_pro_ids = {
            \(proPairs.joined(separator: "\n"))
              }
            }
            """
            try Data(lookup.utf8).write(to: blockURL.appending(path: "builtin_groups.tf"))
        }

        if adeReferenced {
            if adeAddresses.count > 1 {
                warnings.append("PreStages in this block used \(adeAddresses.count) Automated Device Enrollment instances; all now attach to the one named in the block's setting. Capture them as separate blocks to keep them apart.")
            }
            // PreStages wire to the deploying tenant's Automated Device
            // Enrollment instance, found by the name in the block setting.
            let instance = """
            variable "ade_instance_name" {
              description = "Name of the tenant's Automated Device Enrollment instance that PreStage enrollments attach to."
              type        = string
              default     = \(hclStringLiteral(adeInstanceName ?? ""))
            }

            data "jamfplatform_pro_automated_device_enrollment" "instance" {
              name = var.ade_instance_name
            }
            """
            try Data(instance.utf8).write(to: blockURL.appending(path: "enrollment_instance.tf"))
            warnings.append("PreStage enrollments attach to the deploying tenant's Automated Device Enrollment instance — the tenant needs its ADE token uploaded, and the block's \"Automated Device Enrollment instance\" setting must match that instance's name.")
        }

        if vppReferenced {
            let location = """
            variable "vpp_location_name" {
              description = "Name of the tenant's Apps and Books (volume purchasing) location that holds the app licenses."
              type        = string
              default     = \(hclStringLiteral(vppLocationName ?? ""))
            }

            data "jamfplatform_pro_volume_purchasing_location" "apps_and_books" {
              name = var.vpp_location_name
            }
            """
            try Data(location.utf8).write(to: blockURL.appending(path: "apps_and_books_location.tf"))
            warnings.append("App Store apps license through the deploying tenant's Apps and Books location — each tenant needs licenses for these apps, and the block's \"Apps and Books location\" setting must match its location name.")
        }

        // Name→ID and name→deployed-name output maps, so other blocks can
        // wire to this one; names come from the resources so prefixing is
        // reflected.
        if !provides.isEmpty {
            var outputs = ""
            for (depKey, entries) in provides.sorted(by: { $0.key < $1.key }) {
                let pairs = entries
                    .sorted { $0.name < $1.name }
                    .map { "    \(hclStringLiteral($0.name)) = \($0.address).id" }
                    .joined(separator: "\n")
                let namePairs = entries
                    .sorted { $0.name < $1.name }
                    .map {
                        let usesDisplayName = $0.address.hasPrefix("jamfplatform_pro_package.")
                            || $0.address.hasPrefix("jamfplatform_pro_enrollment_customization.")
                        let attribute = usesDisplayName ? "display_name" : "name"
                        return "    \(hclStringLiteral($0.name)) = \($0.address).\(attribute)"
                    }
                    .joined(separator: "\n")
                outputs += """
                output "\(depKey)_ids" {
                  value = {
                \(pairs)
                  }
                }


                output "\(depKey)_names" {
                  value = {
                \(namePairs)
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

        // 4. block.json, including the permissions the export recorded —
        // narrowed to this block's own types, with the write actions a
        // deploy needs (tenant-wide settings are only read and updated).
        let permissionsURL = request.sourceDirectory.appending(path: "PERMISSIONS.md")
        let byType = parsePermissionsByType(at: permissionsURL)
        var permissions: [String] = []
        if byType.isEmpty {
            permissions = parsePermissions(at: permissionsURL)
        } else {
            var set: Set<String> = []
            for type in terraformTypes {
                let actions = singletonTypes.contains(type) ? ["read", "update"] : ["create", "read", "update", "delete"]
                for capability in byType[type] ?? [] {
                    let name = capability.split(separator: ":").first.map(String.init) ?? capability
                    for action in actions { set.insert("\(name):\(action)") }
                }
            }
            // Lookups the capture adds itself only read.
            if adeReferenced { set.insert("device-enrollment-program-instances:read") }
            if !builtinGroupNames.isEmpty { set.insert("device-groups:read") }
            permissions = set.sorted()
        }
        if permissions.isEmpty {
            warnings.append("No PERMISSIONS.md found in the export — the block lists no permissions.")
        }

        let scope: [String: Any]
        if usesJamfProScope {
            scope = ["kind": "jamfProGroup", "variable": "scope_jamf_pro_group_id"]
        } else if usesJamfProMobileScope {
            scope = ["kind": "jamfProMobileGroup", "variable": "scope_jamf_pro_mobile_group_id"]
        } else if usesPlatformScope {
            scope = ["kind": "platformGroup", "variable": "scope_platform_group_uuid"]
        } else {
            scope = ["kind": "none"]
        }

        var metadata: [String: Any] = [
            "id": request.blockID,
            "name": request.name,
            "summary": request.summary,
            "category": "Captured",
            "version": "0.1.0",
            "needs": needs.mapValues { Array($0).sorted() },
            "provides": provides.mapValues { $0.map(\.name).sorted() },
            "mobileDeviceGroups": mobileGroupNames.sorted(),
            "requires": [],
            "conflicts": [],
            "products": ["jamf-pro", "jamf-platform"],
            "permissions": permissions,
            "risk": "medium",
            "alwaysOn": false,
            "acceptsCategory": usesCategory,
            "reviewStatus": "needsReview",
            "scope": scope,
            "settings": (adeReferenced ? [[
                "key": "ade_instance_name",
                "title": "Automated Device Enrollment instance",
                "type": "string",
                "default": adeInstanceName ?? "",
                "required": true,
                "description": "Name of this tenant's Automated Device Enrollment instance. PreStage enrollments attach to it, so the tenant needs its ADE token uploaded first.",
                "section": "Enrollment",
            ]] : []) + (vppReferenced ? [[
                "key": "vpp_location_name",
                "title": "Apps and Books location",
                "type": "string",
                "default": vppLocationName ?? "",
                "required": true,
                "description": "Name of this tenant's Apps and Books (volume purchasing) location. It needs licenses for every app in this block.",
                "section": "Apps and Books",
            ]] : []),
            "objectsCreated": typeCounts.sorted { $0.key < $1.key }.map { "\(objectLabel(for: $0.key)) (\($0.value))" },
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
            usesJamfProMobileScope: usesJamfProMobileScope,
            usesCategory: usesCategory,
            warnings: warnings
        )
    }

    /// Reads the capability set out of jamformer's PERMISSIONS.md.
    /// Removes one named attribute object (`name = { … }`) from a block.
    static func strippingAttributeObject(named attribute: String, from text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var kept: [String] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.range(of: "^\\s*" + attribute + "\\s*=\\s*\\{\\s*$", options: .regularExpression) != nil {
                var depth = 1
                while depth > 0, index + 1 < lines.count {
                    index += 1
                    depth += lines[index].filter { $0 == "{" }.count - lines[index].filter { $0 == "}" }.count
                }
                index += 1
                continue
            }
            kept.append(line)
            index += 1
        }
        return kept.joined(separator: "\n")
    }

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
                guard let header = block.firstMatch(of: /resource\s+"([a-z0-9_]+)"\s+"([A-Za-z0-9_-]+)"/) else { continue }
                let name = block.firstMatch(of: /\n\s+name\s+= "([^"]*)"/).map { String($0.1) }
                    ?? block.firstMatch(of: /\n\s+display_name\s+= "([^"]*)"/).map { String($0.1) }
                guard let name else { continue }
                let address = "\(header.1).\(header.2)"
                table.nameByAddress[address] = name
                if let id = idByAddress[address] {
                    table.nameByTypeAndID["\(header.1)#\(id)"] = name
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
        namePrefix: String,
        builtinGroupNames: inout Set<String>,
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

        // PreStages name their enrollment customization by numeric ID ("0"
        // and "-1" mean none). Without the customization in the export the
        // origin's ID means nothing elsewhere, so it falls back to none.
        text = replacing(in: text, pattern: #"enrollment_customization_id\s*= "(\d+)""#) { match in
            guard match[1] != "0" else { return nil }
            guard let name = table.name(type: "jamfplatform_pro_enrollment_customization", id: match[1]) else {
                warnings.append("A PreStage used an enrollment customization that is not part of the export; it deploys without one. Export the customization with it to keep the link.")
                return "enrollment_customization_id = \"0\""
            }
            return "enrollment_customization_id = \(record("enrollment_customization", name))"
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

        // `.name` references to objects outside this block resolve by name.
        // The dependency map yields the name the providing block actually
        // deploys (prefixing included) and makes the referencing resource
        // wait for the object to exist.
        text = replacing(in: text, pattern: #"\b(jamfplatform_[a-z0-9_]+\.[A-Za-z0-9_-]+)\.name\b"#) { match in
            let address = match[1]
            guard !localAddresses.contains(address),
                  let name = table.nameByAddress[address]
            else { return nil }
            let type = String(address.split(separator: ".").first ?? "")
            if let depKey = dependencyTypes[type], !Self.isBuiltinGroupName(name) {
                needs[depKey, default: []].insert(name)
                return "var.dep_\(depKey)_names[\(hclStringLiteral(name))]"
            }
            return hclStringLiteral(name)
        }

        // Numeric Jamf Pro group IDs: Jamf's built-in groups exist in every
        // tenant and are looked up; everything else wires between blocks.
        text = replacing(in: text, pattern: #"\b(jamfplatform_device_group\.[A-Za-z0-9_-]+)\.jamf_pro_id\b"#) { match in
            let address = match[1]
            guard !localAddresses.contains(address),
                  let name = table.nameByAddress[address]
            else { return nil }
            if Self.isBuiltinGroupName(name) {
                builtinGroupNames.insert(name)
                return "local.builtin_group_jamf_pro_ids[\(hclStringLiteral(name))]"
            }
            needs["device_group", default: []].insert(name)
            return "var.dep_device_group_jamf_pro_ids[\(hclStringLiteral(name))]"
        }

        // Jamf's built-in device groups exist in every tenant and are looked
        // up rather than wired between blocks.
        func builtinGroupUUIDLookup(_ name: String) -> String {
            builtinGroupNames.insert(name)
            return "local.builtin_group_uuids[\(hclStringLiteral(name))]"
        }

        // Resource references to objects outside this block (the exporter
        // resolves same-run references) become name-keyed lookups too.
        for (type, depKey) in dependencyTypes {
            let pattern = "\\b(" + type + #"\.[A-Za-z0-9_-]+)\.id\b"#
            text = replacing(in: text, pattern: pattern) { match in
                let address = match[1]
                guard !localAddresses.contains(address),
                      let name = table.nameByAddress[address]
                else { return nil }
                if depKey == "device_group", Self.isBuiltinGroupName(name) {
                    return builtinGroupUUIDLookup(name)
                }
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
                        elements.append(Self.isBuiltinGroupName(name)
                            ? builtinGroupUUIDLookup(name)
                            : record("device_group", name))
                    } else {
                        resolvedAll = false
                    }
                }
                guard resolvedAll, !elements.isEmpty else { return nil }
                return "\(attribute) = [\(elements.joined(separator: ", "))]"
            }
        }

        // Smart-group criteria name extension attributes as plain strings.
        // The dependency map yields the attribute's deployed name and makes
        // the group wait for it to exist. The earlier prefix pass may have
        // rewritten the criteria string, so match both forms.
        var eaOriginalByCriteria: [String: String] = [:]
        for (address, name) in table.nameByAddress
        where address.hasPrefix("jamfplatform_pro_computer_extension_attribute.") {
            eaOriginalByCriteria[name] = name
            if !namePrefix.isEmpty, name.hasPrefix(namePrefix) {
                eaOriginalByCriteria["${var.name_prefix}" + name.dropFirst(namePrefix.count)] = name
            }
        }
        var localEAAddressesByName: [String: String] = [:]
        for address in localAddresses where address.hasPrefix("jamfplatform_pro_computer_extension_attribute.") {
            if let name = table.nameByAddress[address] { localEAAddressesByName[name] = address }
        }
        text = replacing(in: text, pattern: #"(criteria\s+= )"([^"]+)""#) { match in
            guard let original = eaOriginalByCriteria[match[2]] else { return nil }
            if let address = localEAAddressesByName[original] {
                return "\(match[1])\(address).name"
            }
            needs["extension_attribute", default: []].insert(original)
            return "\(match[1])var.dep_extension_attribute_names[\(hclStringLiteral(original))]"
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
        // ${ and %{ start template interpolation inside HCL strings; object
        // names must never evaluate as expressions.
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "${", with: "$${")
            .replacingOccurrences(of: "%{", with: "%%{") + "\""
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

    /// Capabilities per resource type from the export's PERMISSIONS.md
    /// table (`| `type` | `cap:read`<br>`cap:read` | … |`).
    static func parsePermissionsByType(at url: URL) -> [String: [String]] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var result: [String: [String]] = [:]
        for line in text.split(separator: "\n") {
            guard let row = line.firstMatch(of: /^\|\s*`([a-z0-9_]+)`\s*\|([^|]*)\|/) else { continue }
            let capabilities = row.2.matches(of: /`([a-z0-9-]+:[a-z]+)`/).map { String($0.1) }
            if !capabilities.isEmpty { result[String(row.1), default: []].append(contentsOf: capabilities) }
        }
        return result
    }

    /// Plain-language label for a provider type: `jamfplatform_pro_macos_configuration_profile` → "macOS configuration profile".
    public static func objectLabel(for type: String) -> String {
        var words = type
            .replacingOccurrences(of: "jamfplatform_pro_", with: "")
            .replacingOccurrences(of: "jamfplatform_", with: "")
            .split(separator: "_").map(String.init)
        words = words.map { ["macos": "macOS", "ios": "iOS", "sso": "SSO", "smtp": "SMTP", "gsx": "GSX", "mdm": "MDM", "url": "URL", "ldap": "LDAP"][$0] ?? $0 }
        var label = words.joined(separator: " ")
        if let first = label.first, first.isLowercase, !label.hasPrefix("macOS"), !label.hasPrefix("iOS") {
            label = first.uppercased() + label.dropFirst()
        }
        return label
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
