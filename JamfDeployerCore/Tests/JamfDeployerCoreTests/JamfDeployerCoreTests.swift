import Foundation
import Testing
@testable import JamfDeployerCore

private nonisolated func fixtureURL(_ name: String) -> URL {
    Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)!
}

private nonisolated func fixtureData(_ name: String) -> Data {
    try! Data(contentsOf: fixtureURL(name))
}

@Suite("Engine stream decoding")
struct EngineStreamTests {
    @Test(arguments: ["plan-stream.jsonl", "apply-stream.jsonl", "apply-stream-destroy.jsonl"])
    func decodesEveryLine(fixture: String) throws {
        let text = String(decoding: fixtureData(fixture), as: UTF8.self)
        let decoder = JSONDecoder()
        for line in text.split(separator: "\n") where line.hasPrefix("{") {
            let event = try decoder.decode(EngineStreamEvent.self, from: Data(line.utf8))
            #expect(event.type != .unknown, "unknown event type in \(line.prefix(80))")
        }
    }

    @Test func readsForgetCountFromChangeSummary() throws {
        let line = #"{"@level":"info","@message":"Plan: 0 to add.","@module":"tofu.ui","@timestamp":"t","changes":{"add":0,"change":0,"import":0,"remove":0,"forget":2,"operation":"plan"},"type":"change_summary"}"#
        let event = try JSONDecoder().decode(EngineStreamEvent.self, from: Data(line.utf8))
        #expect(event.changes?.forget == 2)
    }
}

@Suite("Plan files and preview building")
struct PreviewTests {
    @Test func labelsCreatePlan() throws {
        let plan = try JSONDecoder().decode(PlanFile.self, from: fixtureData("show-plan-create.json"))
        let summary = PreviewBuilder.build(plan: plan, diagnostics: [], blockNames: [:])
        #expect(summary.counts[.create, default: 0] > 0)
        #expect(!summary.hasDestructiveChanges)
    }

    @Test func mapsForgetToStopManaging() throws {
        let plan = try JSONDecoder().decode(PlanFile.self, from: fixtureData("show-plan-forget.json"))
        let summary = PreviewBuilder.build(plan: plan, diagnostics: [], blockNames: [:])
        #expect(summary.counts[.stopManaging] == 1)
    }

    @Test func extractsFieldLevelDrift() throws {
        let plan = try JSONDecoder().decode(PlanFile.self, from: fixtureData("show-plan-drift.json"))
        let drifted = plan.resourceDrift ?? []
        #expect(!drifted.isEmpty)
        let category = drifted.first { $0.address.contains("pro_category") }
        #expect(category?.changedAttributeNames == ["name"])
    }

    @Test func attachesImpactAlertsToObjects() throws {
        let plan = try JSONDecoder().decode(PlanFile.self, from: fixtureData("show-plan-create.json"))
        let firstCreate = try #require(plan.resourceChanges?.first { $0.change.actions == ["create"] })
        let diagnostic = EngineStreamEvent.Diagnostic(
            severity: "warning",
            summary: "Impact alert — this policy will be scoped to 0 computers",
            detail: nil,
            address: firstCreate.address
        )
        let summary = PreviewBuilder.build(plan: plan, diagnostics: [diagnostic], blockNames: [:])
        let withNote = summary.groups.flatMap(\.changes).first { !$0.notes.isEmpty }
        #expect(withNote != nil)
    }

    @Test func changeKindMapping() {
        #expect(ChangeKind.from(actions: ["create"], importing: false) == .create)
        #expect(ChangeKind.from(actions: ["delete", "create"], importing: false) == .replace)
        #expect(ChangeKind.from(actions: ["forget"], importing: false) == .stopManaging)
        #expect(ChangeKind.from(actions: ["no-op"], importing: true) == .adopt)
        #expect(ChangeKind.from(actions: ["delete"], importing: false).isDestructive)
    }

    @Test func moduleAddressesMapToBlockIDs() {
        #expect(PreviewBuilder.moduleID(of: "module.compliance_cis_l1.jamfplatform_cbengine_benchmark.cis_l1") == "compliance-cis-l1")
        #expect(PreviewBuilder.moduleID(of: "jamfplatform_pro_category.spike") == nil)
    }
}

@Suite("Catalog loading")
struct CatalogTests {
    // A full catalog fixture: the built-in Foundation block plus the demo
    // catalog's blocks and presets, frozen for the generator tests.
    static let catalogURL = Bundle.module.url(forResource: "Fixtures/test-catalog", withExtension: nil)!

    @Test func loadsAllBlocksAndPresets() throws {
        let catalog = try LoadedCatalog.load(from: Self.catalogURL)
        #expect(catalog.blocks.count == 9)
        let protect = try #require(catalog.block(id: "protect-baseline"))
        #expect(protect.products == ["jamf-protect"])
        #expect(protect.settings.contains { $0.key == "threat_mode" && $0.default == "Report only" })
        #expect(catalog.presets.count == 2)
        let foundation = try #require(catalog.block(id: "foundation"))
        #expect(foundation.alwaysOn)
        #expect(foundation.scope.kind == .none)
        let compliance = try #require(catalog.block(id: "compliance-cis-l1"))
        #expect(compliance.scope.kind == .platformGroup)
        #expect(compliance.settings.contains { $0.type == .enumeration && $0.enumValues?.count == 2 })
    }

    @Test func presetBlocksAllExist() throws {
        let catalog = try LoadedCatalog.load(from: Self.catalogURL)
        for preset in catalog.presets {
            for blockID in preset.blocks {
                #expect(catalog.block(id: blockID) != nil, "preset \(preset.id) references missing block \(blockID)")
            }
        }
    }
}

@Suite("Workspace generation")
struct GeneratorTests {
    static func catalog() throws -> LoadedCatalog {
        try LoadedCatalog.load(from: CatalogTests.catalogURL)
    }

    static func selection(_ catalog: LoadedCatalog, _ id: String, settings: [String: String] = [:], scope: String = "pilot") -> GeneratedSelection {
        GeneratedSelection(block: catalog.block(id: id)!, settings: settings, scope: scope)
    }

    static func metadata(_ json: String) throws -> BlockMetadata {
        try JSONDecoder().decode(BlockMetadata.self, from: Data(json.utf8))
    }

    @Test func wiresDependencyMapsBetweenBlocks() throws {
        let provider = try Self.metadata(
            #"{"id": "cap-scripts", "name": "Scripts", "provides": {"script": ["JD - Install Rosetta 2"]}}"#)
        let consumer = try Self.metadata(
            #"{"id": "cap-policies", "name": "Policies", "needs": {"script": ["JD - Install Rosetta 2"]}}"#)
        let input = WorkspaceInput(
            namePrefix: "JD - ",
            selections: [
                GeneratedSelection(block: provider, settings: [:], scope: "pilot"),
                GeneratedSelection(block: consumer, settings: [:], scope: "pilot"),
            ],
            providerVersion: "1.5.0"
        )
        let output = try WorkspaceGenerator.generate(input)
        #expect(output.mainTF.contains("dep_script_ids = module.cap_scripts.script_ids"))
    }

    @Test func failsOnUnmetDependencies() throws {
        let consumer = try Self.metadata(
            #"{"id": "cap-policies", "name": "Policies", "needs": {"script": ["Missing Script"]}}"#)
        let input = WorkspaceInput(
            namePrefix: "JD - ",
            selections: [GeneratedSelection(block: consumer, settings: [:], scope: "pilot")],
            providerVersion: "1.5.0"
        )
        #expect(throws: WorkspaceGeneratorError.self) {
            _ = try WorkspaceGenerator.generate(input)
        }
    }

    @Test func generatesFullBaseline() throws {
        let catalog = try Self.catalog()
        let input = WorkspaceInput(
            namePrefix: "JD - ",
            selections: [
                Self.selection(catalog, "foundation"),
                Self.selection(catalog, "enrollment", settings: ["ade_instance_name": "Apple Business Manager"]),
                Self.selection(catalog, "filevault"),
                Self.selection(catalog, "software-updates"),
                Self.selection(catalog, "compliance-cis-l1"),
                Self.selection(catalog, "rosetta", scope: "apple_silicon"),
            ],
            providerVersion: "1.5.0"
        )
        let output = try WorkspaceGenerator.generate(input)

        #expect(output.providersTF.contains("impact_alerts = true"))
        #expect(!output.providersTF.contains("jamfprotect"), "no Protect provider without Protect blocks")
        #expect(output.mainTF.contains(#"module "foundation""#))
        #expect(output.mainTF.contains("scope_jamf_pro_group_id = module.foundation.pilot_jamf_pro_id"))
        #expect(output.mainTF.contains("scope_platform_group_uuid = module.foundation.pilot_platform_uuid"))
        #expect(output.mainTF.contains("module.foundation.apple_silicon_jamf_pro_id"))
        let normalized = output.mainTF.replacingOccurrences(of: " +", with: " ", options: .regularExpression)
        #expect(normalized.contains(#"ade_instance_name = "Apple Business Manager""#))
        #expect(output.mainTF.contains("category_id"))
        #expect(output.secretVariableNames.isEmpty)
    }

    @Test func emitsProtectProviderForProtectBlocks() throws {
        let catalog = try Self.catalog()
        let input = WorkspaceInput(
            namePrefix: "JD - ",
            selections: [
                Self.selection(catalog, "foundation"),
                Self.selection(catalog, "protect-baseline"),
            ],
            providerVersion: "1.5.0"
        )
        let output = try WorkspaceGenerator.generate(input)
        #expect(output.providersTF.contains(#"source  = "Jamf-Concepts/jamfprotect""#))
        #expect(output.providersTF.contains(#"provider "jamfprotect""#))
    }

    @Test func refusesBaselineWithoutFoundation() throws {
        let catalog = try Self.catalog()
        let input = WorkspaceInput(
            namePrefix: "JD - ",
            selections: [Self.selection(catalog, "rosetta")],
            providerVersion: "1.5.0"
        )
        #expect(throws: WorkspaceGeneratorError.self) {
            try WorkspaceGenerator.generate(input)
        }
    }

    @Test func refusesMissingRequiredSetting() throws {
        let catalog = try Self.catalog()
        let input = WorkspaceInput(
            namePrefix: "JD - ",
            selections: [
                Self.selection(catalog, "foundation"),
                Self.selection(catalog, "enrollment"), // ade_instance_name missing
            ],
            providerVersion: "1.5.0"
        )
        #expect(throws: WorkspaceGeneratorError.self) {
            try WorkspaceGenerator.generate(input)
        }
    }

    @Test func escapesHCLStrings() {
        #expect(WorkspaceGenerator.hclString(#"a "quoted" ${thing}"#) == #""a \"quoted\" $${thing}""#)
    }
}

@Suite("App Catalog selections")
struct AppCatalogTests {
    @Test func roundTripsThroughSettingValue() {
        let apps = [
            AppCatalogApp(titleName: "Google Chrome", publisher: "Google", deploymentType: .selfService, updateBehavior: .automatic),
            AppCatalogApp(titleName: "1Password 8", publisher: "AgileBits", deploymentType: .installAutomatically, updateBehavior: .manual),
        ]
        let encoded = AppCatalogApp.encode(apps)
        let decoded = AppCatalogApp.decode(settingValue: encoded)
        #expect(Set(decoded) == Set(apps))
        #expect(AppCatalogApp.decode(settingValue: "") == [])
        #expect(AppCatalogApp.decode(settingValue: "not json") == [])
    }

    @Test func generatorEmbedsAppsJSON() throws {
        let catalog = try LoadedCatalog.load(from: CatalogTests.catalogURL)
        let apps = AppCatalogApp.encode([AppCatalogApp(titleName: "Google Chrome", publisher: "Google")])
        let input = WorkspaceInput(
            namePrefix: "JD - ",
            selections: [
                GeneratedSelection(block: catalog.block(id: "foundation")!, settings: [:], scope: "pilot"),
                GeneratedSelection(block: catalog.block(id: "app-catalog")!, settings: ["apps_json": apps], scope: "all_macs"),
            ],
            providerVersion: "1.5.0"
        )
        let output = try WorkspaceGenerator.generate(input)
        #expect(output.mainTF.contains("module.foundation.all_macs_jamf_pro_id"))
        #expect(output.mainTF.contains("titleName") && output.mainTF.contains("Google Chrome"))
    }

    @Test func appCatalogScopeIsSmartOnly() throws {
        let catalog = try LoadedCatalog.load(from: CatalogTests.catalogURL)
        let block = try #require(catalog.block(id: "app-catalog"))
        #expect(block.scope.smartOnly)
        #expect(block.settings.first?.type == .appPicker)
    }
}

@Suite("Drift reports")
struct DriftReportTests {
    @Test func classifiesDriftWithDeepPaths() throws {
        let plan = try JSONDecoder().decode(PlanFile.self, from: fixtureData("show-plan-drift.json"))
        let report = DriftReportBuilder.build(plan: plan, blockNames: [:])
        #expect(report.objects.count == 4)

        // The admin's rename is actionable…
        let category = try #require(report.objects.first { $0.resourceType == "jamfplatform_pro_category" })
        #expect(!category.isComputedOnly)
        #expect(category.fields.map(\.path) == ["name"])

        // …while the echoes on referencing objects are computed-only noise.
        let script = try #require(report.objects.first { $0.resourceType == "jamfplatform_pro_script" })
        #expect(script.isComputedOnly)
        let policy = try #require(report.objects.first { $0.resourceType == "jamfplatform_pro_policy" })
        #expect(policy.fields.map(\.path) == ["general.category_name"])
        #expect(policy.isComputedOnly)
        let prestage = try #require(report.objects.first { $0.resourceType == "jamfplatform_pro_computer_prestage_enrollment" })
        #expect(prestage.isComputedOnly)

        #expect(report.actionableObjects.count == 1)
    }
}

@Suite("Block removals")
struct RemovalTests {
    @Test func emitsRemovedBlockForStopManaging() throws {
        let catalog = try LoadedCatalog.load(from: CatalogTests.catalogURL)
        let input = WorkspaceInput(
            namePrefix: "JD - ",
            selections: [GeneratedSelection(block: catalog.block(id: "foundation")!, settings: [:], scope: "pilot")],
            providerVersion: "1.5.0",
            removals: [
                BlockRemoval(blockID: "rosetta", keepInJamf: true),
                BlockRemoval(blockID: "filevault", keepInJamf: false),
            ]
        )
        let output = try WorkspaceGenerator.generate(input)
        #expect(output.mainTF.contains("from = module.rosetta"))
        #expect(output.mainTF.contains("destroy = false"))
        // Plain removal ("Remove from tenant") needs no removed block.
        #expect(!output.mainTF.contains("module.filevault"))
    }

    @Test func handOverGeneratesWithoutFoundation() throws {
        let input = WorkspaceInput(
            namePrefix: "JD - ",
            selections: [],
            providerVersion: "1.5.0",
            removals: [
                BlockRemoval(blockID: "foundation", keepInJamf: true),
                BlockRemoval(blockID: "rosetta", keepInJamf: true),
            ]
        )
        let output = try WorkspaceGenerator.generate(input)
        #expect(output.mainTF.contains("from = module.foundation"))
        #expect(output.mainTF.contains("from = module.rosetta"))
    }
}

@Suite("Block capture")
struct BlockCaptureTests {
    func exportFixtureURL() -> URL {
        Bundle.module.url(forResource: "Fixtures/jamformer-export", withExtension: nil)!
    }

    @Test func fidelityCapturePreservesAssociations() throws {
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "fidelity-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }
        let full = FileManager.default.temporaryDirectory
            .appending(path: "fidelity-src-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: exportFixtureURL(), to: full)
        defer { try? FileManager.default.removeItem(at: full) }

        // Capture only the policy, as a split capture would: references to
        // the script, package and category land in other blocks.
        let staging = FileManager.default.temporaryDirectory
            .appending(path: "fidelity-staging-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: full, to: staging)
        defer { try? FileManager.default.removeItem(at: staging) }
        let objects = try ExportedObjectInventory.scan(directory: staging)
        let policyOnly = Set(objects.filter { $0.resourceType == "jamfplatform_pro_policy" }.map(\.address))
        try ExportedObjectInventory.prune(directory: staging, keeping: policyOnly)

        let result = try BlockCapture.capture(BlockCapture.Request(
            blockID: "fidelity-policy",
            name: "Policy",
            summary: "Policy slice.",
            namePrefix: "JD - ",
            sourceDirectory: staging,
            catalogRootDirectory: destination,
            resolutionDirectory: full
        ))
        let folder = result.blockFolderURL
        let policy = try String(contentsOf: folder.appending(path: "pro_policy.tf"), encoding: .utf8)
        // Numeric and resource references become name-keyed lookups.
        #expect(policy.contains(#"category_id = var.dep_category_ids["JD - Testing"]"#))
        #expect(policy.contains(#"id = var.dep_package_ids["JD - Test Package"]"#))
        #expect(policy.contains(#"var.dep_script_ids["JD - Install Rosetta 2"]"#))
        #expect(!policy.contains("var.category_id"))
        #expect(!policy.contains(#"= "73""#))

        let variables = try String(contentsOf: folder.appending(path: "variables.tf"), encoding: .utf8)
        #expect(variables.contains(#"variable "dep_category_ids""#))
        #expect(variables.contains(#"variable "dep_script_ids""#))
        #expect(variables.contains(#"variable "dep_package_ids""#))

        let manifest = try JSONSerialization.jsonObject(
            with: Data(contentsOf: folder.appending(path: "block.json"))) as? [String: Any]
        let needs = manifest?["needs"] as? [String: [String]]
        #expect(needs?["category"] == ["JD - Testing"])
        #expect(needs?["script"] == ["JD - Install Rosetta 2"])
        #expect(needs?["package"] == ["JD - Test Package"])
        #expect((manifest?["requires"] as? [String])?.isEmpty == true)
    }

    @Test func fidelityCaptureEmitsProvidesOutputs() throws {
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "provides-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }
        let source = FileManager.default.temporaryDirectory
            .appending(path: "provides-src-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: exportFixtureURL(), to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let result = try BlockCapture.capture(BlockCapture.Request(
            blockID: "fidelity-all",
            name: "All",
            summary: "Whole export.",
            namePrefix: "JD - ",
            sourceDirectory: source,
            catalogRootDirectory: destination
        ))
        let folder = result.blockFolderURL
        let outputs = try String(contentsOf: folder.appending(path: "dependency_outputs.tf"), encoding: .utf8)
        #expect(outputs.contains(#"output "script_ids""#))
        #expect(outputs.contains(#""JD - Install Rosetta 2" = jamfplatform_pro_script.jd_install_rosetta_2.id"#))
        #expect(outputs.contains(#"output "category_ids""#))
        #expect(outputs.contains(#"output "package_ids""#))

        // Same-block references stay direct resource references.
        let policy = try String(contentsOf: folder.appending(path: "pro_policy.tf"), encoding: .utf8)
        #expect(policy.contains("category_id = jamfplatform_pro_category.jd_testing.id"))
        #expect(!policy.contains("dep_category_ids"))
        let manifest = try JSONSerialization.jsonObject(
            with: Data(contentsOf: folder.appending(path: "block.json"))) as? [String: Any]
        let provides = manifest?["provides"] as? [String: [String]]
        #expect(provides?["script"]?.contains("JD - Install Rosetta 2") == true)
        #expect(provides?["category"] == ["JD - Testing"])
    }

    @Test func capturesExportIntoBlockLayout() throws {
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "capture-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }

        // Capture from the temp directory like the app does: /var/folders is
        // a symlink to /private/var, which the support-file copy must survive.
        let source = FileManager.default.temporaryDirectory
            .appending(path: "capture-src-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: exportFixtureURL(), to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let result = try BlockCapture.capture(BlockCapture.Request(
            blockID: "captured-rosetta",
            name: "Captured Rosetta",
            summary: "Rosetta policy captured from a tenant.",
            namePrefix: "JD - ",
            sourceDirectory: source,
            catalogRootDirectory: destination,
            rebind: .foundation
        ))

        #expect(result.objectCount == 6)
        #expect(result.usesJamfProScope)
        #expect(!result.usesPlatformScope)

        let folder = result.blockFolderURL
        let policy = try String(contentsOf: folder.appending(path: "pro_policy.tf"), encoding: .utf8)
        #expect(policy.contains(#"name            = "${var.name_prefix}Install Rosetta 2""#))
        #expect(policy.contains("computer_group_ids = [var.scope_jamf_pro_group_id]"))
        #expect(!policy.contains(#"["69"]"#))
        #expect(!policy.contains("provider = jamfplatform"))
        #expect(policy.contains("category_id = var.category_id"))

        // Variables the export declares and the configuration references are
        // carried over (with file paths rewritten); provider credentials and
        // other unreferenced variables are not.
        let variables = try String(contentsOf: folder.appending(path: "variables.tf"), encoding: .utf8)
        #expect(variables.contains(#"variable "pro_icon_icon_18_icon_file_source""#))
        // A declaration without a default gets its value from terraform.tfvars.
        #expect(variables.contains(#"variable "pro_icon_icon_12_icon_file_source""#))
        #expect(variables.contains(#"default = "files/icons/icon_12.png""#))

        // Unfillable (no default, no tfvars value): the icon resource and the
        // policy's reference to it are left out, with a warning.
        #expect(!variables.contains("icon_99"))
        let prunedIcons = try String(contentsOf: folder.appending(path: "pro_icon.tf"), encoding: .utf8)
        #expect(!prunedIcons.contains("icon_99"))
        let prunedPolicy = try String(contentsOf: folder.appending(path: "pro_policy.tf"), encoding: .utf8)
        #expect(!prunedPolicy.contains("self_service_icon"))
        #expect(prunedPolicy.contains("jamfplatform_pro_script.jd_install_rosetta_2.id"))
        #expect(result.warnings.contains { $0.contains("Left out 1 object") })

        // Referenced support files follow the block into files/.
        let copiedScript = folder.appending(path: "files/scripts/JD - Install Rosetta 2.zsh")
        #expect(FileManager.default.fileExists(atPath: copiedScript.path))
        #expect(variables.contains(#"default     = "files/icons/icon_18.png""#))
        #expect(!variables.contains("jamfplatform_base_url"))
        #expect(!policy.contains(#"category_id     = "73""#))

        let script = try String(contentsOf: folder.appending(path: "pro_script.tf"), encoding: .utf8)
        #expect(script.contains("files/scripts/"))
        #expect(!script.contains("support_files"))
        #expect(FileManager.default.fileExists(
            atPath: folder.appending(path: "files/scripts/JD - Install Rosetta 2.zsh").path
        ))

        // Import blocks and provider config stay out of the block.
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "pro_policy_import.tf").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "provider.tf").path))

        // block.json is loadable and marked for review, with permissions.
        let metadata = try JSONDecoder().decode(
            BlockMetadata.self,
            from: Data(contentsOf: folder.appending(path: "block.json"))
        )
        #expect(metadata.needsReview)
        #expect(metadata.scope.kind == .jamfProGroup)
        #expect(metadata.permissions.contains("policies:read"))
        #expect(metadata.requires == ["foundation"])
        #expect(metadata.acceptsCategory)
    }

    @Test func refusesEmptyExports() throws {
        let empty = FileManager.default.temporaryDirectory
            .appending(path: "capture-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(throws: BlockCapture.CaptureError.self) {
            try BlockCapture.capture(BlockCapture.Request(
                blockID: "empty",
                name: "Empty",
                summary: "",
                namePrefix: "JD - ",
                sourceDirectory: empty,
                catalogRootDirectory: empty
            ))
        }
    }
}

@Suite("As-built documentation")
struct AsBuiltTests {
    @Test func documentsExportedObjects() throws {
        let fixtures = Bundle.module.url(forResource: "Fixtures/jamformer-export", withExtension: nil)!
        let markdown = try AsBuiltReport.markdown(AsBuiltReport.Input(
            tenantName: "Demo",
            exportDirectory: fixtures,
            appVersion: "0.1.0"
        ))
        #expect(markdown.contains("# As-built — Demo"))
        #expect(markdown.contains("### JD - Install Rosetta 2"))
        #expect(markdown.contains("`jamfplatform_pro_policy`"))
        #expect(markdown.contains("Frequency: Once per computer"))
        #expect(markdown.contains("Scoped:"))
        #expect(markdown.contains("**7 objects**"))
    }
}

@Suite("Catalog merging")
struct CatalogMergeTests {
    @Test func mergesCustomSourceAfterOfficial() throws {
        let official = try LoadedCatalog.load(from: CatalogTests.catalogURL)

        // A custom source with one captured block.
        let customRoot = FileManager.default.temporaryDirectory
            .appending(path: "custom-source-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: customRoot) }
        try JSONSerialization.data(withJSONObject: ["id": "custom", "name": "My Blocks", "schemaVersion": 1])
            .write(to: { try FileManager.default.createDirectory(at: customRoot, withIntermediateDirectories: true); return customRoot.appending(path: "catalog.json") }())
        _ = try BlockCapture.capture(BlockCapture.Request(
            blockID: "captured-rosetta",
            name: "Captured Rosetta",
            summary: "Captured.",
            namePrefix: "JD - ",
            sourceDirectory: Bundle.module.url(forResource: "Fixtures/jamformer-export", withExtension: nil)!,
            catalogRootDirectory: customRoot
        ))
        let custom = try LoadedCatalog.load(from: customRoot)

        let merged = LoadedCatalog.merge([official, custom])
        #expect(merged.blocks.count == official.blocks.count + 1)
        #expect(merged.block(id: "captured-rosetta") != nil)
        #expect(merged.sourceName(for: "captured-rosetta") == "My Blocks")
        #expect(merged.sourceName(for: "foundation") == "Built-in")
        #expect(merged.blockFolderURL(id: "captured-rosetta").path.contains("custom-source"))
    }
}

@Suite("Exported object inventory")
struct InventoryTests {
    func copyFixture() throws -> URL {
        let source = Bundle.module.url(forResource: "Fixtures/jamformer-export", withExtension: nil)!
        let copy = FileManager.default.temporaryDirectory.appending(path: "inventory-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: source, to: copy)
        return copy
    }

    @Test func scansObjectsWithNamesAndProvenance() throws {
        let dir = try copyFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let objects = try ExportedObjectInventory.scan(directory: dir)
        #expect(objects.count == 7)
        let script = try #require(objects.first { $0.resourceType == "jamfplatform_pro_script" })
        #expect(script.displayName == "JD - Install Rosetta 2")
        #expect(script.hasProvenanceTag) // fixture script carries the tag
        let policy = try #require(objects.first { $0.resourceType == "jamfplatform_pro_policy" })
        #expect(!policy.hasProvenanceTag)
    }

    @Test func normalizesIdentityImportsToStringIDs() throws {
        let dir = try copyFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        try ExportedObjectInventory.normalizeImportBlocks(directory: dir)
        let text = try String(contentsOf: dir.appending(path: "pro_script_import.tf"), encoding: .utf8)
        #expect(text.contains(#"id = "143""#))
        #expect(!text.contains("identity"))
        #expect(!text.contains("provider = jamfplatform"))
    }

    @Test func prunesUnselectedObjectsAndTheirImports() throws {
        let dir = try copyFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keep: Set<String> = ["jamfplatform_pro_script.jd_install_rosetta_2"]
        try ExportedObjectInventory.prune(directory: dir, keeping: keep)

        let after = try ExportedObjectInventory.scan(directory: dir)
        #expect(after.map(\.address) == ["jamfplatform_pro_script.jd_install_rosetta_2"])
        // The policy file and its import are gone; the script import stays.
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "pro_policy.tf").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "pro_policy_import.tf").path))
        let scriptImport = try String(contentsOf: dir.appending(path: "pro_script_import.tf"), encoding: .utf8)
        #expect(scriptImport.contains("jamfplatform_pro_script.jd_install_rosetta_2"))
    }
}

@Suite("Adopt preview semantics")
struct AdoptPreviewTests {
    @Test func importsAlwaysReadAsAdoptWithDiffsWhenChanging() throws {
        let planJSON = """
        {"format_version":"1.2","resource_changes":[
          {"address":"jamfplatform_pro_category.handmade","type":"jamfplatform_pro_category","name":"handmade",
           "change":{"actions":["no-op"],"before":{"name":"Ops"},"after":{"name":"Ops"},"importing":{"id":"7"}}},
          {"address":"jamfplatform_pro_script.handmade","type":"jamfplatform_pro_script","name":"handmade",
           "change":{"actions":["update"],"before":{"name":"Fix","priority":"BEFORE"},"after":{"name":"Fix","priority":"AFTER"},"importing":{"id":"9"}}}
        ]}
        """
        let plan = try JSONDecoder().decode(PlanFile.self, from: Data(planJSON.utf8))
        let summary = PreviewBuilder.build(plan: plan, diagnostics: [], blockNames: ["tenant": "Adopted objects"])
        #expect(summary.counts[.adopt] == 2)
        #expect(summary.counts[.update] == nil)
        let changing = try #require(summary.groups.flatMap(\.changes).first { !$0.fieldDiffs.isEmpty })
        #expect(changing.fieldDiffs.map(\.path) == ["priority"])
        #expect(!summary.hasDestructiveChanges)
    }
}

@Suite("Provider schema catalog")
struct SchemaCatalogTests {
    @Test func parsesRealSchemaIntoEditableTypes() throws {
        let catalog = try ProviderSchemaCatalog.parse(schemaJSON: fixtureData("providers-schema.json"))
        #expect(catalog.resourceTypes.count > 100)

        let category = try #require(catalog.resourceType(named: "jamfplatform_pro_category"))
        #expect(category.isFormEditable)
        let name = try #require(category.attributes.first { $0.name == "name" })
        #expect(name.required && name.kind == .string)
        let priority = try #require(category.attributes.first { $0.name == "priority" })
        #expect(priority.kind == .number)

        // Policies need nested objects, so the form flags them non-editable.
        let policy = try #require(catalog.resourceType(named: "jamfplatform_pro_policy"))
        #expect(!policy.isFormEditable)

        // Both providers present.
        #expect(catalog.resourceType(named: "jamfprotect_telemetry") != nil)
    }

    @Test func generatesOverrideHCL() throws {
        let catalog = try ProviderSchemaCatalog.parse(schemaJSON: fixtureData("providers-schema.json"))
        let category = catalog.resourceType(named: "jamfplatform_pro_category")!
        let name = category.attributes.first { $0.name == "name" }!
        let priority = category.attributes.first { $0.name == "priority" }!
        let hcl = OverrideGenerator.hcl(
            resourceType: "jamfplatform_pro_category",
            terraformName: "custom_ops",
            values: [(name, "JD - Ops"), (priority, "9")]
        )
        #expect(hcl.contains(#"resource "jamfplatform_pro_category" "custom_ops""#))
        #expect(hcl.contains(#"name = "JD - Ops""#))
        #expect(hcl.contains("priority = 9"))
    }
}

@Suite("Drift bindings")
struct DriftBindingTests {
    @Test func catalogBlocksDeclareBindings() throws {
        let catalog = try LoadedCatalog.load(from: CatalogTests.catalogURL)
        let updates = try #require(catalog.block(id: "software-updates"))
        #expect(updates.settingKey(
            forResourceType: "jamfplatform_blueprints_blueprint",
            fieldPath: "component_blocks[0].software_update_settings.deferral_major_period_days"
        ) == "deferral_major_days")
        #expect(updates.settingKey(forResourceType: "x", fieldPath: "y") == nil)
    }

    @Test func deepDiffsRecurseIntoObjectArraysWithRawValues() throws {
        let before = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"component_blocks":[{"software_update_settings":{"deferral_major_period_days":14,"notifications_enabled":true}}]}
        """.utf8))
        let after = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"component_blocks":[{"software_update_settings":{"deferral_major_period_days":30,"notifications_enabled":true}}]}
        """.utf8))
        let diffs = DriftReportBuilder.deepFieldDiffs(before: before, after: after)
        #expect(diffs.count == 1)
        let diff = try #require(diffs.first)
        #expect(diff.path == "component_blocks[0].software_update_settings.deferral_major_period_days")
        #expect(diff.rawAfter == "30")
    }
}

@Suite("Team secret encryption")
struct TeamCryptoTests {
    @Test func sealsForMultipleRecipientsAndOpensWithEach() throws {
        let alice = TeamCrypto.generateIdentity()
        let bob = TeamCrypto.generateIdentity()
        let payload = try JSONEncoder().encode(TenantSecretPayload(
            platformClientSecret: "s3cret",
            statePassphrase: "passphrase"
        ))

        let envelope = try TeamCrypto.seal(
            payload: payload,
            recipientPublicKeys: [alice.publicKey, bob.publicKey]
        )
        #expect(envelope.boxes.count == 2)
        // The repository only ever sees ciphertext.
        for box in envelope.boxes {
            #expect(!box.ciphertext.contains("s3cret"))
        }

        for identity in [alice, bob] {
            let opened = try TeamCrypto.open(envelope, identity: identity)
            let decoded = try JSONDecoder().decode(TenantSecretPayload.self, from: opened)
            #expect(decoded.platformClientSecret == "s3cret")
            #expect(decoded.statePassphrase == "passphrase")
        }
    }

    @Test func rejectsUnaddressedIdentity() throws {
        let alice = TeamCrypto.generateIdentity()
        let mallory = TeamCrypto.generateIdentity()
        let envelope = try TeamCrypto.seal(
            payload: Data("secret".utf8),
            recipientPublicKeys: [alice.publicKey]
        )
        #expect(throws: TeamCrypto.CryptoError.self) {
            try TeamCrypto.open(envelope, identity: mallory)
        }
    }

    @Test func envelopeRoundTripsThroughJSON() throws {
        let alice = TeamCrypto.generateIdentity()
        let envelope = try TeamCrypto.seal(payload: Data("x".utf8), recipientPublicKeys: [alice.publicKey])
        let encoded = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(TeamCrypto.Envelope.self, from: encoded)
        let opened = try TeamCrypto.open(decoded, identity: alice)
        #expect(opened == Data("x".utf8))
    }
}

@Suite("Error translation")
struct ErrorTranslationTests {
    @Test func translatesKnownErrors() {
        let translated = ErrorTranslation.translate("Error: API returned status 403 Forbidden for /v2/computer-prestages")
        #expect(translated.message.contains("permission"))
        #expect(translated.hint != nil)
    }

    @Test func translatesSecurityCloudEntitlement() {
        // The live-captured not-entitled error from an unentitled environment.
        let raw = "ListDeviceGroupsV2: API request failed with status 404 Not Found (url=https://us.api.jamfcloud.com/securitycloud/v2/groups): [TENANT_NOT_FOUND] No tenant found for environment 'x'."
        let translated = ErrorTranslation.translate(raw)
        #expect(translated.message.contains("Security Cloud"))
    }

    @Test func fallsBackGracefully() {
        let translated = ErrorTranslation.translate("some entirely novel failure")
        #expect(!translated.message.isEmpty)
    }
}
