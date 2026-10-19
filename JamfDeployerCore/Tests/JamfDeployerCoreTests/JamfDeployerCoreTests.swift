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
        let category = try #require(drifted.first { $0.address.contains("pro_category") })
        #expect(PreviewBuilder.fieldDiffs(for: category).map(\.path) == ["name"])
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
    // A catalog fixture: built-in blocks plus demo catalog blocks (with
    // their Jamf Pro API modules) and presets, frozen for the generator tests.
    static let catalogURL = Bundle.module.url(forResource: "Fixtures/test-catalog", withExtension: nil)!

    @Test func loadsAllBlocksAndPresets() throws {
        let catalog = try LoadedCatalog.load(from: Self.catalogURL)
        #expect(catalog.blocks.count == 11)
        let protect = try #require(catalog.block(id: "protect-baseline"))
        #expect(protect.products == ["jamf-protect"])
        #expect(protect.settings.contains { $0.key == "threat_mode" && $0.default == "Report only" })
        #expect(catalog.presets.count == 2)
        let groups = try #require(catalog.block(id: "device-groups"))
        #expect(groups.scope.kind == .none)
        #expect(groups.provides["device_group"]?.contains("Pilot") == true)
        let compliance = try #require(catalog.block(id: "compliance-cis-l1"))
        #expect(compliance.scope.kind == .platformGroup)
        #expect(compliance.settings.contains { $0.type == .enumeration && $0.enumValues?.count == 2 })
    }

    @Test func recordsWhichConnectionsEachBlockSupports() throws {
        let catalog = try LoadedCatalog.load(from: Self.catalogURL)
        // A Jamf Pro API module in jamfpro/ adds the connection.
        #expect(catalog.supports(blockID: "filevault", connection: .platform))
        #expect(catalog.supports(blockID: "filevault", connection: .jamfPro))
        #expect(catalog.supports(blockID: "app-catalog", connection: .jamfPro))
        // Platform-only features have no Jamf Pro API module.
        #expect(!catalog.supports(blockID: "compliance-cis-l1", connection: .jamfPro))
        #expect(!catalog.supports(blockID: "software-updates", connection: .jamfPro))
        #expect(!catalog.supports(blockID: "security-cloud", connection: .jamfPro))
        // Jamf Protect blocks use no Jamf Pro or Platform resources.
        #expect(catalog.supports(blockID: "protect-baseline", connection: .jamfPro))
        #expect(catalog.supports(blockID: "protect-baseline", connection: .platform))
        let filevault = try #require(catalog.block(id: "filevault"))
        #expect(filevault.jamfProPermissions.contains("Create Policies"))
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

    static func selection(
        _ catalog: LoadedCatalog, _ id: String, settings: [String: String] = [:], scope: String? = nil
    ) -> GeneratedSelection {
        let block = catalog.block(id: id)!
        return GeneratedSelection(
            block: block, settings: settings,
            providedScope: (scope ?? block.scope.default).flatMap(ProvidedObject.init(reference:)),
            providedCategory: block.defaultCategory.flatMap(ProvidedObject.init(reference:)))
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
                GeneratedSelection(block: provider, settings: [:]),
                GeneratedSelection(block: consumer, settings: [:]),
            ],
            providerVersion: "1.5.0"
        )
        let output = try WorkspaceGenerator.generate(input)
        #expect(output.mainTF.contains("dep_script_ids"))
        #expect(output.mainTF.contains("module.cap_scripts.script_ids"))
        #expect(output.mainTF.contains("module.cap_scripts.script_names"))
    }

    @Test func failsOnUnmetDependencies() throws {
        let consumer = try Self.metadata(
            #"{"id": "cap-policies", "name": "Policies", "needs": {"script": ["Missing Script"]}}"#)
        let input = WorkspaceInput(
            namePrefix: "JD - ",
            selections: [GeneratedSelection(block: consumer, settings: [:])],
            providerVersion: "1.5.0"
        )
        #expect(throws: WorkspaceGeneratorError.self) {
            _ = try WorkspaceGenerator.generate(input)
        }
    }

    @Test func refusesTwoBlocksOwningOneSetting() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ownership-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var selections: [GeneratedSelection] = []
        for id in ["checkin-a", "checkin-b"] {
            let folder = root.appending(path: id)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(#"resource "jamfplatform_pro_computer_check_in_settings" "singleton" {}"#.utf8)
                .write(to: folder.appending(path: "settings.tf"))
            selections.append(GeneratedSelection(
                block: try Self.metadata(#"{"id": "\#(id)", "name": "\#(id)"}"#),
                settings: [:], folderURL: folder))
        }
        let output = try WorkspaceGenerator.generate(WorkspaceInput(
            namePrefix: "JD - ", selections: selections, providerVersion: "1.5.0"))
        #expect(throws: WorkspaceGeneratorError.self) {
            try WorkspaceGenerator.materialize(
                output, selections: selections, catalog: try Self.catalog(),
                workspaceURL: root.appending(path: "workspace"))
        }
        // One owner is fine.
        try WorkspaceGenerator.materialize(
            output, selections: [selections[0]], catalog: try Self.catalog(),
            workspaceURL: root.appending(path: "workspace-single"))
    }

    @Test func generatesFullBaseline() throws {
        let catalog = try Self.catalog()
        let input = WorkspaceInput(
            namePrefix: "JD - ",
            selections: [
                Self.selection(catalog, "device-groups"),
                Self.selection(catalog, "categories"),
                Self.selection(catalog, "enrollment", settings: ["ade_instance_name": "Apple Business Manager"]),
                Self.selection(catalog, "filevault"),
                Self.selection(catalog, "software-updates", scope: "device-groups/Pilot"),
                Self.selection(catalog, "compliance-cis-l1", scope: "device-groups/Pilot"),
                Self.selection(catalog, "rosetta"),
            ],
            providerVersion: "1.5.0"
        )
        let output = try WorkspaceGenerator.generate(input)

        #expect(output.providersTF.contains("impact_alerts = true"))
        #expect(!output.providersTF.contains("jamfprotect"), "no Protect provider without Protect blocks")
        #expect(output.mainTF.contains(#"scope_jamf_pro_group_id = module.device_groups.device_group_jamf_pro_ids["Pilot"]"#))
        #expect(output.mainTF.contains(#"module.device_groups.device_group_ids["Pilot"]"#), "Platform-scoped blocks take Platform group IDs")
        #expect(output.mainTF.contains(#"module.device_groups.device_group_jamf_pro_ids["Apple Silicon Macs"]"#))
        #expect(output.mainTF.contains(#"category_id             = module.categories.category_ids["Security"]"#))
        let normalized = output.mainTF.replacingOccurrences(of: " +", with: " ", options: .regularExpression)
        #expect(normalized.contains(#"ade_instance_name = "Apple Business Manager""#))
        #expect(output.secretVariableNames.isEmpty)
    }

    @Test func jamfProTenantsUseEachBlocksJamfProModule() throws {
        let catalog = try Self.catalog()
        let selections = try WorkspaceGenerator.resolveModules(
            [Self.selection(catalog, "device-groups"), Self.selection(catalog, "categories"),
             Self.selection(catalog, "filevault"), Self.selection(catalog, "protect-baseline")],
            catalog: catalog, connection: .jamfPro)
        let output = try WorkspaceGenerator.generate(WorkspaceInput(
            namePrefix: "JD - ", selections: selections, providerVersion: "1.5.0", connection: .jamfPro))
        #expect(output.providersTF.contains(#"source  = "deploymenttheory/jamfpro""#))
        #expect(!output.providersTF.contains("jamfplatform"))
        #expect(output.providersTF.contains(#"provider "jamfprotect""#))
        #expect(output.mainTF.contains(#"source"#) && output.mainTF.contains(#""./modules/filevault/jamfpro""#))
        // A block without Jamf resources keeps its own folder.
        #expect(output.mainTF.contains(#""./modules/protect-baseline""#))
        #expect(output.mainTF.contains(#"module.device_groups.device_group_jamf_pro_ids["Pilot"]"#))

        // Blocks with no Jamf Pro API module are refused by name.
        #expect {
            try WorkspaceGenerator.resolveModules(
                [Self.selection(catalog, "software-updates", scope: "device-groups/Pilot")],
                catalog: catalog, connection: .jamfPro)
        } throws: { error in
            if case WorkspaceGeneratorError.unsupportedConnection(block: "Software Updates", connection: .jamfPro) = error { return true }
            return false
        }
        // Platform tenants keep the main module.
        let platform = try WorkspaceGenerator.resolveModules(
            [Self.selection(catalog, "filevault")], catalog: catalog, connection: .platform)
        #expect(platform.first?.modulePath == "")
    }

    @Test func teamWorkspacesUseTheHTTPStateBackend() throws {
        for connection in [ConnectionKind.platform, .jamfPro] {
            let solo = try WorkspaceGenerator.generate(WorkspaceInput(
                namePrefix: "JD - ", selections: [], providerVersion: "1.5.0", connection: connection))
            // The backend sits in the terraform block's body, two spaces in.
            #expect(solo.providersTF.contains("""

              # The tenant record lives next to the generated configuration,
              # encrypted via TF_ENCRYPTION, with automatic backups.
              backend "local" {
                path = "../state/terraform.tfstate"
              }
            }
            """))

            let team = try WorkspaceGenerator.generate(WorkspaceInput(
                namePrefix: "JD - ", selections: [], providerVersion: "1.5.0",
                connection: connection, stateBackend: .http))
            #expect(team.providersTF.contains("""

              # Team Mode: the state backend on this Mac stores the encrypted
              # record in the team repository and locks it while in use.
              # Its address and password come from TF_HTTP_* variables.
              backend "http" {
              }
            }
            """))
            #expect(!team.providersTF.contains("backend \"local\""))
            // Address and password come from TF_HTTP_* only.
            #expect(!team.providersTF.contains("address ="))
            #expect(!team.providersTF.contains("password ="))
        }
    }

    @Test func emitsProtectProviderForProtectBlocks() throws {
        let catalog = try Self.catalog()
        let input = WorkspaceInput(
            namePrefix: "JD - ",
            selections: [Self.selection(catalog, "protect-baseline")],
            providerVersion: "1.5.0"
        )
        let output = try WorkspaceGenerator.generate(input)
        #expect(output.providersTF.contains(#"source  = "Jamf-Concepts/jamfprotect""#))
        #expect(output.providersTF.contains(#"provider "jamfprotect""#))
    }

    @Test func refusesScopeFromAnUnselectedBlock() throws {
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
        #expect(WorkspaceGenerator.hclString("a\r\nb\tc") == #""a\r\nb\tc""#)
        #expect(BlockCapture.hclStringLiteral("a\r\nb\tc %{x}") == #""a\r\nb\tc %%{x}""#)
    }

    @Test func stringListsSplitCRLFInput() throws {
        let block = try Self.metadata(
            #"{"id": "lists", "name": "Lists", "settings": [{"key": "items", "title": "Items", "type": "list"}]}"#)
        let output = try WorkspaceGenerator.generate(WorkspaceInput(
            namePrefix: "JD - ",
            selections: [GeneratedSelection(block: block, settings: ["items": "one\r\ntwo\r\n"])],
            providerVersion: "1.5.0"))
        #expect(output.mainTF.contains(#"["one", "two"]"#))
    }

    @Test func errorsNameBlocksAndSettingsByTitle() throws {
        let catalog = try Self.catalog()
        let enrollment = try #require(catalog.block(id: "enrollment"))
        let setting = try #require(enrollment.settings.first { $0.key == "ade_instance_name" })
        #expect {
            try WorkspaceGenerator.generate(WorkspaceInput(
                namePrefix: "JD - ", selections: [Self.selection(catalog, "enrollment")], providerVersion: "1.5.0"))
        } throws: { error in
            guard case WorkspaceGeneratorError.missingRequiredSetting(let block, let title) = error else { return false }
            return block == enrollment.name && title == setting.title
        }
        let consumer = try Self.metadata(
            #"{"id": "cap-policies", "name": "Policies", "needs": {"script": ["Missing Script"]}}"#)
        #expect {
            try WorkspaceGenerator.generate(WorkspaceInput(
                namePrefix: "JD - ", selections: [GeneratedSelection(block: consumer, settings: [:])], providerVersion: "1.5.0"))
        } throws: { error in
            if case WorkspaceGeneratorError.unmetDependencies(block: "Policies", type: "script", names: ["Missing Script"]) = error { return true }
            return false
        }
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

    @Test func appsCarryTheirOwnCategory() throws {
        let apps = [
            AppCatalogApp(titleName: "Slack", publisher: "Slack", categoryID: "12", categoryName: "Communication"),
            AppCatalogApp(titleName: "Zoom", publisher: "Zoom"),
        ]
        let encoded = AppCatalogApp.encode(apps)
        #expect(encoded.contains(#""categoryId":"12""#))
        #expect(AppCatalogApp.decode(settingValue: encoded) == apps)
        // Lists saved before per-app categories still decode.
        let legacy = AppCatalogApp.decode(settingValue: #"[{"titleName":"Zoom","publisher":"Zoom","deploymentType":"SELF_SERVICE","updateBehavior":"AUTOMATIC"}]"#)
        #expect(legacy.first?.categoryID == nil)
    }

    @Test func generatorEmbedsAppsJSON() throws {
        let catalog = try LoadedCatalog.load(from: CatalogTests.catalogURL)
        let apps = AppCatalogApp.encode([AppCatalogApp(titleName: "Google Chrome", publisher: "Google")])
        let input = WorkspaceInput(
            namePrefix: "JD - ",
            selections: [
                GeneratedSelection(block: catalog.block(id: "device-groups")!, settings: [:]),
                GeneratedSelection(block: catalog.block(id: "app-catalog")!, settings: ["apps_json": apps],
                                   providedScope: ProvidedObject(blockID: "device-groups", name: "All Managed Macs")),
            ],
            providerVersion: "1.5.0"
        )
        let output = try WorkspaceGenerator.generate(input)
        #expect(output.mainTF.contains(#"module.device_groups.device_group_jamf_pro_ids["All Managed Macs"]"#))
        #expect(output.mainTF.contains("titleName") && output.mainTF.contains("Google Chrome"))
    }

    @Test func existingGroupAndCategory() throws {
        let catalog = try LoadedCatalog.load(from: CatalogTests.catalogURL)
        let block = try #require(catalog.block(id: "app-catalog"))
        let selection = GeneratedSelection(
            block: block, settings: [:],
            existingScopeID: "1", existingCategoryID: "467")
        let output = try WorkspaceGenerator.generate(WorkspaceInput(
            namePrefix: "JD - ", selections: [selection], providerVersion: "1.5.0"))
        #expect(output.mainTF.contains(/scope_jamf_pro_group_id\s*=\s*"1"/))
        #expect(output.mainTF.contains(/category_id\s*=\s*"467"/))
    }

    @Test func unchosenCategoryMeansNoCategory() throws {
        let catalog = try LoadedCatalog.load(from: CatalogTests.catalogURL)
        let block = try #require(catalog.block(id: "app-catalog"))
        let output = try WorkspaceGenerator.generate(WorkspaceInput(
            namePrefix: "JD - ",
            selections: [GeneratedSelection(block: block, settings: [:], existingScopeID: "1")],
            providerVersion: "1.5.0"))
        #expect(output.mainTF.contains(/category_id\s*=\s*"-1"/))
    }

    @Test func unchosenScopeIsReported() throws {
        let catalog = try LoadedCatalog.load(from: CatalogTests.catalogURL)
        let block = try #require(catalog.block(id: "app-catalog"))
        let input = WorkspaceInput(
            namePrefix: "JD - ",
            selections: [GeneratedSelection(block: block, settings: [:])],
            providerVersion: "1.5.0")
        #expect {
            try WorkspaceGenerator.generate(input)
        } throws: { error in
            if case WorkspaceGeneratorError.scopeNotChosen(block: block.name) = error { return true }
            return false
        }
    }

    @Test func presetsLeaveTenantSpecificScopesOut() throws {
        let catalog = try LoadedCatalog.load(from: CatalogTests.catalogURL)
        let preset = Preset.capturing(
            name: "Mixed", summary: "",
            selections: [.init(blockID: "app-catalog", settings: [:])],
            blocks: catalog.blocks)
        #expect(preset.scopes.isEmpty)
    }

    @Test func scopesAndCategoriesFromAnotherBlock() throws {
        let catalog = try LoadedCatalog.load(from: CatalogTests.catalogURL)
        var groups = try #require(catalog.block(id: "protect-baseline"))
        groups.id = "device-groups"
        groups.provides = ["device_group": ["All Macs"], "category": ["Apps"]]
        let appCatalog = try #require(catalog.block(id: "app-catalog"))
        let selection = GeneratedSelection(
            block: appCatalog, settings: [:],
            providedScope: ProvidedObject(blockID: "device-groups", name: "All Macs"),
            providedCategory: ProvidedObject(blockID: "device-groups", name: "Apps"))
        let output = try WorkspaceGenerator.generate(WorkspaceInput(
            namePrefix: "JD - ",
            selections: [GeneratedSelection(block: groups, settings: [:]), selection],
            providerVersion: "1.5.0"))
        #expect(output.mainTF.contains(#"module.device_groups.device_group_jamf_pro_ids["All Macs"]"#))
        #expect(output.mainTF.contains(#"module.device_groups.category_ids["Apps"]"#))

        // The providing block must be selected and create the named object.
        #expect(throws: WorkspaceGeneratorError.self) {
            try WorkspaceGenerator.generate(WorkspaceInput(
                namePrefix: "JD - ", selections: [selection], providerVersion: "1.5.0"))
        }
        #expect(ProvidedObject(reference: "device-groups/All Macs") == ProvidedObject(blockID: "device-groups", name: "All Macs"))
        #expect(ProvidedObject(reference: "all_macs") == nil)
    }

    @Test func presetsCarryProvidedReferences() throws {
        let catalog = try LoadedCatalog.load(from: CatalogTests.catalogURL)
        var groups = try #require(catalog.block(id: "protect-baseline"))
        groups.id = "device-groups"
        let preset = Preset.capturing(
            name: "Wired", summary: "",
            selections: [
                .init(blockID: "device-groups", settings: [:]),
                .init(blockID: "app-catalog", settings: [:],
                      providedScope: ProvidedObject(blockID: "device-groups", name: "All Macs"),
                      providedCategory: ProvidedObject(blockID: "elsewhere", name: "Apps")),
            ],
            blocks: catalog.blocks + [groups])
        #expect(preset.scopes == ["app-catalog": "device-groups/All Macs"])
        #expect(preset.categories.isEmpty)
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

@Suite("Drift field comparison")
struct DriftFieldTests {
    @Test func unsetAndEmptyListsAreTheSame() {
        let before = JSONValue.object(["scope": .object(["computer_group_ids": .array([.number(5)]), "building_ids": .null])])
        let after = JSONValue.object(["scope": .object(["computer_group_ids": .array([.number(5)]), "building_ids": .array([])])])
        #expect(DriftReportBuilder.deepFieldDiffs(before: before, after: after).isEmpty)
        let changed = JSONValue.object(["scope": .object(["computer_group_ids": .array([.number(6)]), "building_ids": .array([])])])
        #expect(DriftReportBuilder.deepFieldDiffs(before: before, after: changed).map(\.path) == ["scope.computer_group_ids"])
    }

    @Test func objectListElementTurningNullIsReported() throws {
        let planJSON = """
        {"format_version":"1.2","resource_drift":[
          {"address":"jamfplatform_blueprints_blueprint.updates","type":"jamfplatform_blueprints_blueprint","name":"updates",
           "change":{"actions":["update"],
             "before":{"component_blocks":[{"kind":"a"},{"kind":"b"}]},
             "after":{"component_blocks":[{"kind":"a"},null]}}}
        ]}
        """
        let plan = try JSONDecoder().decode(PlanFile.self, from: Data(planJSON.utf8))
        let report = DriftReportBuilder.build(plan: plan, blockNames: [:])
        let object = try #require(report.objects.first)
        #expect(object.fields.map(\.path) == ["component_blocks"])
    }
}

@Suite("Block removals")
struct RemovalTests {
    @Test func emitsRemovedBlockForStopManaging() throws {
        let catalog = try LoadedCatalog.load(from: CatalogTests.catalogURL)
        let input = WorkspaceInput(
            namePrefix: "JD - ",
            selections: [GeneratedSelection(block: catalog.block(id: "device-groups")!, settings: [:])],
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

    @Test func handOverReleasesEveryBlock() throws {
        let input = WorkspaceInput(
            namePrefix: "JD - ",
            selections: [],
            providerVersion: "1.5.0",
            removals: [
                BlockRemoval(blockID: "device-groups", keepInJamf: true),
                BlockRemoval(blockID: "rosetta", keepInJamf: true),
            ]
        )
        let output = try WorkspaceGenerator.generate(input)
        #expect(output.mainTF.contains("from = module.device_groups"))
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

    @Test func smartGroupCriteriaOrderThroughDependencyMap() throws {
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "criteria-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }
        let full = FileManager.default.temporaryDirectory
            .appending(path: "criteria-src-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: exportFixtureURL(), to: full)
        defer { try? FileManager.default.removeItem(at: full) }

        // Split capture: the group lands in one block, the extension
        // attribute it names in another.
        let staging = FileManager.default.temporaryDirectory
            .appending(path: "criteria-staging-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: full, to: staging)
        defer { try? FileManager.default.removeItem(at: staging) }
        let objects = try ExportedObjectInventory.scan(directory: staging)
        let groupOnly = Set(objects.filter { $0.resourceType == "jamfplatform_device_group" }.map(\.address))
        try ExportedObjectInventory.prune(directory: staging, keeping: groupOnly)

        let split = try BlockCapture.capture(BlockCapture.Request(
            blockID: "criteria-groups",
            name: "Groups",
            summary: "Group slice.",
            namePrefix: "JD - ",
            sourceDirectory: staging,
            catalogRootDirectory: destination,
            resolutionDirectory: full
        ))
        let groups = try String(contentsOf: split.blockFolderURL.appending(path: "device_groups.tf"), encoding: .utf8)
        #expect(groups.contains(#"criteria = var.dep_extension_attribute_names["Rosetta installed"]"#))
        let variables = try String(contentsOf: split.blockFolderURL.appending(path: "variables.tf"), encoding: .utf8)
        #expect(variables.contains(#"variable "dep_extension_attribute_ids""#))
        #expect(variables.contains(#"variable "dep_extension_attribute_names""#))
        let manifest = try JSONSerialization.jsonObject(
            with: Data(contentsOf: split.blockFolderURL.appending(path: "block.json"))) as? [String: Any]
        #expect((manifest?["needs"] as? [String: [String]])?["extension_attribute"] == ["Rosetta installed"])

        // Same-block capture: the criteria reference the local resource so
        // the attribute is created first.
        let whole = try BlockCapture.capture(BlockCapture.Request(
            blockID: "criteria-all",
            name: "All",
            summary: "Whole export.",
            namePrefix: "JD - ",
            sourceDirectory: full,
            catalogRootDirectory: destination
        ))
        let local = try String(contentsOf: whole.blockFolderURL.appending(path: "device_groups.tf"), encoding: .utf8)
        #expect(local.contains("criteria = jamfplatform_pro_computer_extension_attribute.rosetta_installed.name"))
    }

    @Test func perTenantCaptureKeepsCrossBlockWiring() throws {
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "rebind-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }
        let full = FileManager.default.temporaryDirectory
            .appending(path: "rebind-src-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: exportFixtureURL(), to: full)
        defer { try? FileManager.default.removeItem(at: full) }

        // Split capture with per-tenant scope: scope and category collapse
        // to the block settings, but the script and package the policy uses
        // live in other blocks and must stay wired.
        let staging = FileManager.default.temporaryDirectory
            .appending(path: "rebind-staging-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: full, to: staging)
        defer { try? FileManager.default.removeItem(at: staging) }
        let objects = try ExportedObjectInventory.scan(directory: staging)
        let policyOnly = Set(objects.filter { $0.resourceType == "jamfplatform_pro_policy" }.map(\.address))
        try ExportedObjectInventory.prune(directory: staging, keeping: policyOnly)

        let result = try BlockCapture.capture(BlockCapture.Request(
            blockID: "rebind-policy",
            name: "Policy",
            summary: "Policy slice with a per-tenant scope.",
            namePrefix: "JD - ",
            sourceDirectory: staging,
            catalogRootDirectory: destination,
            rebind: .perTenant,
            resolutionDirectory: full
        ))
        let policy = try String(contentsOf: result.blockFolderURL.appending(path: "pro_policy.tf"), encoding: .utf8)
        #expect(policy.contains("category_id = var.category_id"))
        #expect(policy.contains("computer_group_ids = [var.scope_jamf_pro_group_id]"))
        #expect(policy.contains(#"var.dep_script_ids["JD - Install Rosetta 2"]"#))
        #expect(policy.contains(#"var.dep_package_ids["JD - Test Package"]"#))

        let manifest = try JSONSerialization.jsonObject(
            with: Data(contentsOf: result.blockFolderURL.appending(path: "block.json"))) as? [String: Any]
        let needs = manifest?["needs"] as? [String: [String]]
        #expect(needs?["script"] == ["JD - Install Rosetta 2"])
        #expect(needs?["package"] == ["JD - Test Package"])
        #expect(needs?["category"] == nil)
        #expect((manifest?["requires"] as? [String]) == [])
    }

    /// Exclusions keep their captured wiring: only targets collapse onto the
    /// per-tenant scope, or the policy would exclude its own target group.
    @Test func perTenantCaptureLeavesExclusionsAlone() throws {
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "exclusions-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }
        let source = FileManager.default.temporaryDirectory
            .appending(path: "exclusions-src-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: exportFixtureURL(), to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let policyURL = source.appending(path: "pro_policy.tf")
        let original = try String(contentsOf: policyURL, encoding: .utf8)
        try original.replacingOccurrences(
            of: "exclusions = {\n      computer_group_ids = []",
            with: "exclusions = {\n      computer_group_ids = [\"70\"]"
        ).write(to: policyURL, atomically: true, encoding: .utf8)

        let result = try BlockCapture.capture(BlockCapture.Request(
            blockID: "exclusions-block",
            name: "Exclusions",
            summary: "Policy with an exclusion.",
            namePrefix: "JD - ",
            sourceDirectory: source,
            catalogRootDirectory: destination,
            rebind: .perTenant
        ))
        let policy = try String(contentsOf: result.blockFolderURL.appending(path: "pro_policy.tf"), encoding: .utf8)
        let exclusions = try #require(policy.range(of: #"exclusions = \{[^}]*\}"#, options: .regularExpression))
        #expect(!policy[exclusions].contains("var.scope_jamf_pro_group_id"))
        #expect(policy.contains("computer_group_ids = [var.scope_jamf_pro_group_id]"))
    }

    @Test func mentionsMatchesWholeAddressesOnly() {
        #expect(BlockCapture.mentions("icon_id = jamfplatform_pro_icon.icon_9.id", address: "jamfplatform_pro_icon.icon_9"))
        #expect(!BlockCapture.mentions("icon_id = jamfplatform_pro_icon.icon_99.id", address: "jamfplatform_pro_icon.icon_9"))
        #expect(!BlockCapture.mentions("x = jamfplatform_pro_script.foo_bar.id", address: "jamfplatform_pro_script.foo"))
    }

    @Test func outsideExclusionsSkipsNestedObjects() {
        let text = "a = 1\nexclusions = {\n  inner = { a = 1 }\n  a = 1\n}\na = 1"
        let result = BlockCapture.outsideExclusions(text) { $0.replacingOccurrences(of: "a = 1", with: "a = 2") }
        #expect(result == "a = 2\nexclusions = {\n  inner = { a = 1 }\n  a = 1\n}\na = 2")
    }

    @Test func prestigeWiresToDestinationEnrollmentInstance() throws {
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "prestage-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }
        let source = FileManager.default.temporaryDirectory
            .appending(path: "prestage-src-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: exportFixtureURL(), to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let result = try BlockCapture.capture(BlockCapture.Request(
            blockID: "prestage-block",
            name: "PreStage",
            summary: "Whole export including a PreStage.",
            namePrefix: "JD - ",
            sourceDirectory: source,
            catalogRootDirectory: destination
        ))
        let folder = result.blockFolderURL
        let prestige = try String(contentsOf: folder.appending(path: "pro_computer_prestage_enrollment.tf"), encoding: .utf8)
        #expect(prestige.contains("device_enrollment_program_instance_id = data.jamfplatform_pro_automated_device_enrollment.instance.id"))

        // The origin's instance resource is dropped (its token is not
        // exportable); the lookup file replaces it.
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "pro_automated_device_enrollment.tf").path))
        let lookup = try String(contentsOf: folder.appending(path: "enrollment_instance.tf"), encoding: .utf8)
        #expect(lookup.contains(#"default     = "Apple Business Manager""#))
        #expect(lookup.contains(#"data "jamfplatform_pro_automated_device_enrollment" "instance""#))

        let manifest = try JSONSerialization.jsonObject(
            with: Data(contentsOf: folder.appending(path: "block.json"))) as? [String: Any]
        let settings = manifest?["settings"] as? [[String: Any]]
        #expect(settings?.first?["key"] as? String == "ade_instance_name")
        #expect(settings?.first?["default"] as? String == "Apple Business Manager")
        #expect(result.warnings.contains { $0.contains("Automated Device Enrollment instance") })

        // Recovery Lock passwords are not exportable; the capture turns the
        // feature off rather than shipping a PreStage that cannot be created.
        #expect(prestige.range(of: #"enable_recovery_lock\s+= false"#, options: .regularExpression) != nil)
        #expect(result.warnings.contains { $0.contains("Recovery Lock") })
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
            rebind: .perTenant
        ))

        #expect(result.objectCount == 9)
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
        #expect(result.warnings.contains { $0.contains("Left out 2 objects") })

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
        #expect(metadata.requires.isEmpty)
        #expect(metadata.scope.default == nil)
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
        #expect(markdown.contains("**11 objects**"))
    }
}

@Suite("Catalog merging")
struct CatalogMergeTests {
    /// Catalog values end up in generated configuration and paths, so a
    /// block with an unsafe ID or setting key is skipped.
    @Test func rejectsBlocksWithUnsafeIdentifiers() throws {
        let official = try LoadedCatalog.load(from: CatalogTests.catalogURL)
        var block = try #require(official.blocks.first)
        #expect(LoadedCatalog.hasSafeIdentifiers(block))
        block.id = "evil\" { }"
        #expect(!LoadedCatalog.hasSafeIdentifiers(block))
        block.id = "../escape"
        #expect(!LoadedCatalog.hasSafeIdentifiers(block))
    }

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
        var custom = try LoadedCatalog.load(from: customRoot)
        custom.sourceID = "source-1"

        let merged = LoadedCatalog.merge([official, custom])
        #expect(merged.blocks.count == official.blocks.count + 1)
        // Selections record where a block comes from, so release pins apply.
        #expect(merged.sourceIDByBlockID["captured-rosetta"] == "source-1")
        #expect(official.blocks.allSatisfy { merged.sourceIDByBlockID[$0.id] == nil })
        #expect(merged.block(id: "captured-rosetta") != nil)
        #expect(merged.sourceName(for: "captured-rosetta") == "My Blocks")
        #expect(merged.sourceName(for: "device-groups") == "Built-in")
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
        #expect(objects.count == 11)
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

    @Test func unsetAndEmptyListsAreNotShownAsChanges() throws {
        let planJSON = """
        {"format_version":"1.2","resource_changes":[
          {"address":"jamfplatform_pro_script.fix","type":"jamfplatform_pro_script","name":"fix",
           "change":{"actions":["update"],"before":{"name":"Fix","ids":null,"tags":[]},"after":{"name":"Fixed","ids":[],"tags":null}}}
        ]}
        """
        let plan = try JSONDecoder().decode(PlanFile.self, from: Data(planJSON.utf8))
        let change = try #require(plan.resourceChanges?.first)
        #expect(PreviewBuilder.fieldDiffs(for: change).map(\.path) == ["name"])
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

        // Numbers are written unquoted, so anything else becomes null.
        let injected = OverrideGenerator.hcl(
            resourceType: "jamfplatform_pro_category", terraformName: "custom_ops",
            values: [(priority, "9\n  name = \"x\"")])
        #expect(injected.contains("priority = null"))
        #expect(!injected.contains(#"name = "x""#))
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

    /// Drift reports are saved with the tenant record, so sensitive values
    /// must be masked at every depth.
    @Test func deepDiffsMaskSensitiveValuesInListsAndWholeObjects() throws {
        func json(_ text: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }
        let listDiffs = DriftReportBuilder.deepFieldDiffs(
            before: try json(#"{"local_accounts":[{"name":"admin","password":"old"}]}"#),
            after: try json(#"{"local_accounts":[{"name":"admin","password":"new"}]}"#),
            beforeSensitive: try json(#"{"local_accounts":[{"password":true}]}"#),
            afterSensitive: try json(#"{"local_accounts":[{"password":true}]}"#)
        )
        #expect(listDiffs.count == 1)
        #expect(listDiffs.first?.after == "••••••")
        #expect(listDiffs.first?.rawAfter == nil)

        let objectDiffs = DriftReportBuilder.deepFieldDiffs(
            before: try json(#"{"credentials":{"secret":"old"}}"#),
            after: try json(#"{"credentials":{"secret":"new"}}"#),
            beforeSensitive: try json(#"{"credentials":true}"#),
            afterSensitive: try json(#"{"credentials":true}"#)
        )
        #expect(objectDiffs.count == 1)
        #expect(!objectDiffs.contains { $0.before.contains("old") || $0.after.contains("new") })
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

    @Test func translatesExistingUEMConnect() {
        // Captured live on a tenant already linked to Jamf Pro.
        let raw = "Error: A UEM Connect integration already exists for this tenant ... A connector already exists for the customer with an incompatible UEM vendor."
        let translated = ErrorTranslation.translate(raw)
        #expect(translated.message.contains("already connected"))
        #expect(translated.hint?.contains("Use the existing connection") == true)
    }

    @Test func translatesMissingUEMConnect() {
        let translated = ErrorTranslation.translate("Error: No UEM Connect integration on this tenant")
        #expect(translated.message.contains("not connected"))
        #expect(translated.hint?.contains("Connect this Jamf Pro tenant") == true)
    }

    @Test func fallsBackGracefully() {
        let translated = ErrorTranslation.translate("some entirely novel failure")
        #expect(!translated.message.isEmpty)
    }
}

@Suite("Plan redaction")
struct PlanRedactionTests {
    @Test func masksSensitiveValuesFromRealEngineOutput() throws {
        // Captured from `tofu show -json`: a sensitive root variable passed
        // into a module, the way secret block settings are wired.
        let raw = fixtureData("plan-with-secret.json")
        #expect(String(decoding: raw, as: UTF8.self).contains("SUPERSECRET-123"))

        let redacted = try #require(PlanRedactor.redact(raw))
        let text = String(decoding: redacted, as: UTF8.self)
        #expect(!text.contains("SUPERSECRET-123"))
        #expect(text.contains(PlanRedactor.placeholder))
        // Non-sensitive content survives, and the result still decodes as a plan.
        #expect(text.contains("module.blk.terraform_data.x"))
        _ = try JSONDecoder().decode(PlanFile.self, from: redacted)
    }

    @Test func adoptionKeepsObjectsReferencedByJamfProID() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "refs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("""
        resource "jamfplatform_pro_policy" "p" {
          scope = { computer_group_ids = [jamfplatform_device_group.g.jamf_pro_id] }
          category_id = jamfplatform_pro_category.c.id
        }

        resource "jamfplatform_device_group" "g" {
          name = "Group"
        }

        resource "jamfplatform_pro_category" "c" {
          name = "Cat"
        }
        """.utf8).write(to: directory.appending(path: "main.tf"))
        let policy = "jamfplatform_pro_policy.p", group = "jamfplatform_device_group.g"
        let pulled = ExportedObjectInventory.adoptableSelection(directory: directory, kept: [policy])
        #expect(pulled.kept == [policy, group] && pulled.leftOut.isEmpty)
        // Already adopted: referenced as it is.
        let managed = ExportedObjectInventory.adoptableSelection(directory: directory, kept: [policy], alreadyManaged: [group])
        #expect(managed.kept == [policy])
        // Cannot be adopted: neither can the policy that needs it.
        let blocked = ExportedObjectInventory.adoptableSelection(directory: directory, kept: [policy], unavailable: [group])
        #expect(blocked.kept.isEmpty && blocked.leftOut == [policy])
    }

    @Test func masksDriftAndDropsUnknownSections() throws {
        let raw = Data(#"""
        {"format_version":"1.2",
         "resource_drift":[{"address":"a.b","change":{"actions":["update"],
           "before":{"password":"OLD-SECRET"},"after":{"password":"NEW-SECRET"},
           "before_sensitive":{"password":true},"after_sensitive":{"password":true}}}],
         "future_section":{"value":"UNKNOWN-SECRET"}}
        """#.utf8)
        let text = String(decoding: try #require(PlanRedactor.redact(raw)), as: UTF8.self)
        #expect(!text.contains("OLD-SECRET") && !text.contains("NEW-SECRET"))
        #expect(!text.contains("UNKNOWN-SECRET"))
        #expect(text.contains("a.b"))
    }

    @Test func masksNestedPathsOnly() {
        let value: [String: Any] = ["name": "visible", "payload": ["password": "p", "user": "u"]]
        let mask: [String: Any] = ["payload": ["password": true]]
        let result = PlanRedactor.masked(value, mask) as? [String: Any]
        #expect(result?["name"] as? String == "visible")
        let payload = result?["payload"] as? [String: Any]
        #expect(payload?["password"] as? String == PlanRedactor.placeholder)
        #expect(payload?["user"] as? String == "u")
    }
}

@Suite("Create-failure recovery")
struct CreateFailureRecoveryTests {
    static let plan = #"""
    {"format_version":"1.2","resource_changes":[
      {"address":"module.cap.jamfplatform_pro_policy.flush_dns","type":"jamfplatform_pro_policy","name":"flush_dns",
       "change":{"actions":["create"],"after":{"general":{"name":"[Self Service] Flush DNS cache"}}}},
      {"address":"module.cap.jamfplatform_pro_patch_software_title.chrome","type":"jamfplatform_pro_patch_software_title","name":"chrome",
       "change":{"actions":["create"],"after":{"name":"Google Chrome"}}},
      {"address":"module.cap.jamfplatform_pro_app_installer.zoom","type":"jamfplatform_pro_app_installer","name":"zoom",
       "change":{"actions":["create"],"after":{"name":"Zoom"}}},
      {"address":"module.cap.jamfplatform_pro_policy.renamed","type":"jamfplatform_pro_policy","name":"renamed",
       "change":{"actions":["update"],"after":{"general":{"name":"Renamed"}}}}
    ]}
    """#

    static func diagnostic(_ address: String, _ summary: String, _ detail: String) throws -> EngineStreamEvent.Diagnostic {
        let json = #"{"severity":"error","summary":"\#(summary)","detail":"\#(detail)","address":"\#(address)"}"#
        return try JSONDecoder().decode(EngineStreamEvent.Diagnostic.self, from: Data(json.utf8))
    }

    @Test func recognizesJamfProPluginFailures() throws {
        let plan = try JSONDecoder().decode(PlanFile.self, from: Data(#"""
        {"format_version":"1.2","resource_changes":[
          {"address":"module.cap.jamfpro_policy.flush_dns","type":"jamfpro_policy","name":"flush_dns",
           "change":{"actions":["create"],"after":{"name":"Flush DNS cache"}}}
        ]}
        """#.utf8))
        let failed = try Self.diagnostic("module.cap.jamfpro_policy.flush_dns",
            "failed to create Jamf Pro Policy 'Flush DNS cache' after retries: {\\\"status_code\\\":502,\\\"method\\\":\\\"POST\\\"}", "")
        let conflict = try Self.diagnostic("module.cap.jamfpro_policy.flush_dns",
            "failed to create Jamf Pro Policy 'Flush DNS cache' after retries: {\\\"status_code\\\":409}", "")
        #expect(CreateFailureRecovery.candidates(diagnostics: [failed], plan: plan).map(\.name) == ["Flush DNS cache"])
        #expect(CreateFailureRecovery.candidates(diagnostics: [conflict], plan: plan).isEmpty)
    }

    @Test func picksOnlyRecoverableServerErrorsOnCreate() throws {
        let plan = try JSONDecoder().decode(PlanFile.self, from: Data(Self.plan.utf8))
        let diagnostics = [
            try Self.diagnostic("module.cap.jamfplatform_pro_policy.flush_dns", "Error creating Jamf Pro policy",
                                "CreatePolicyByID(0): API request failed with status 500 Internal Server Error"),
            try Self.diagnostic("module.cap.jamfplatform_pro_patch_software_title.chrome", "Error creating Jamf Pro patch software title",
                                "API request failed with status 500 Internal Server Error"),
            // Gateway timeouts can leave the object behind too.
            try Self.diagnostic("module.cap.jamfplatform_pro_app_installer.zoom", "Error creating App Installer deployment",
                                "API request failed with status 504 Gateway Timeout"),
            // Not a server error.
            try Self.diagnostic("module.cap.jamfplatform_pro_policy.flush_dns", "Error creating Jamf Pro policy",
                                "status 409 Conflict: Duplicate name"),
            // Updates are never recovered.
            try Self.diagnostic("module.cap.jamfplatform_pro_policy.renamed", "Error creating Jamf Pro policy", "status 500"),
        ]
        let candidates = CreateFailureRecovery.candidates(diagnostics: diagnostics, plan: plan)
        #expect(candidates.map(\.address) == [
            "module.cap.jamfplatform_pro_policy.flush_dns",
            "module.cap.jamfplatform_pro_patch_software_title.chrome",
            "module.cap.jamfplatform_pro_app_installer.zoom",
        ])
        #expect(CreateFailureRecovery.lookupQuery(for: candidates[2]).first?.name == "page-size")
        #expect(candidates.first?.name == "[Self Service] Flush DNS cache")
        #expect(CreateFailureRecovery.lookupPath(for: candidates[0]) == "/proclassic/policies/name/[Self Service] Flush DNS cache")
        #expect(CreateFailureRecovery.lookupPath(for: candidates[1]) == "/proclassic/patchsoftwaretitles")
    }

    @Test func readsIDsFromLookupsAndRendersImports() throws {
        let policy = CreateFailureRecovery.Candidate(
            address: "module.cap.jamfplatform_pro_policy.flush_dns",
            resourceType: "jamfplatform_pro_policy", name: "[Self Service] Flush DNS cache")
        let found = Data(#"{"policy":{"general":{"id":625,"name":"[Self Service] Flush DNS cache"}}}"#.utf8)
        #expect(CreateFailureRecovery.objectID(in: found, for: policy) == "625")
        let other = Data(#"{"policy":{"general":{"id":1,"name":"Something else"}}}"#.utf8)
        #expect(CreateFailureRecovery.objectID(in: other, for: policy) == nil)

        let title = CreateFailureRecovery.Candidate(
            address: "module.cap.jamfplatform_pro_patch_software_title.chrome",
            resourceType: "jamfplatform_pro_patch_software_title", name: "Google Chrome")
        let list = Data(#"{"patch_software_titles":[{"id":"102","name":"Apple macOS Sonoma"},{"id":"103","name":"Google Chrome"}]}"#.utf8)
        #expect(CreateFailureRecovery.objectID(in: list, for: title) == "103")

        // Duplicate names: the one the state already tracks is never taken,
        // and two untracked matches are too ambiguous to adopt.
        let installer = CreateFailureRecovery.Candidate(
            address: "module.cap.jamfplatform_pro_app_installer.figma_2",
            resourceType: "jamfplatform_pro_app_installer", name: "Figma")
        let deployments = Data(#"{"results":[{"id":"10","name":"Figma"},{"id":"11","name":"Figma"},{"id":"12","name":"Zoom"}]}"#.utf8)
        #expect(CreateFailureRecovery.objectID(in: deployments, for: installer, excluding: ["10"]) == "11")
        #expect(CreateFailureRecovery.objectID(in: deployments, for: installer) == nil)
        #expect(CreateFailureRecovery.objectID(in: found, for: policy, excluding: ["625"]) == nil)

        let state = Data(#"{"values":{"root_module":{"child_modules":[{"resources":[{"type":"jamfplatform_pro_app_installer","values":{"id":"10"}}]}]}}}"#.utf8)
        #expect(CreateFailureRecovery.managedIDs(stateJSON: state)["jamfplatform_pro_app_installer"] == ["10"])

        let file = CreateFailureRecovery.importFile([(policy.address, "625")])
        #expect(file.contains("to = module.cap.jamfplatform_pro_policy.flush_dns"))
        #expect(file.contains(#"id = "625""#))
    }
}

@Suite("Server error translation")
struct ServerErrorTranslationTests {
    @Test func translatesTransientServerErrors() {
        for raw in [
            "Error creating Jamf Pro policy\nCreatePolicyByID(0): API request failed with status 500 Internal Server Error",
            "Error creating Jamf Pro patch software title\nAPI request failed with status 504 Gateway Timeout",
        ] {
            #expect(ErrorTranslation.translateIfKnown(raw)?.message == "Jamf had a temporary server problem with this object.")
        }
    }
}

@Suite("Saving presets")
struct PresetCaptureTests {
    static let blocks: [BlockMetadata] = [
        try! JSONDecoder().decode(BlockMetadata.self, from: Data(#"""
        {"id":"checkin","name":"Check-in","scope":{"kind":"none"},
         "settings":[{"key":"check_in_frequency","type":"enum","default":"15"},
                     {"key":"api_key","type":"secret"}]}
        """#.utf8)),
        try! JSONDecoder().decode(BlockMetadata.self, from: Data(#"""
        {"id":"rosetta","name":"Rosetta","scope":{"kind":"jamfProGroup","variable":"scope_jamf_pro_group_id","default":"device-groups/Apple Silicon Macs"},"settings":[]}
        """#.utf8)),
    ]

    @Test func keepsOnlyChangesAndNeverSecrets() throws {
        let preset = Preset.capturing(
            name: "Office Macs — 2026",
            summary: "Our standard.",
            selections: [
                .init(blockID: "device-groups", settings: [:]),
                .init(blockID: "checkin", settings: ["check_in_frequency": "30", "api_key": "s3cret"]),
                .init(blockID: "rosetta", settings: [:], providedScope: ProvidedObject(blockID: "device-groups", name: "Laptops")),
            ],
            blocks: Self.blocks)
        #expect(preset.id == "office-macs-2026")
        #expect(preset.blocks == ["device-groups", "checkin", "rosetta"])
        #expect(preset.defaults == ["checkin": ["check_in_frequency": "30"]])
        #expect(preset.scopes == ["rosetta": "device-groups/Laptops"])

        // Round-trips through JSON; presets without scopes decode.
        let data = try JSONEncoder().encode(preset)
        #expect(!String(decoding: data, as: UTF8.self).contains("s3cret"))
        #expect(try JSONDecoder().decode(Preset.self, from: data) == preset)
        let minimal = try JSONDecoder().decode(Preset.self, from: Data(#"{"id":"minimal","blocks":["device-groups"]}"#.utf8))
        #expect(minimal.scopes.isEmpty)
    }

    @Test func savedPresetLoadsFromAFolderSource() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "preset-src-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "presets"), withIntermediateDirectories: true)
        try Data(#"{"id":"mine","name":"Mine","schemaVersion":1}"#.utf8).write(to: root.appending(path: "catalog.json"))

        let preset = Preset.capturing(
            name: "Office Macs", summary: "",
            selections: [
                .init(blockID: "device-groups", settings: [:]),
                .init(blockID: "rosetta", settings: [:], providedScope: ProvidedObject(blockID: "device-groups", name: "Laptops")),
            ],
            blocks: Self.blocks)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(preset).write(to: root.appending(path: "presets/\(preset.id).json"))

        let catalog = try LoadedCatalog.load(from: root)
        #expect(catalog.presets == [preset])
        #expect(catalog.presets.first?.scopes["rosetta"] == "device-groups/Laptops")
    }

    @Test func unchangedDefaultsStayOut() {
        let preset = Preset.capturing(
            name: "", summary: "",
            selections: [
                .init(blockID: "device-groups", settings: [:]),
                .init(blockID: "checkin", settings: ["check_in_frequency": "15"]),
                .init(blockID: "rosetta", settings: [:], providedScope: ProvidedObject(blockID: "device-groups", name: "Apple Silicon Macs")),
            ],
            blocks: Self.blocks)
        #expect(preset.id == "preset")
        #expect(preset.defaults.isEmpty)
        #expect(preset.scopes.isEmpty)
    }
}

@Suite("Captured block metadata")
struct CapturedMetadataTests {
    @Test func permissionsComePerResourceType() throws {
        let url = fixtureURL("permissions-table.md")
        let byType = BlockCapture.parsePermissionsByType(at: url)
        #expect(byType["jamfplatform_pro_re_enrollment_settings"] == ["re-enrollment:read"])
        #expect(byType["jamfplatform_pro_category"] == ["categories:read", "self-service:read"])
        #expect(byType["jamfplatform_pro_icon"] == nil)
    }

    @Test func labelsReadAsPlainLanguage() {
        #expect(BlockCapture.objectLabel(for: "jamfplatform_pro_macos_configuration_profile") == "macOS configuration profile")
        #expect(BlockCapture.objectLabel(for: "jamfplatform_pro_app_installer_settings") == "App installer settings")
        #expect(BlockCapture.objectLabel(for: "jamfplatform_device_group") == "Device group")
        #expect(BlockCapture.objectLabel(for: "jamfplatform_pro_sso_failover_url") == "SSO failover URL")
    }
}

@Suite("Adopting existing objects")
struct AdoptPreparationTests {
    static func export() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "adopt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"""
        resource "jamfplatform_pro_automated_device_enrollment" "abm" {
          name         = "Apple Business Manager"
          server_token = var.abm_server_token
        }

        resource "jamfplatform_pro_computer_prestage_enrollment" "default" {
          display_name                          = "Default"
          device_enrollment_program_instance_id = jamfplatform_pro_automated_device_enrollment.abm.id
        }

        resource "jamfplatform_pro_icon" "icon_1" {
          icon_file_source = var.icon_1_source
        }

        resource "jamfplatform_pro_computer_invitation" "all_0" {
          invitation_type = "DEP_ENROLL"
        }
        """#.utf8).write(to: dir.appending(path: "main.tf"))
        try Data(#"""
        import {
          identity = {
            id = "7"
          }
          to = jamfplatform_pro_automated_device_enrollment.abm
        }
        """#.utf8).write(to: dir.appending(path: "main_import.tf"))
        try Data(#"""
        variable "abm_server_token" {
          type      = string
          sensitive = true
        }

        variable "icon_1_source" {
          type    = string
          default = "support_files/icons/icon_1.png"
        }
        """#.utf8).write(to: dir.appending(path: "variables.tf"))
        return dir
    }

    @Test func findsObjectsTheAppCannotManage() throws {
        let dir = try Self.export()
        defer { try? FileManager.default.removeItem(at: dir) }
        let unmanageable = ExportedObjectInventory.unmanageable(directory: dir)
        #expect(Set(unmanageable.keys) == [
            "jamfplatform_pro_automated_device_enrollment.abm",
            "jamfplatform_pro_computer_invitation.all_0",
        ])
    }

    @Test func pinsReferencesAndInlinesValues() throws {
        let dir = try Self.export()
        defer { try? FileManager.default.removeItem(at: dir) }
        let kept: Set<String> = ["jamfplatform_pro_computer_prestage_enrollment.default", "jamfplatform_pro_icon.icon_1"]
        try ExportedObjectInventory.pinReferences(directory: dir, keeping: kept)
        try ExportedObjectInventory.inlineVariables(directory: dir)
        let text = try String(contentsOf: dir.appending(path: "main.tf"), encoding: .utf8)
        #expect(text.contains(#"device_enrollment_program_instance_id = "7""#))
        #expect(text.contains(#"icon_file_source = "support_files/icons/icon_1.png""#))
    }
}

@Suite("Drift noise")
struct DriftNoiseTests {
    @Test func categoryNameMirrorsAreNotActionable() {
        #expect(DriftReportBuilder.isComputed("general.category_name"))
        #expect(DriftReportBuilder.isComputed("self_service.categories[0].name"))
        #expect(DriftReportBuilder.isComputed("self_service.categories[12].name"))
        #expect(!DriftReportBuilder.isComputed("self_service.categories[0].display_in"))
        #expect(!DriftReportBuilder.isComputed("general.name"))
    }
}

@Suite("Mobile devices")
struct MobileDeviceTests {
    /// A minimal export: a mobile profile scoped to a mobile group, the group
    /// itself, Jamf's Device Compliance group, and a mobile PreStage whose
    /// enrollment customization is not part of the export.
    static func writeExport(includingComputerPolicy: Bool = false) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "mobile-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let files: [String: String] = [
            "device_groups.tf": """
            resource "jamfplatform_device_group" "tagged_ipads_mobile" {
              device_type = "mobile"
              group_type  = "smart"
              name        = "Tagged iPads"
            }

            resource "jamfplatform_device_group" "jamf_device_compliance_group_computer" {
              device_type = "computer"
              group_type  = "smart"
              name        = "Jamf Device Compliance Group"
            }
            """,
            "pro_mobile_device_configuration_profile.tf": """
            resource "jamfplatform_pro_mobile_device_configuration_profile" "camera" {
              general = {
                category_id = "-1"
                name        = "Camera"
                payloads    = "<plist/>"
              }
              scope = {
                targets = {
                  mobile_device_group_ids = [
                    jamfplatform_device_group.tagged_ipads_mobile.jamf_pro_id,
                  ]
                }
              }
            }
            """,
            "pro_mobile_device_prestage_enrollment.tf": """
            resource "jamfplatform_pro_mobile_device_prestage_enrollment" "ipads" {
              display_name                = "iPads"
              enrollment_customization_id = "4"
              timezone                    = "UTC"
            }
            """,
        ]
        for (name, text) in files {
            try Data(text.utf8).write(to: directory.appending(path: name))
        }
        if includingComputerPolicy {
            try Data("""
            resource "jamfplatform_pro_policy" "p" {
              scope = {
                computer_group_ids = ["12"]
              }
            }
            """.utf8).write(to: directory.appending(path: "pro_policy.tf"))
        }
        return directory
    }

    @Test func portableCaptureChoosesMobileGroupPerTenant() throws {
        let source = try Self.writeExport()
        let catalog = FileManager.default.temporaryDirectory.appending(path: "mobile-dst-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: catalog) }
        let result = try BlockCapture.capture(BlockCapture.Request(
            blockID: "mobile", name: "Mobile", summary: "", namePrefix: "",
            sourceDirectory: source, catalogRootDirectory: catalog, rebind: .perTenant))
        #expect(result.usesJamfProMobileScope)
        let profile = try String(contentsOf: result.blockFolderURL.appending(path: "pro_mobile_device_configuration_profile.tf"), encoding: .utf8)
        #expect(profile.contains("mobile_device_group_ids = [var.scope_jamf_pro_mobile_group_id]"))
        let block = try JSONDecoder().decode(BlockMetadata.self, from: Data(contentsOf: result.blockFolderURL.appending(path: "block.json")))
        #expect(block.scope.kind == .jamfProMobileGroup)
        #expect(block.mobileDeviceGroups == ["Tagged iPads"])
        // Jamf's own Device Compliance group is looked up, never recreated.
        let groups = try String(contentsOf: result.blockFolderURL.appending(path: "device_groups.tf"), encoding: .utf8)
        #expect(!groups.contains("Jamf Device Compliance Group"))
        // The origin's enrollment customization ID means nothing elsewhere.
        let prestage = try String(contentsOf: result.blockFolderURL.appending(path: "pro_mobile_device_prestage_enrollment.tf"), encoding: .utf8)
        #expect(prestage.contains(#"enrollment_customization_id = "0""#))
        #expect(result.warnings.contains { $0.contains("enrollment customization") })
    }

    @Test func computerScopeWinsWhenBothArePresent() throws {
        let source = try Self.writeExport(includingComputerPolicy: true)
        let catalog = FileManager.default.temporaryDirectory.appending(path: "mobile-dst-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: catalog) }
        let result = try BlockCapture.capture(BlockCapture.Request(
            blockID: "mixed", name: "Mixed", summary: "", namePrefix: "",
            sourceDirectory: source, catalogRootDirectory: catalog, rebind: .perTenant))
        #expect(result.usesJamfProScope)
        #expect(!result.usesJamfProMobileScope)
        #expect(result.warnings.contains { $0.contains("Mobile device objects keep their captured groups") })
    }

    @Test func generatorWiresMobileScope() throws {
        let catalog = try LoadedCatalog.load(from: CatalogTests.catalogURL)
        var block = try #require(catalog.block(id: "app-catalog"))
        block.id = "mobile-profile"
        block.acceptsCategory = false
        block.scope = BlockScope(kind: .jamfProMobileGroup, variable: "scope_jamf_pro_mobile_group_id", default: nil)
        var groups = try #require(catalog.block(id: "protect-baseline"))
        groups.id = "mobile-groups"
        groups.provides = ["device_group": ["Supervised iPads"]]

        let existing = try WorkspaceGenerator.generate(WorkspaceInput(
            namePrefix: "",
            selections: [GeneratedSelection(block: block, settings: [:], existingScopeID: "2")], providerVersion: "1.5.0"))
        #expect(existing.mainTF.contains(/scope_jamf_pro_mobile_group_id\s*=\s*"2"/))

        let provided = try WorkspaceGenerator.generate(WorkspaceInput(
            namePrefix: "",
            selections: [
                GeneratedSelection(block: groups, settings: [:]),
                GeneratedSelection(block: block, settings: [:],
                                   providedScope: ProvidedObject(blockID: "mobile-groups", name: "Supervised iPads")),
            ], providerVersion: "1.5.0"))
        #expect(provided.mainTF.contains(#"module.mobile_groups.device_group_jamf_pro_ids["Supervised iPads"]"#))

    }

    @Test func adoptionProtectsPreStageSectionsTheExportLeavesOut() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "prestage-adopt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("""
        resource "jamfplatform_pro_mobile_device_prestage_enrollment" "ipads" {
          display_name = "iPads"
          names = {
            manage_names = true
          }
        }
        """.utf8).write(to: directory.appending(path: "pro_mobile_device_prestage_enrollment.tf"))
        try ExportedObjectInventory.protectOmittedSections(directory: directory)
        let text = try String(contentsOf: directory.appending(path: "pro_mobile_device_prestage_enrollment.tf"), encoding: .utf8)
        #expect(text.contains("ignore_changes = [location_information, purchasing_information, skip_setup_items]"))
        // Running it again changes nothing.
        try ExportedObjectInventory.protectOmittedSections(directory: directory)
        let again = try String(contentsOf: directory.appending(path: "pro_mobile_device_prestage_enrollment.tf"), encoding: .utf8)
        #expect(again == text)
    }

    @Test func appStoreAppsLicenseThroughTheDestinationsLocation() throws {
        let source = FileManager.default.temporaryDirectory.appending(path: "vpp-src-\(UUID().uuidString)")
        let catalog = FileManager.default.temporaryDirectory.appending(path: "vpp-dst-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: catalog) }
        try Data("""
        resource "jamfplatform_pro_mac_app_store_app" "word" {
          general = {
            name = "Microsoft Word"
          }
          vpp = {
            assign_vpp_device_based_licenses = true
            vpp_admin_account_id             = "3"
          }
        }

        resource "jamfplatform_pro_mac_app_store_app" "pages" {
          general = {
            name = "Pages"
          }
          vpp = {
            assign_vpp_device_based_licenses = false
            vpp_admin_account_id             = "-1"
          }
        }
        """.utf8).write(to: source.appending(path: "pro_mac_app_store_app.tf"))
        try Data("""
        resource "jamfplatform_pro_volume_purchasing_location" "abm" {
          name          = "Company Apps"
          service_token = var.token
        }
        """.utf8).write(to: source.appending(path: "pro_volume_purchasing_location.tf"))
        try Data("""
        import {
          to = jamfplatform_pro_volume_purchasing_location.abm
          id = "3"
        }
        """.utf8).write(to: source.appending(path: "pro_volume_purchasing_location_import.tf"))

        let result = try BlockCapture.capture(BlockCapture.Request(
            blockID: "apps", name: "Apps", summary: "", namePrefix: "",
            sourceDirectory: source, catalogRootDirectory: catalog))
        let apps = try String(contentsOf: result.blockFolderURL.appending(path: "pro_mac_app_store_app.tf"), encoding: .utf8)
        #expect(apps.contains("data.jamfplatform_pro_volume_purchasing_location.apps_and_books.id"))
        #expect(apps.contains(#"vpp_admin_account_id             = "-1""#))
        let lookup = try String(contentsOf: result.blockFolderURL.appending(path: "apps_and_books_location.tf"), encoding: .utf8)
        #expect(lookup.contains(#"default     = "Company Apps""#))
        let block = try JSONDecoder().decode(BlockMetadata.self, from: Data(contentsOf: result.blockFolderURL.appending(path: "block.json")))
        #expect(block.settings.map(\.key) == ["vpp_location_name"])
        #expect(ErrorTranslation.translate("409 Conflict: App is not available for device assignment").message.contains("Apps and Books"))
    }

    @Test func enrollmentCustomizationsLeaveOriginSpecificPartsBehind() throws {
        let source = FileManager.default.temporaryDirectory.appending(path: "ec-src-\(UUID().uuidString)")
        let catalog = FileManager.default.temporaryDirectory.appending(path: "ec-dst-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: catalog) }
        try Data("""
        resource "jamfplatform_pro_enrollment_customization" "welcome" {
          branding_settings = {
            background_color  = "FFFFFF"
            icon_url          = "https://origin.jamfcloud.com/api/v2/enrollment-customizations/images/1"
          }
          display_name = "Welcome"
          ldap_panes = [
            {
              display_name = "Sign in"
              directory_service_groups = [
                {
                  directory_service_server_id = "3"
                  group_name                  = "Staff"
                },
              ]
            },
          ]
        }
        """.utf8).write(to: source.appending(path: "pro_enrollment_customization.tf"))
        let result = try BlockCapture.capture(BlockCapture.Request(
            blockID: "ec", name: "EC", summary: "", namePrefix: "",
            sourceDirectory: source, catalogRootDirectory: catalog))
        let text = try String(contentsOf: result.blockFolderURL.appending(path: "pro_enrollment_customization.tf"), encoding: .utf8)
        #expect(!text.contains("ldap_panes"))
        #expect(!text.contains("directory_service_server_id"))
        #expect(text.contains("display_name = \"Welcome\""))
        #expect(result.warnings.contains { $0.contains("LDAP pane") })
        #expect(result.warnings.contains { $0.contains("hosted on the origin tenant") })
    }

    @Test func catalogsSkipBlocksFromNewerVersions() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "future-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for (id, scope) in [("today", "jamfProGroup"), ("future", "someFutureKind")] {
            let folder = root.appending(path: "blocks/\(id)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(#"{"id":"\#(id)","scope":{"kind":"\#(scope)"}}"#.utf8).write(to: folder.appending(path: "block.json"))
        }
        try Data(#"{"id":"c","name":"C","schemaVersion":1}"#.utf8).write(to: root.appending(path: "catalog.json"))
        let catalog = try LoadedCatalog.load(from: root)
        #expect(catalog.blocks.map(\.id) == ["today"])
        #expect(catalog.unreadableBlocks == ["future"])
    }

    @Test func mobileInvitationsAreNotAdopted() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "invite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("""
        resource "jamfplatform_pro_mobile_device_invitation" "i1" {
          invitation_type = "DEFAULT"
        }
        """.utf8).write(to: directory.appending(path: "pro_mobile_device_invitation.tf"))
        #expect(ExportedObjectInventory.unmanageable(directory: directory)["jamfplatform_pro_mobile_device_invitation.i1"] != nil)
    }
}

@Suite("Jamf Pro connection")
struct JamfProConnectionTests {
    @Test func jamfProWorkspaceUsesTheJamfProPluginOnly() throws {
        let output = try WorkspaceGenerator.generate(WorkspaceInput(
            namePrefix: "JD - ", selections: [], providerVersion: "1.5.0",
            connection: .jamfPro, jamfProProviderVersion: "0.42.0"
        ))
        #expect(output.providersTF.contains(#"source  = "deploymenttheory/jamfpro""#))
        #expect(output.providersTF.contains(#"version = "0.42.0""#))
        #expect(output.providersTF.contains(#"provider "jamfpro""#))
        #expect(!output.providersTF.contains("jamfplatform"))
        // Credentials come from the environment only.
        #expect(!output.providersTF.contains("password"))
        #expect(output.secretVariableNames.isEmpty)
    }

    @Test func jamfProWorkspaceHasNoPlatformPlugin() throws {
        let output = try WorkspaceGenerator.generate(WorkspaceInput(
            namePrefix: "JD - ", selections: [], providerVersion: "1.5.0", connection: .jamfPro))
        #expect(!output.providersTF.contains("jamfplatform"))
        #expect(!output.providersTF.contains("jamfprotect"))
    }

    @Test func adoptStagingHandlesJamfProObjects() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "jamfpro-adopt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try """
        resource "jamfpro_category" "apps" {
          name     = "Apps"
          priority = 9
        }

        resource "jamfpro_policy" "install" {
          name        = "Install"
          category_id = jamfpro_category.apps.id
        }
        """.write(to: directory.appending(path: "main.tf"), atomically: true, encoding: .utf8)
        try """
        import {
          to = jamfpro_category.apps
          id = "13"
        }

        import {
          to = jamfpro_policy.install
          id = "7"
        }
        """.write(to: directory.appending(path: "main_import.tf"), atomically: true, encoding: .utf8)

        let objects = try ExportedObjectInventory.scan(directory: directory)
        #expect(Set(objects.map(\.address)) == ["jamfpro_category.apps", "jamfpro_policy.install"])

        // Adopting only the policy pins its category reference to the existing ID.
        try ExportedObjectInventory.pinReferences(directory: directory, keeping: ["jamfpro_policy.install"])
        let main = try String(contentsOf: directory.appending(path: "main.tf"), encoding: .utf8)
        #expect(main.contains(#"category_id = "13""#))
    }
}


@Suite("Standalone export")
struct StandaloneExportTests {
    static func metadata(_ json: String) throws -> BlockMetadata {
        try JSONDecoder().decode(BlockMetadata.self, from: Data(json.utf8))
    }

    /// A category provider and a block using every setting type.
    static func input(connection: ConnectionKind = .platform) throws -> WorkspaceInput {
        let categories = try metadata(#"{"id": "cats", "name": "Categories", "version": "1.0.0", "provides": {"category": ["Security"]}}"#)
        let filevault = try metadata(#"""
        {"id": "file-vault", "name": "FileVault", "version": "1.2.0", "acceptsCategory": true,
         "settings": [
           {"key": "label", "title": "Label", "type": "string", "default": "Encrypt \"now\""},
           {"key": "restart", "title": "Restart", "type": "bool", "default": "true"},
           {"key": "days", "title": "Days", "type": "number", "default": "7"},
           {"key": "users", "title": "Users", "type": "list", "default": "a\nb"},
           {"key": "token", "title": "Token", "type": "secret"}
         ]}
        """#)
        return WorkspaceInput(
            namePrefix: "JD - ",
            selections: [
                GeneratedSelection(block: categories, settings: [:]),
                GeneratedSelection(block: filevault, settings: ["days": "14"],
                                   providedCategory: ProvidedObject(blockID: "cats", name: "Security"),
                                   modulePath: connection == .jamfPro ? "jamfpro" : ""),
            ],
            providerVersion: "1.5.0",
            connection: connection)
    }

    static func files(_ input: WorkspaceInput) throws -> [String: String] {
        let tenant = StandaloneExport.Tenant(slug: "acme", input: input, blockFolders: [:])
        return try StandaloneExport.tenantFiles(tenant, moduleFolders: StandaloneExport.moduleFolders(for: [tenant]))
    }

    @Test func settingsBecomeDataAndWiringStaysInCode() throws {
        let files = try Self.files(Self.input())
        #expect(files["main.tf"]!.contains("""
        module "file_vault" {
          source         = "../../modules/file-vault"
          name_prefix    = var.name_prefix
          managed_by_tag = var.file_vault.managed_by_tag
          category_id    = module.cats.category_ids["Security"]
          label          = var.file_vault.label
          restart        = var.file_vault.restart
          days           = var.file_vault.days
          users          = var.file_vault.users
          token          = var.file_vault_token
        }
        """))
        #expect(files["variables.tf"]!.contains("""
        variable "file_vault" {
          description = "Settings for the FileVault block."
          type = object({
            managed_by_tag = string
            label          = string
            restart        = bool
            days           = number
            users          = list(string)
          })
        }
        """))
        let tfvars = files["tenant.auto.tfvars"]!
        #expect(tfvars.contains("""
        file_vault = {
          managed_by_tag = "Managed by Jamf Deployer · file-vault@1.2.0"
          label          = "Encrypt \\"now\\""
          restart        = true
          days           = 14
          users          = ["a", "b"]
        }
        """))
        #expect(tfvars.hasPrefix("# The only file") && tfvars.contains("name_prefix = \"JD - \""))
    }

    @Test func secretSettingsAreSensitiveVariablesNeverValues() throws {
        let files = try Self.files(Self.input())
        #expect(files["variables.tf"]!.contains("""
        variable "file_vault_token" {
          description = "FileVault: Token"
          type        = string
          sensitive   = true
        }
        """))
        #expect(files["variables.tf"]!.contains("TF_VAR_<name>"))
        #expect(files["main.tf"]!.contains("token          = var.file_vault_token"))
        #expect(!files["tenant.auto.tfvars"]!.contains("token"))
    }

    @Test func connectionsPickModuleVariantAndProvider() throws {
        let platform = try Self.files(Self.input())
        #expect(platform["terraform.tf"]!.contains("source  = \"jamf/jamfplatform\""))
        #expect(platform["terraform.tf"]!.contains("backend \"http\" {}"))
        #expect(platform["providers.tf"]!.contains("impact_alerts = true"))

        let jamfPro = try Self.files(Self.input(connection: .jamfPro))
        #expect(jamfPro["main.tf"]!.contains("source         = \"../../modules/file-vault/jamfpro\""))
        #expect(jamfPro["terraform.tf"]!.contains("source  = \"deploymenttheory/jamfpro\""))
        #expect(jamfPro["providers.tf"]!.contains("provider \"jamfpro\""))
        #expect(!jamfPro["terraform.tf"]!.contains("jamfplatform"))
    }

    @Test func blocksAtDifferentVersionsGetSeparateFolders() throws {
        let v1 = try Self.metadata(#"{"id": "cats", "name": "Categories", "version": "1.0.0"}"#)
        let v2 = try Self.metadata(#"{"id": "cats", "name": "Categories", "version": "2.0.0"}"#)
        let other = try Self.metadata(#"{"id": "eas", "name": "Attributes", "version": "1.0.0"}"#)
        func tenant(_ blocks: [BlockMetadata]) -> StandaloneExport.Tenant {
            StandaloneExport.Tenant(slug: "t", input: WorkspaceInput(
                namePrefix: "", selections: blocks.map { GeneratedSelection(block: $0, settings: [:]) },
                providerVersion: "1.5.0"), blockFolders: [:])
        }
        let folders = StandaloneExport.moduleFolders(for: [tenant([v1, other]), tenant([v2, other])])
        #expect(folders[StandaloneExport.folderKey(v1, source: nil)] == "cats-v1.0.0")
        #expect(folders[StandaloneExport.folderKey(v2, source: nil)] == "cats-v2.0.0")
        #expect(folders[StandaloneExport.folderKey(other, source: nil)] == "eas")

        // The same block and version from two sources are two copies.
        func sourced(_ path: String) -> StandaloneExport.Tenant {
            StandaloneExport.Tenant(slug: "s", input: WorkspaceInput(
                namePrefix: "", selections: [GeneratedSelection(block: v1, settings: [:])],
                providerVersion: "1.5.0"), blockFolders: ["cats": URL(filePath: path)])
        }
        let two = StandaloneExport.moduleFolders(for: [sourced("/a/cats"), sourced("/b/cats")])
        #expect(Set(two.values) == ["cats-v1.0.0", "cats-v1.0.0-2"])
    }

    @Test func tenantNamesBecomeUniqueDirectoryNames() {
        #expect(StandaloneExport.slug(for: "Acme Corp (EU)", taken: []) == "acme-corp-eu")
        #expect(StandaloneExport.slug(for: "Acme Corp (EU)", taken: ["acme-corp-eu"]) == "acme-corp-eu-2")
        #expect(StandaloneExport.slug(for: "—", taken: []) == "tenant")
        #expect(StandaloneExport.slug(for: "Zürich", taken: []) == "z-rich")
    }

    @Test func pendingRemovalsBlockTheExport() throws {
        var input = try Self.input()
        input.removals = [BlockRemoval(blockID: "cats", keepInJamf: true)]
        #expect(throws: StandaloneExport.ExportError.self) { try Self.files(input) }
    }

    @Test func stateMovesToTerraformsRegistry() throws {
        let state = Data(#"{"resources":[{"provider":"provider[\"registry.opentofu.org/jamf/jamfplatform\"]","instances":[{"attributes":{"notes":"see registry.opentofu.org/"}}]}]}"#.utf8)
        let moved = String(decoding: try StandaloneExport.stateForTerraform(state), as: UTF8.self)
        #expect(moved.contains("registry.terraform.io\\/jamf\\/jamfplatform") || moved.contains("registry.terraform.io/jamf/jamfplatform"))
        // Attribute values are not rewritten.
        #expect(moved.contains("see registry.opentofu.org"))
    }

    @Test func writesTheRepositoryAndRefusesAFullFolder() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let block = root.appending(path: "catalog/cats")
        try FileManager.default.createDirectory(at: block.appending(path: "jamfpro"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: block.appending(path: "block.json"))
        try Data("# module\n".utf8).write(to: block.appending(path: "main.tf"))
        let templates = root.appending(path: "templates")
        try FileManager.default.createDirectory(at: templates.appending(path: ".github"), withIntermediateDirectories: true)
        try Data("# readme\n".utf8).write(to: templates.appending(path: "README.md"))

        let cats = try Self.metadata(#"{"id": "cats", "name": "Categories", "version": "1.0.0"}"#)
        let tenant = StandaloneExport.Tenant(
            slug: "acme",
            input: WorkspaceInput(namePrefix: "JD - ", selections: [GeneratedSelection(block: cats, settings: [:])], providerVersion: "1.5.0"),
            blockFolders: ["cats": block])
        let out = root.appending(path: "repo")
        try StandaloneExport.write([tenant], templatesURL: templates, to: out)

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: out.appending(path: "modules/cats/main.tf").path))
        #expect(fm.fileExists(atPath: out.appending(path: "modules/cats/jamfpro").path))
        #expect(!fm.fileExists(atPath: out.appending(path: "modules/cats/block.json").path))
        for file in ["main.tf", "variables.tf", "tenant.auto.tfvars", "terraform.tf", "providers.tf"] {
            #expect(fm.fileExists(atPath: out.appending(path: "tenants/acme/\(file)").path))
        }
        #expect(fm.fileExists(atPath: out.appending(path: "README.md").path))
        #expect(fm.fileExists(atPath: out.appending(path: ".github").path))
        #expect(throws: StandaloneExport.ExportError.self) {
            try StandaloneExport.write([tenant], templatesURL: templates, to: out)
        }
    }
}
